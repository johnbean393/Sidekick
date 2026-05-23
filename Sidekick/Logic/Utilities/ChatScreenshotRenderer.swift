//
//  ChatScreenshotRenderer.swift
//  Sidekick
//
//  Created by John Bean on 5/23/26.
//
//  Drives an offscreen `WKWebView` to render a chat screenshot.
//  The web view is parented to a hidden window — `takeSnapshot`
//  refuses to capture orphaned web views — and the page is given a
//  bounded amount of time to declare its final layout before the
//  bitmap is grabbed. Returns an `NSImage` at native Retina scale.
//

import AppKit
import Foundation
import OSLog
import WebKit

// MARK: - Errors

enum ChatScreenshotError: LocalizedError {
    case templateMissing
    case templateUnreadable(Error)
    case templateMalformed
    case payloadEncodingFailed(Error?)
    case rendererTimedOut
    case rendererFailed(String)
    case snapshotFailed(Error)
    case noMessages
    case writeFailed(Error)
    case cancelled
    
    var errorDescription: String? {
        switch self {
            case .templateMissing:
                return String(localized: "The screenshot template could not be found in the app bundle.")
            case .templateUnreadable(let error):
                return String(localized: "The screenshot template could not be read: \(error.localizedDescription)")
            case .templateMalformed:
                return String(localized: "The screenshot template is missing its bootstrap script tag.")
            case .payloadEncodingFailed(let error):
                if let error {
                    return String(localized: "Failed to encode the screenshot payload: \(error.localizedDescription)")
                }
                return String(localized: "Failed to encode the screenshot payload.")
            case .rendererTimedOut:
                return String(localized: "The screenshot renderer timed out while preparing the page.")
            case .rendererFailed(let reason):
                return String(localized: "The screenshot renderer failed: \(reason)")
            case .snapshotFailed(let error):
                return String(localized: "WebKit failed to capture the snapshot: \(error.localizedDescription)")
            case .noMessages:
                return String(localized: "There are no messages to capture in the selected scope.")
            case .writeFailed(let error):
                return String(localized: "Could not write the screenshot to disk: \(error.localizedDescription)")
            case .cancelled:
                return String(localized: "The screenshot was cancelled.")
        }
    }
}

// MARK: - Renderer

@MainActor
final class ChatScreenshotRenderer {
    
    fileprivate static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Sidekick",
        category: "ChatScreenshotRenderer"
    )
    
    /// Maximum on-screen bitmap height for `WKWebView.takeSnapshot`.
    /// WebKit refuses or silently truncates beyond ~16k px, so we
    /// downscale the snapshot width proportionally when the page
    /// reports anything taller.
    fileprivate static let maxSnapshotHeight: CGFloat = 16_000
    
    /// Hard ceiling on how long we'll wait for the page to finish
    /// laying out before erroring out. Covers vendor JS init plus
    /// image decoding plus font load.
    fileprivate static let renderTimeoutSeconds: TimeInterval = 30
    
    /// Cushion added when WebKit fails its first snapshot attempt —
    /// most often because the contentful layer hasn't been promoted
    /// yet. We retry once after a runloop spin.
    fileprivate static let snapshotRetryDelay: TimeInterval = 0.18
    
    private let width: CGFloat
    
    init(width: CGFloat = 820) {
        self.width = width
    }
    
    /// Loads the bundled screenshot template, hands it the JSON
    /// payload via `evaluateJavaScript`, waits for the page to
    /// declare its final layout, and returns a PNG snapshot.
    func renderImage(
        templateURL: URL,
        resourcesFolder: URL,
        payloadJSON: String
    ) async throws -> NSImage {
        return try await self.runSession(
            templateURL: templateURL,
            resourcesFolder: resourcesFolder,
            payloadJSON: payloadJSON
        ) { session in
            try await session.runImage()
        }
    }
    
    /// Same flow as ``renderImage(templateURL:resourcesFolder:payloadJSON:)``,
    /// but returns PDF bytes produced by `WKWebView.createPDF`.
    /// The PDF is laid out as a single page sized to the full
    /// rendered content so the chat reads as one continuous
    /// document, mirroring the screenshot path.
    func renderPDF(
        templateURL: URL,
        resourcesFolder: URL,
        payloadJSON: String
    ) async throws -> Data {
        return try await self.runSession(
            templateURL: templateURL,
            resourcesFolder: resourcesFolder,
            payloadJSON: payloadJSON
        ) { session in
            try await session.runPDF()
        }
    }
    
    private func runSession<Output: Sendable>(
        templateURL: URL,
        resourcesFolder: URL,
        payloadJSON: String,
        _ body: @MainActor @Sendable @escaping (RendererSession) async throws -> Output
    ) async throws -> Output {
        let session = RendererSession(
            width: self.width,
            templateURL: templateURL,
            resourcesFolder: resourcesFolder,
            payloadJSON: payloadJSON
        )
        try Task.checkCancellation()
        do {
            let output = try await withThrowingTaskGroup(of: Output.self) { group in
                group.addTask { @MainActor in
                    return try await body(session)
                }
                group.addTask { @MainActor in
                    try await Task.sleep(
                        nanoseconds: UInt64(Self.renderTimeoutSeconds * 1_000_000_000)
                    )
                    throw ChatScreenshotError.rendererTimedOut
                }
                guard let value = try await group.next() else {
                    throw ChatScreenshotError.rendererFailed("no result")
                }
                group.cancelAll()
                return value
            }
            session.tearDown()
            return output
        } catch {
            session.tearDown()
            throw error
        }
    }
}

// MARK: - Session

/// One-shot renderer harness. Created per snapshot so the script
/// message handlers can capture a fresh pair of continuations.
@MainActor
private final class RendererSession: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    
    private let width: CGFloat
    private let templateURL: URL
    private let resourcesFolder: URL
    private let payloadJSON: String
    
    private var window: NSWindow?
    private var webView: WKWebView?
    private let assetSchemeHandler = ChatMarkdownAssetSchemeHandler()
    
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var heightContinuation: CheckedContinuation<CGFloat, Error>?
    private var navigationContinuation: CheckedContinuation<Void, Error>?
    
    private var didReady: Bool = false
    private var pendingHeight: CGFloat?
    private var scriptError: String?
    
    init(width: CGFloat, templateURL: URL, resourcesFolder: URL, payloadJSON: String) {
        self.width = width
        self.templateURL = templateURL
        self.resourcesFolder = resourcesFolder
        self.payloadJSON = payloadJSON
    }
    
    func runImage() async throws -> NSImage {
        let reportedHeight = try await self.prepareAndResize()
        let image = try await takeSnapshot(reportedHeight: reportedHeight)
        ChatScreenshotRenderer.logger.notice("renderer: snapshot complete")
        return image
    }
    
    func runPDF() async throws -> Data {
        let reportedHeight = try await self.prepareAndResize()
        let data = try await takePDFData(reportedHeight: reportedHeight)
        ChatScreenshotRenderer.logger.notice("renderer: pdf complete bytes=\(data.count, privacy: .public)")
        return data
    }
    
    /// Loads the bundled template, injects the payload, waits for
    /// the page to declare itself laid out, and resizes the web
    /// view to the reported height. Returns the height so the
    /// final output stage can size its snapshot/PDF accordingly.
    private func prepareAndResize() async throws -> CGFloat {
        ChatScreenshotRenderer.logger.notice("renderer: session.run start, template=\(self.templateURL.path, privacy: .public)")
        let webView = makeWebView()
        self.webView = webView
        attachToHiddenWindow(webView: webView)
        ChatScreenshotRenderer.logger.notice("renderer: web view attached")
        
        // Stage 1: load the bundled template file the same way the
        // in-app chat web view loads chat.html. `loadFileURL` with
        // an explicit `allowingReadAccessTo` is the only reliable
        // way to give a sandboxed WKWebView permission to read its
        // sibling resources (vendor JS, CSS, screenshot.js).
        ChatScreenshotRenderer.logger.notice("renderer: loadFileURL start")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.navigationContinuation = continuation
            webView.loadFileURL(
                self.templateURL,
                allowingReadAccessTo: self.resourcesFolder
            )
        }
        ChatScreenshotRenderer.logger.notice("renderer: navigation finished")
        try Task.checkCancellation()
        
        // Stage 2: inject the payload and kick off the bootstrap.
        // The page sets `window.skBootstrap` synchronously when
        // screenshot.js parses, so this call is safe immediately
        // after navigation finishes.
        try await self.bootstrapPage()
        ChatScreenshotRenderer.logger.notice("renderer: bootstrap injected")
        try Task.checkCancellation()
        
        // Stage 3: wait for the page to signal `ready`.
        try await waitForReady()
        ChatScreenshotRenderer.logger.notice("renderer: ready received")
        try Task.checkCancellation()
        
        // Stage 4: wait for the page's final layout-stable height.
        // The page only sends this after fonts + images are ready.
        let reportedHeight: CGFloat = try await waitForHeight()
        ChatScreenshotRenderer.logger.notice("renderer: height reported=\(reportedHeight, privacy: .public)")
        try Task.checkCancellation()
        
        // Resize the web view to match — `takeSnapshot` only paints
        // the on-screen region of the view's bounds, and createPDF
        // uses the same content area.
        try await resizeWebView(to: reportedHeight)
        try Task.checkCancellation()
        return reportedHeight
    }
    
    func tearDown() {
        if let webView = self.webView {
            webView.stopLoading()
            webView.navigationDelegate = nil
            let ucc = webView.configuration.userContentController
            ucc.removeScriptMessageHandler(forName: "ready")
            ucc.removeScriptMessageHandler(forName: "heightChanged")
            ucc.removeScriptMessageHandler(forName: "scriptError")
            webView.removeFromSuperview()
        }
        self.webView = nil
        if let window = self.window {
            window.orderOut(nil)
            window.contentView = nil
        }
        self.window = nil
        // Fail any unresolved continuations so dangling awaits don't
        // hang forever.
        if let cont = self.navigationContinuation {
            self.navigationContinuation = nil
            cont.resume(throwing: ChatScreenshotError.cancelled)
        }
        if let cont = self.readyContinuation {
            self.readyContinuation = nil
            cont.resume(throwing: ChatScreenshotError.cancelled)
        }
        if let cont = self.heightContinuation {
            self.heightContinuation = nil
            cont.resume(throwing: ChatScreenshotError.cancelled)
        }
    }
    
    // MARK: - Setup
    
    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        
        // Serve sidekick-asset:// for embedded chat images.
        config.setURLSchemeHandler(
            self.assetSchemeHandler,
            forURLScheme: ChatMarkdownAssetSchemeHandler.scheme
        )
        
        let userController = WKUserContentController()
        userController.add(self, name: "ready")
        userController.add(self, name: "heightChanged")
        userController.add(self, name: "scriptError")
        config.userContentController = userController
        
        config.suppressesIncrementalRendering = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.defaultWebpagePreferences.preferredContentMode = .desktop
        
        let frame = NSRect(x: 0, y: 0, width: self.width, height: 600)
        let webView = WKWebView(frame: frame, configuration: config)
        webView.navigationDelegate = self
        // Snapshot fidelity: opaque background, no transparency tricks.
        webView.setValue(true, forKey: "drawsBackground")
        webView.allowsMagnification = false
        webView.allowsLinkPreview = false
        return webView
    }
    
    /// Parents the web view to a window that is technically
    /// visible (on-screen, non-zero alpha) but invisible to the
    /// user (alpha ~0, ordered behind the active window, anchored
    /// at the corner of the main screen). WebKit aggressively
    /// suspends pages hosted in fully-hidden windows (`alpha == 0`
    /// or off-screen origins), and a suspended page never finishes
    /// navigation or runs scripts — which is why the previous
    /// offscreen-window setup hung.
    private func attachToHiddenWindow(webView: WKWebView) {
        let screen: NSScreen = NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
        // Window size matches the initial web view bounds so the
        // contents are laid out at the right width from the start.
        let initialHeight: CGFloat = 600
        let size = NSSize(width: self.width, height: initialHeight)
        // Anchor at the bottom-left corner of the main screen.
        // Combined with alpha ~0 + `.orderBack` the user never
        // sees the window, but WebKit treats it as visible and
        // keeps the page running normally.
        let origin = NSPoint(
            x: screen.frame.minX,
            y: screen.frame.minY
        )
        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.alphaValue = 0.002
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = container
        
        webView.frame = NSRect(origin: .zero, size: size)
        webView.autoresizingMask = []
        container.addSubview(webView)
        
        // Order back so this never appears above the user's
        // foreground content, but DO order it in so the window is
        // present in the screen graph (required for WebKit to
        // consider it visible).
        window.orderBack(nil)
        
        self.window = window
    }
    
    // MARK: - Bootstrap
    
    /// Hands the JSON payload to the page and triggers
    /// `window.skBootstrap`. The script tag for `screenshot.js`
    /// runs synchronously during HTML parsing, so the helper is
    /// always defined by the time `didFinish navigation` fires.
    private func bootstrapPage() async throws {
        guard let webView = self.webView else {
            throw ChatScreenshotError.rendererFailed("web view torn down")
        }
        let js: String = """
        (function () {
          try {
            var payload = \(self.payloadJSON);
            window.skScreenshotPayload = payload;
            if (typeof window.skBootstrap === 'function') {
              window.skBootstrap(payload);
            } else {
              return 'missing-bootstrap';
            }
            return 'ok';
          } catch (err) {
            return 'error:' + (err && err.message ? err.message : String(err));
          }
        })();
        """
        let result: String? = try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(js) { value, error in
                if let error {
                    continuation.resume(
                        throwing: ChatScreenshotError.rendererFailed(
                            "bootstrap: \(error.localizedDescription)"
                        )
                    )
                    return
                }
                continuation.resume(returning: value as? String)
            }
        }
        if let result, result != "ok" {
            throw ChatScreenshotError.rendererFailed("bootstrap returned \(result)")
        }
    }
    
    // MARK: - Wait helpers
    
    private func waitForReady() async throws {
        if self.didReady { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.readyContinuation = continuation
        }
    }
    
    private func waitForHeight() async throws -> CGFloat {
        if let pending = self.pendingHeight {
            self.pendingHeight = nil
            return pending
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CGFloat, Error>) in
            self.heightContinuation = continuation
        }
    }
    
    private func resizeWebView(to height: CGFloat) async throws {
        guard let webView = self.webView, let window = self.window else { return }
        let clampedHeight = max(50, height)
        let frame = NSRect(x: 0, y: 0, width: self.width, height: clampedHeight)
        var windowFrame = window.frame
        windowFrame.size = frame.size
        window.setFrame(windowFrame, display: false)
        window.contentView?.frame = frame
        webView.frame = frame
        // Spin the runloop a few ticks so AppKit + WebKit get a
        // chance to flush the geometry change before snapshot.
        try await Task.sleep(nanoseconds: 80_000_000)
    }
    
    // MARK: - Snapshot
    
    private func takeSnapshot(reportedHeight: CGFloat) async throws -> NSImage {
        guard let webView = self.webView else {
            throw ChatScreenshotError.rendererFailed("web view torn down")
        }
        
        let scale: CGFloat = webView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let logicalHeight: CGFloat = reportedHeight
        let bitmapHeight: CGFloat = logicalHeight * scale
        var snapshotWidth: CGFloat = self.width * scale
        
        // Clamp the bitmap if WebKit would refuse it. Downscaling
        // the snapshot width keeps the aspect ratio intact.
        if bitmapHeight > ChatScreenshotRenderer.maxSnapshotHeight {
            let downscale = ChatScreenshotRenderer.maxSnapshotHeight / bitmapHeight
            snapshotWidth = floor(snapshotWidth * downscale)
            ChatScreenshotRenderer.logger.warning(
                "Snapshot exceeded \(ChatScreenshotRenderer.maxSnapshotHeight, privacy: .public) px; downscaled to \(snapshotWidth, privacy: .public) px wide."
            )
        }
        
        let config = WKSnapshotConfiguration()
        config.rect = .null // Capture the entire view.
        config.afterScreenUpdates = true
        config.snapshotWidth = NSNumber(value: Double(snapshotWidth))
        
        do {
            return try await Self.snapshot(webView: webView, config: config)
        } catch {
            ChatScreenshotRenderer.logger.notice(
                "Initial snapshot failed; retrying once. error=\(String(describing: error), privacy: .public)"
            )
            // One retry: WebKit occasionally needs a runloop tick to
            // promote the layer it just sized.
            try await Task.sleep(
                nanoseconds: UInt64(ChatScreenshotRenderer.snapshotRetryDelay * 1_000_000_000)
            )
            return try await Self.snapshot(webView: webView, config: config)
        }
    }
    
    private static func snapshot(
        webView: WKWebView,
        config: WKSnapshotConfiguration
    ) async throws -> NSImage {
        return try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: config) { image, error in
                if let image {
                    continuation.resume(returning: image)
                    return
                }
                if let error {
                    continuation.resume(throwing: ChatScreenshotError.snapshotFailed(error))
                    return
                }
                continuation.resume(
                    throwing: ChatScreenshotError.rendererFailed("WKWebView returned no image")
                )
            }
        }
    }
    
    // MARK: - PDF
    
    private func takePDFData(reportedHeight: CGFloat) async throws -> Data {
        guard let webView = self.webView else {
            throw ChatScreenshotError.rendererFailed("web view torn down")
        }
        // Producing the PDF as a single page sized to the full
        // content keeps the chat readable as one continuous
        // document instead of paginating mid-message.
        let pdfConfig = WKPDFConfiguration()
        pdfConfig.rect = CGRect(
            x: 0,
            y: 0,
            width: self.width,
            height: max(50, reportedHeight)
        )
        return try await withCheckedThrowingContinuation { continuation in
            webView.createPDF(configuration: pdfConfig) { result in
                switch result {
                    case .success(let data):
                        continuation.resume(returning: data)
                    case .failure(let error):
                        continuation.resume(
                            throwing: ChatScreenshotError.snapshotFailed(error)
                        )
                }
            }
        }
    }
    
    // MARK: - WKNavigationDelegate
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ChatScreenshotRenderer.logger.notice("renderer: WKNavigation didFinish")
        if let cont = self.navigationContinuation {
            self.navigationContinuation = nil
            cont.resume()
        }
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        ChatScreenshotRenderer.logger.error(
            "renderer: WKNavigation didFail: \(String(describing: error), privacy: .public)"
        )
        if let cont = self.navigationContinuation {
            self.navigationContinuation = nil
            cont.resume(throwing: ChatScreenshotError.rendererFailed(error.localizedDescription))
        }
    }
    
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        ChatScreenshotRenderer.logger.error(
            "renderer: WKNavigation didFailProvisional: \(String(describing: error), privacy: .public)"
        )
        if let cont = self.navigationContinuation {
            self.navigationContinuation = nil
            cont.resume(throwing: ChatScreenshotError.rendererFailed(error.localizedDescription))
        }
    }
    
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ChatScreenshotRenderer.logger.error("renderer: WebContent process terminated")
        let err = ChatScreenshotError.rendererFailed("WebContent process terminated")
        if let cont = self.navigationContinuation {
            self.navigationContinuation = nil
            cont.resume(throwing: err)
        }
        if let cont = self.readyContinuation {
            self.readyContinuation = nil
            cont.resume(throwing: err)
        }
        if let cont = self.heightContinuation {
            self.heightContinuation = nil
            cont.resume(throwing: err)
        }
    }
    
    // MARK: - WKScriptMessageHandler
    
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        switch message.name {
            case "ready":
                ChatScreenshotRenderer.logger.notice("renderer: script message ready")
                self.didReady = true
                if let cont = self.readyContinuation {
                    self.readyContinuation = nil
                    cont.resume()
                }
            case "heightChanged":
                let body = message.body as? [String: Any]
                let raw = (body?["height"] as? NSNumber)?.doubleValue
                    ?? (body?["height"] as? Double)
                    ?? 0
                let height = CGFloat(raw)
                if let cont = self.heightContinuation {
                    self.heightContinuation = nil
                    cont.resume(returning: height)
                } else {
                    self.pendingHeight = height
                }
            case "scriptError":
                let body = message.body as? [String: Any]
                let text = (body?["message"] as? String) ?? "unknown JS error"
                self.scriptError = text
                ChatScreenshotRenderer.logger.error(
                    "screenshot.js error: \(text, privacy: .public)"
                )
                // Surface the failure to any pending stage so the
                // user sees a real error instead of waiting on the
                // 30-second timeout.
                if let cont = self.readyContinuation {
                    self.readyContinuation = nil
                    cont.resume(throwing: ChatScreenshotError.rendererFailed(text))
                }
                if let cont = self.heightContinuation {
                    self.heightContinuation = nil
                    cont.resume(throwing: ChatScreenshotError.rendererFailed(text))
                }
            default:
                break
        }
    }
}


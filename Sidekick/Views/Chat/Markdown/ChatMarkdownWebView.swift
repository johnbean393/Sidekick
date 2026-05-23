//
//  ChatMarkdownWebView.swift
//  Sidekick
//
//  Created by John Bean on 5/22/26.
//
//  A WKWebView-backed Markdown renderer used inside chat bubbles. Markdown
//  is parsed and rendered by the bundled chat.js (markdown-it +
//  highlight.js + KaTeX). The host pushes text in via a JS bridge and the
//  guest reports back its content height so the SwiftUI parent can size
//  the view accordingly.
//

import AppKit
import OSLog
import SwiftUI
import WebKit

/// A SwiftUI wrapper around a `WKWebView` configured for streaming
/// Markdown rendering.
///
/// The view reports its intrinsic content height back through the
/// supplied `height` binding. Callers typically apply
/// `.frame(height: height)` so the bubble grows with its content.
struct ChatMarkdownWebView: NSViewRepresentable {

    /// Visual style used by the renderer.
    ///
    /// - ``default``: standard assistant-message styling.
    /// - ``reasoning``: smaller, muted variant used to show an assistant
    ///   model's "thinking" / reasoning stream.
    enum Mode: String {
        case `default`
        case reasoning
    }

    /// The Markdown source to render. May grow over time (streaming).
    var text: String

    /// Whether the host is still streaming `text` into this view. While
    /// true, the trailing block is rendered with a blinking caret and skips
    /// code-block highlighting.
    var isStreaming: Bool

    /// Color scheme applied to the rendered Markdown.
    var colorScheme: ColorScheme

    /// Base font size for the rendered Markdown, in points.
    var fontSize: CGFloat

    /// Renderer mode (see ``Mode``).
    var mode: Mode = .default

    /// Optional stable identity used to cache the most recently observed
    /// intrinsic content height. When two ``ChatMarkdownWebView`` instances
    /// share the same `cacheKey`, the second one initialises its
    /// ``contentHeight`` from the cached value so the layout does not
    /// briefly collapse while `chat.html` finishes loading. Typically the
    /// underlying message id is used.
    var cacheKey: String? = nil

    /// Reported intrinsic content height of the rendered Markdown.
    @Binding var contentHeight: CGFloat

    func makeCoordinator() -> Coordinator {
        let cacheKey = self.cacheKey
        // Seed the binding from the height cache so the initial layout is
        // already correct (avoids the post-stream scroll jump described in
        // the design notes).
        if let cacheKey, let cached = ChatMarkdownHeightCache.shared.height(for: cacheKey) {
            DispatchQueue.main.async { [contentHeight = self._contentHeight] in
                if contentHeight.wrappedValue < cached - 0.5 {
                    contentHeight.wrappedValue = cached
                }
            }
        }
        return Coordinator(
            colorScheme: self.colorScheme,
            fontSize: self.fontSize,
            isStreaming: self.isStreaming,
            mode: self.mode,
            initialText: self.text
        ) { [contentHeight = self._contentHeight] newHeight in
            if abs(contentHeight.wrappedValue - newHeight) > 0.5 {
                contentHeight.wrappedValue = newHeight
            }
            if let cacheKey {
                ChatMarkdownHeightCache.shared.store(
                    height: newHeight,
                    for: cacheKey
                )
            }
        }
    }

    func makeNSView(context: Context) -> ChatMarkdownWebViewHost {
        let host = ChatMarkdownWebViewHost(coordinator: context.coordinator)
        host.loadIfNeeded()
        return host
    }

    func updateNSView(_ host: ChatMarkdownWebViewHost, context: Context) {
        context.coordinator.apply(
            text: self.text,
            isStreaming: self.isStreaming,
            colorScheme: self.colorScheme,
            fontSize: self.fontSize,
            mode: self.mode
        )
    }

    static func dismantleNSView(_ host: ChatMarkdownWebViewHost, coordinator: Coordinator) {
        host.tearDown()
    }
}

// MARK: - Height cache

/// Process-wide cache that remembers the most recently observed
/// intrinsic content height for each ``ChatMarkdownWebView/cacheKey``.
/// Used to prevent the scroll position from snapping when a streaming
/// message's host (PendingMessageHost) is swapped for the persisted
/// message in the conversation list: the freshly-mounted WKWebView
/// initialises its layout from this cache so it does not briefly report
/// `height = 0`.
final class ChatMarkdownHeightCache {

    static let shared = ChatMarkdownHeightCache()

    private let cache: NSCache<NSString, NSNumber> = {
        let c = NSCache<NSString, NSNumber>()
        c.countLimit = 512
        return c
    }()

    private init() { }

    func height(for key: String) -> CGFloat? {
        guard let value = self.cache.object(forKey: key as NSString) else {
            return nil
        }
        return CGFloat(value.doubleValue)
    }

    func store(height: CGFloat, for key: String) {
        guard height > 0 else { return }
        self.cache.setObject(
            NSNumber(value: Double(height)),
            forKey: key as NSString
        )
    }
}

// MARK: - Coordinator

extension ChatMarkdownWebView {

    /// Tracks the state pushed to the JS renderer and coalesces updates so
    /// we never block the main thread waiting for `evaluateJavaScript`.
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {

        /// Logger.
        private static let logger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "com.sidekick",
            category: "ChatMarkdownWebView"
        )

        /// Owning WKWebView. Set by ``ChatMarkdownWebViewHost`` once the
        /// view is constructed.
        weak var webView: WKWebView?

        /// Called every time the rendered content reports a new height.
        var onHeightChanged: (CGFloat) -> Void

        /// Most recently applied state.
        private(set) var lastText: String = ""
        private(set) var lastIsStreaming: Bool = false
        private(set) var lastColorScheme: ColorScheme
        private(set) var lastFontSize: CGFloat
        private(set) var lastMode: ChatMarkdownWebView.Mode

        /// Pending state to flush when the page becomes ready.
        private var pendingText: String?
        private var pendingIsStreaming: Bool?
        private var pendingColorScheme: ColorScheme?
        private var pendingFontSize: CGFloat?
        private var pendingMode: ChatMarkdownWebView.Mode?

        /// Whether the guest reported ready (chat.js finished loading).
        private var ready: Bool = false

        init(
            colorScheme: ColorScheme,
            fontSize: CGFloat,
            isStreaming: Bool,
            mode: ChatMarkdownWebView.Mode,
            initialText: String,
            onHeightChanged: @escaping (CGFloat) -> Void
        ) {
            self.lastColorScheme = colorScheme
            self.lastFontSize = fontSize
            self.lastIsStreaming = isStreaming
            self.lastMode = mode
            self.lastText = initialText
            self.onHeightChanged = onHeightChanged
            self.pendingText = initialText
            self.pendingIsStreaming = isStreaming
            self.pendingColorScheme = colorScheme
            self.pendingFontSize = fontSize
            self.pendingMode = mode
            super.init()
        }

        // MARK: Bridge inputs

        /// Apply updated state from SwiftUI's `updateNSView`.
        func apply(
            text: String,
            isStreaming: Bool,
            colorScheme: ColorScheme,
            fontSize: CGFloat,
            mode: ChatMarkdownWebView.Mode
        ) {
            // Color scheme.
            if colorScheme != self.lastColorScheme {
                self.lastColorScheme = colorScheme
                if self.ready {
                    self.callJS("window.sk && sk.setColorScheme(\(quote(colorScheme == .dark ? "dark" : "light")))")
                } else {
                    self.pendingColorScheme = colorScheme
                }
            }

            // Font size.
            if abs(fontSize - self.lastFontSize) > 0.01 {
                self.lastFontSize = fontSize
                if self.ready {
                    self.callJS("window.sk && sk.setFontSize(\(fontSize))")
                } else {
                    self.pendingFontSize = fontSize
                }
            }

            // Mode.
            if mode != self.lastMode {
                self.lastMode = mode
                if self.ready {
                    self.callJS("window.sk && sk.setMode(\(quote(mode.rawValue)))")
                } else {
                    self.pendingMode = mode
                }
            }

            // Text.
            if text != self.lastText {
                let previous = self.lastText
                self.lastText = text
                if self.ready {
                    if text.hasPrefix(previous) && previous.count > 0 {
                        let suffix = String(text.dropFirst(previous.count))
                        self.callJS("window.sk && sk.appendMarkdown(\(quote(suffix)))")
                    } else {
                        self.callJS("window.sk && sk.setMarkdown(\(quote(text)))")
                    }
                } else {
                    self.pendingText = text
                }
            }

            // Streaming flag.
            if isStreaming != self.lastIsStreaming {
                self.lastIsStreaming = isStreaming
                if self.ready {
                    self.callJS("window.sk && sk.setStreaming(\(isStreaming ? "true" : "false"))")
                } else {
                    self.pendingIsStreaming = isStreaming
                }
            }
        }

        // MARK: WKScriptMessageHandler

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            switch message.name {
                case "ready":
                    self.handleReady()
                case "heightChanged":
                    if let body = message.body as? [String: Any], let h = body["height"] as? Double {
                        DispatchQueue.main.async { [weak self] in
                            self?.onHeightChanged(CGFloat(h))
                        }
                    }
                case "openLink":
                    if let body = message.body as? [String: Any], let href = body["href"] as? String {
                        self.openLink(href: href)
                    }
                case "copyCode":
                    if let body = message.body as? [String: Any], let text = body["text"] as? String {
                        self.copyToClipboard(text)
                    }
                default:
                    break
            }
        }

        // MARK: WKNavigationDelegate

        // Block top-frame navigations to external URLs; we route them through NSWorkspace.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            if navigationAction.navigationType == .linkActivated {
                self.openLink(href: url.absoluteString)
                decisionHandler(.cancel)
                return
            }
            // Allow the initial file:// load + same-document subresources,
            // our custom asset scheme, and inert about:blank navigation.
            if url.isFileURL
                || url.scheme == "about"
                || url.scheme == ChatMarkdownAssetSchemeHandler.scheme {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
        }

        // MARK: Helpers

        private func handleReady() {
            self.ready = true
            // Drain pending state in the right order: theme + font + mode,
            // then text, then streaming flag so the trailing-block
            // decoration is correct.
            if let scheme = self.pendingColorScheme {
                self.callJS("window.sk && sk.setColorScheme(\(quote(scheme == .dark ? "dark" : "light")))")
                self.pendingColorScheme = nil
            }
            if let size = self.pendingFontSize {
                self.callJS("window.sk && sk.setFontSize(\(size))")
                self.pendingFontSize = nil
            }
            if let mode = self.pendingMode {
                self.callJS("window.sk && sk.setMode(\(quote(mode.rawValue)))")
                self.pendingMode = nil
            }
            if let text = self.pendingText {
                self.callJS("window.sk && sk.setMarkdown(\(quote(text)))")
                self.pendingText = nil
            }
            if let streaming = self.pendingIsStreaming {
                self.callJS("window.sk && sk.setStreaming(\(streaming ? "true" : "false"))")
                self.pendingIsStreaming = nil
            }
        }

        private func callJS(_ script: String) {
            guard let webView = self.webView else { return }
            // Always hop to the main actor — WKWebView is main-thread-only.
            if Thread.isMainThread {
                webView.evaluateJavaScript(script, completionHandler: nil)
            } else {
                DispatchQueue.main.async {
                    webView.evaluateJavaScript(script, completionHandler: nil)
                }
            }
        }

        private func openLink(href: String) {
            guard let url = URL(string: href) else { return }
            DispatchQueue.main.async {
                NSWorkspace.shared.open(url)
            }
        }

        private func copyToClipboard(_ text: String) {
            DispatchQueue.main.async {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            }
        }

        /// JSON-encode an arbitrary string into a single-line JS literal.
        private func quote(_ s: String) -> String {
            do {
                let data = try JSONSerialization.data(
                    withJSONObject: [s],
                    options: [.fragmentsAllowed]
                )
                if let str = String(data: data, encoding: .utf8) {
                    // strip outer brackets
                    var trimmed = str
                    if trimmed.hasPrefix("[") { trimmed.removeFirst() }
                    if trimmed.hasSuffix("]") { trimmed.removeLast() }
                    return trimmed
                }
            } catch { }
            // Safe fallback.
            return "\"\""
        }
    }
}

// MARK: - WKWebView subclass

/// `WKWebView` subclass with two macOS-specific tweaks:
///
/// 1. **Scroll pass-through.** When the user scrolls a chat conversation
///    and the pointer happens to be over a message bubble, we want the
///    surrounding `ScrollView` (the conversation transcript) to scroll,
///    not the (deliberately-non-scrolling) web view. We forward
///    predominantly-vertical scroll events up the responder chain.
///    Predominantly-horizontal events stay inside the bubble so wide
///    code blocks and tables can still pan.
///
/// 2. **Background transparency.** Set up by the host once instantiated
///    (`drawsBackground = false`).
final class ChatMarkdownWKWebView: WKWebView {

    override func scrollWheel(with event: NSEvent) {
        // Heuristic: treat a gesture as vertical if its accumulated Y
        // displacement clearly dominates. Otherwise let WKWebView's
        // internal scroll handling deal with it (used for horizontal pan
        // inside <pre>/<table> overflow regions).
        let dy = abs(event.scrollingDeltaY)
        let dx = abs(event.scrollingDeltaX)
        if dy >= dx {
            // Forward to the nearest enclosing scroll view rather than to
            // `nextResponder`, which would re-enter our own view chain.
            if let scrollView = self.enclosingScrollView {
                scrollView.scrollWheel(with: event)
                return
            }
            self.nextResponder?.scrollWheel(with: event)
            return
        }
        super.scrollWheel(with: event)
    }
}

// MARK: - Host NSView

/// `NSView` subclass that owns the underlying `WKWebView`. Kept as a
/// dedicated class so we can customize layout, tear-down and (later) view
/// reuse without leaking those details to SwiftUI.
final class ChatMarkdownWebViewHost: NSView {

    let webView: ChatMarkdownWKWebView
    private let coordinator: ChatMarkdownWebView.Coordinator
    private let schemeHandler: ChatMarkdownAssetSchemeHandler
    private var didLoad: Bool = false

    init(coordinator: ChatMarkdownWebView.Coordinator) {
        self.coordinator = coordinator
        let schemeHandler = ChatMarkdownAssetSchemeHandler()
        self.schemeHandler = schemeHandler

        let config = WKWebViewConfiguration()

        // Allow JS to talk back to Swift.
        let userController = WKUserContentController()
        userController.add(coordinator, name: "ready")
        userController.add(coordinator, name: "heightChanged")
        userController.add(coordinator, name: "openLink")
        userController.add(coordinator, name: "copyCode")
        config.userContentController = userController

        // Serve image assets referenced by the rendered Markdown — file://
        // URLs, bare filenames resolved against ~/Library/Application
        // Support/.../Generated Images, etc.
        config.setURLSchemeHandler(
            schemeHandler,
            forURLScheme: ChatMarkdownAssetSchemeHandler.scheme
        )

        config.suppressesIncrementalRendering = false
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.defaultWebpagePreferences.preferredContentMode = .desktop

        // Enable inline media and disable any chrome that fights with chat.
        if #available(macOS 11.3, *) {
            config.preferences.isFraudulentWebsiteWarningEnabled = false
        }

        let frame = NSRect(x: 0, y: 0, width: 200, height: 1)
        let webView = ChatMarkdownWKWebView(frame: frame, configuration: config)
        self.webView = webView
        super.init(frame: frame)

        coordinator.webView = webView
        webView.navigationDelegate = coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsLinkPreview = false
        webView.allowsMagnification = false
        webView.translatesAutoresizingMaskIntoConstraints = false

        self.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: self.topAnchor),
            webView.bottomAnchor.constraint(equalTo: self.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: self.trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Loads the bundled chat.html the first time we're attached to a window.
    func loadIfNeeded() {
        guard !self.didLoad else { return }
        guard let folder = ChatMarkdownWebViewResources.shared.bundleFolderURL,
              let chatURL = ChatMarkdownWebViewResources.shared.chatHTMLURL else {
            assertionFailure("chat.html missing from bundle")
            return
        }
        self.didLoad = true
        // Allow the WKWebView to load sibling vendor/* assets.
        self.webView.loadFileURL(chatURL, allowingReadAccessTo: folder)
    }

    /// Releases retained handlers before the view is torn down.
    func tearDown() {
        let ucc = self.webView.configuration.userContentController
        ucc.removeScriptMessageHandler(forName: "ready")
        ucc.removeScriptMessageHandler(forName: "heightChanged")
        ucc.removeScriptMessageHandler(forName: "openLink")
        ucc.removeScriptMessageHandler(forName: "copyCode")
        self.webView.navigationDelegate = nil
        self.webView.stopLoading()
    }
}

// MARK: - Resource bundle

/// Resolves bundled chat.html / chat.js / chat.css assets shipped under
/// `Resources/ChatMarkdownWebView/`.
final class ChatMarkdownWebViewResources {

    static let shared = ChatMarkdownWebViewResources()

    /// URL of the bundled `ChatMarkdownWebView` folder. The whole folder is
    /// passed to `WKWebView.loadFileURL` so vendor sub-assets can resolve.
    let bundleFolderURL: URL?

    /// URL of the entrypoint HTML file.
    let chatHTMLURL: URL?

    private init() {
        let bundle = Bundle.main
        // The folder is shipped as a folder reference, so the children are
        // preserved on disk.
        let folder = bundle.url(
            forResource: "ChatMarkdownWebView",
            withExtension: nil
        )
        self.bundleFolderURL = folder
        if let folder {
            self.chatHTMLURL = folder.appendingPathComponent("chat.html")
        } else {
            // Fall back to flat lookup.
            self.chatHTMLURL = bundle.url(
                forResource: "chat",
                withExtension: "html"
            )
        }
    }
}

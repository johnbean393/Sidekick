//
//  ChatMarkdownAssetSchemeHandler.swift
//  Sidekick
//
//  Created by John Bean on 5/22/26.
//
//  Serves image assets referenced by the rendered Markdown inside
//  ``ChatMarkdownWebView``. The renderer (chat.js) rewrites the `src` of
//  every non-network image to
//
//      sidekick-asset://load?u=<percent-encoded-original-src>
//
//  This handler decodes that original source, resolves it to a file on
//  disk (file URL, absolute path, or a bare filename looked up against
//  the well-known Sidekick directories like
//  `~/Library/Application Support/com.pattonium.Sidekick/Generated Images`),
//  and streams the bytes back to the web view.
//
//  Historical messages keep working because the resolution rules are
//  exactly the same ones the previous `MarkdownImageProvider` used.
//

import Foundation
import OSLog
import UniformTypeIdentifiers
import WebKit

/// Custom ``WKURLSchemeHandler`` used by ``ChatMarkdownWebView`` to fetch
/// image bytes for image references inside chat messages.
///
/// All requests share the URL shape:
///
///     sidekick-asset://load?u=<percent-encoded-original-src>
///
/// The query parameter `u` carries the *exact* image src that appeared in
/// the original Markdown so the resolution logic stays in Swift. This
/// keeps the renderer trivially serializable in JS and lets us evolve
/// resolution rules without round-tripping through chat.js.
final class ChatMarkdownAssetSchemeHandler: NSObject, WKURLSchemeHandler {

    /// The URL scheme this handler serves. Registered with
    /// ``WKWebViewConfiguration/setURLSchemeHandler(_:forURLScheme:)``.
    static let scheme: String = "sidekick-asset"

    /// Logger used for diagnosing path-resolution misses.
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.sidekick",
        category: "ChatMarkdownAssetSchemeHandler"
    )

    /// File system queue for blocking I/O. Each `start(_:)` invocation
    /// hops onto this queue so we don't stall the WebKit network thread.
    private let ioQueue: DispatchQueue = DispatchQueue(
        label: "com.sidekick.chat-md-asset-handler",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// Tasks we've already started but not yet finished, keyed by their
    /// request URL. We honour `stop(_:)` callbacks by marking the matching
    /// task cancelled before it tries to call back into WebKit (which
    /// would crash if the task has been invalidated).
    private let stateLock = NSLock()
    private var cancelledTasks: Set<ObjectIdentifier> = []

    // MARK: - WKURLSchemeHandler

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let taskID = ObjectIdentifier(urlSchemeTask)
        let request = urlSchemeTask.request

        guard let url = request.url else {
            self.fail(urlSchemeTask, taskID: taskID, code: .unsupportedURL)
            return
        }

        guard let originalSrc = Self.extractOriginalSrc(from: url) else {
            self.fail(urlSchemeTask, taskID: taskID, code: .unsupportedURL)
            return
        }

        self.ioQueue.async { [weak self] in
            guard let self = self else { return }
            guard !self.isCancelled(taskID) else { return }

            guard let resolved = AssetResolver.resolve(originalSrc: originalSrc) else {
                Self.logger.debug(
                    "asset resolution failed for src: \(originalSrc, privacy: .public)"
                )
                self.fail(urlSchemeTask, taskID: taskID, code: .fileDoesNotExist)
                return
            }
            guard AssetResolver.isAllowed(resolved) else {
                Self.logger.notice(
                    "blocked asset outside allowed roots: \(resolved.path, privacy: .public)"
                )
                self.fail(urlSchemeTask, taskID: taskID, code: .noPermissionsToReadFile)
                return
            }

            let data: Data
            do {
                data = try Data(contentsOf: resolved, options: [.mappedIfSafe])
            } catch {
                Self.logger.notice(
                    "could not read asset \(resolved.path, privacy: .public): \(String(describing: error), privacy: .public)"
                )
                self.fail(urlSchemeTask, taskID: taskID, code: .fileDoesNotExist)
                return
            }
            guard !self.isCancelled(taskID) else { return }

            let mimeType = AssetResolver.mimeType(for: resolved)
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": mimeType,
                    "Content-Length": String(data.count),
                    "Cache-Control": "private, max-age=600",
                    "Access-Control-Allow-Origin": "*",
                ]
            ) ?? URLResponse(
                url: url,
                mimeType: mimeType,
                expectedContentLength: data.count,
                textEncodingName: nil
            )

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if self.isCancelled(taskID) {
                    self.forget(taskID: taskID)
                    return
                }
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
                self.forget(taskID: taskID)
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        let taskID = ObjectIdentifier(urlSchemeTask)
        self.stateLock.lock()
        self.cancelledTasks.insert(taskID)
        self.stateLock.unlock()
    }

    // MARK: - Helpers

    private func fail(
        _ task: WKURLSchemeTask,
        taskID: ObjectIdentifier,
        code: URLError.Code
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.isCancelled(taskID) {
                self.forget(taskID: taskID)
                return
            }
            task.didFailWithError(URLError(code))
            self.forget(taskID: taskID)
        }
    }

    private func isCancelled(_ taskID: ObjectIdentifier) -> Bool {
        self.stateLock.lock()
        defer { self.stateLock.unlock() }
        return self.cancelledTasks.contains(taskID)
    }

    private func forget(taskID: ObjectIdentifier) {
        self.stateLock.lock()
        self.cancelledTasks.remove(taskID)
        self.stateLock.unlock()
    }

    /// Pulls the original markdown image src out of a
    /// `sidekick-asset://load?u=...` URL.
    fileprivate static func extractOriginalSrc(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let queryItems = components.queryItems ?? []
        guard let raw = queryItems.first(where: { $0.name == "u" })?.value,
              !raw.isEmpty else {
            return nil
        }
        return raw.removingPercentEncoding ?? raw
    }
}

// MARK: - Asset resolution

/// Pure functions to resolve a markdown image src to a real file URL,
/// validate it against the set of directories the user has authorised us
/// to read, and detect a MIME type for the response.
enum AssetResolver {

    /// Directories that historical message images can legitimately come
    /// from. Anything outside these is rejected to prevent a maliciously
    /// crafted assistant response from making the web view read arbitrary
    /// files on disk.
    ///
    /// The home directory covers all of `~/Library`, `~/Documents`,
    /// `~/Pictures`, etc. — i.e. anywhere a user can drag from. We add
    /// Sidekick's own container explicitly because it may live somewhere
    /// non-obvious (e.g. inside a sandbox container).
    fileprivate static var allowedRoots: [URL] {
        var roots: [URL] = []
        roots.append(FileManager.default.homeDirectoryForCurrentUser)
        roots.append(Settings.containerUrl)
        if let tmp = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first {
            roots.append(tmp)
        }
        return roots.map { $0.standardizedFileURL }
    }

    /// Directories searched, in order, when an image src is just a bare
    /// filename (e.g. `![](chart.png)`). Mirrors the previous
    /// `MarkdownImageProvider` behaviour, where unresolved filenames fell
    /// back to the Generated Images directory.
    fileprivate static var searchRoots: [URL] {
        [
            Settings.containerUrl.appendingPathComponent("Generated Images"),
            Settings.containerUrl.appendingPathComponent("Temporary Resources"),
            Settings.containerUrl,
        ]
    }

    /// Resolves a markdown image src — a URL string, an absolute path, or
    /// a relative path — to a concrete file URL.
    static func resolve(originalSrc: String) -> URL? {
        let trimmed = originalSrc.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        let fm = FileManager.default

        // 1. file:// URL — use the literal path.
        if trimmed.lowercased().hasPrefix("file://") {
            guard let url = URL(string: trimmed) else { return nil }
            return fm.fileExists(atPath: url.path) ? url : nil
        }

        // 2. Absolute POSIX path — use directly. (Tilde-expanded.)
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            let expanded = (trimmed as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            return fm.fileExists(atPath: url.path) ? url : nil
        }

        // 3. URL with another scheme that wasn't filtered out at the
        // chat.js layer — refuse so we don't accidentally proxy network
        // traffic.
        if let url = URL(string: trimmed),
           let scheme = url.scheme,
           !scheme.isEmpty,
           scheme.lowercased() != "file" {
            return nil
        }

        // 4. Relative — search the well-known directories.
        let decoded = trimmed.removingPercentEncoding ?? trimmed
        for root in self.searchRoots {
            let candidate = root.appendingPathComponent(decoded)
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Whether `url` is inside one of the allowed root directories.
    static func isAllowed(_ url: URL) -> Bool {
        let normalized = url.standardizedFileURL.path
        let roots = self.allowedRoots
        for root in roots {
            let rootPath = root.path
            // Suffix the root with a path separator so `/Users/foo` doesn't
            // accidentally match `/Users/foobar`.
            let normalizedRoot = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            if normalized == rootPath { return true }
            if normalized.hasPrefix(normalizedRoot) { return true }
        }
        return false
    }

    /// Picks a MIME type from the file extension; defaults to
    /// `application/octet-stream` for unknown types.
    static func mimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if ext.isEmpty { return "application/octet-stream" }
        if let type = UTType(filenameExtension: ext),
           let mime = type.preferredMIMEType {
            return mime
        }
        // Fallback for a couple of stragglers UTType doesn't always know.
        switch ext {
            case "svg":   return "image/svg+xml"
            case "webp":  return "image/webp"
            case "avif":  return "image/avif"
            default:      return "application/octet-stream"
        }
    }
}

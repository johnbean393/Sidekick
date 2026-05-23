//
//  MessageTextContentView.swift
//  Sidekick
//
//  Created by Bean John on 11/12/24.
//

import AppKit
import SwiftUI

/// Renders the assistant's response text using a `WKWebView`-backed
/// Markdown renderer (see ``ChatMarkdownWebView``). Replaces the previous
/// MarkdownUI / TextKit hybrid which was too slow during streaming.
struct MessageTextContentView: View {

    @Environment(\.colorScheme) private var colorScheme

    var text: String
    var isStreaming: Bool = false
    /// Retained for API compatibility with previous call sites; the new
    /// renderer doesn't need a separate "deprioritized" path.
    var deprioritizeStreamingUpdates: Bool = false
    /// Stable identity for the underlying message. Used to keep the
    /// scroll position from snapping when ``PendingMessageHost`` swaps
    /// its streaming WKWebView for the persisted message's WKWebView at
    /// the end of generation: the new view starts at the cached height.
    var messageIdentity: String? = nil

    @State private var contentHeight: CGFloat

    init(
        text: String,
        isStreaming: Bool = false,
        deprioritizeStreamingUpdates: Bool = false,
        messageIdentity: String? = nil
    ) {
        self.text = text
        self.isStreaming = isStreaming
        self.deprioritizeStreamingUpdates = deprioritizeStreamingUpdates
        self.messageIdentity = messageIdentity
        // Seed the height from the per-message cache so the post-stream
        // WKWebView swap doesn't briefly collapse the layout (which would
        // otherwise snap the conversation scroll position back to the
        // top of the message).
        let seed: CGFloat = messageIdentity
            .flatMap { ChatMarkdownHeightCache.shared.height(for: $0) } ?? 1
        self._contentHeight = State(initialValue: seed)
    }

    private var fontSize: CGFloat {
        NSFont.systemFontSize + 1
    }

    var body: some View {
        ChatMarkdownWebView(
            text: self.text,
            isStreaming: self.isStreaming,
            colorScheme: self.colorScheme,
            fontSize: self.fontSize,
            mode: .default,
            cacheKey: self.messageIdentity,
            contentHeight: self.$contentHeight
        )
        .frame(
            maxWidth: .infinity,
            minHeight: max(self.contentHeight, 1),
            alignment: .leading
        )
        .frame(height: max(self.contentHeight, 1))
    }
}

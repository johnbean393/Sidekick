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

    @State private var contentHeight: CGFloat = 1

    private var fontSize: CGFloat {
        NSFont.systemFontSize + 1
    }

    var body: some View {
        ChatMarkdownWebView(
            text: self.text,
            isStreaming: self.isStreaming,
            colorScheme: self.colorScheme,
            fontSize: self.fontSize,
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

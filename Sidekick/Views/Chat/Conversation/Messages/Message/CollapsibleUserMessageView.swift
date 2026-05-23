//
//  CollapsibleUserMessageView.swift
//  Sidekick
//
//  Created by Assistant on 11/6/25.
//

import SwiftUI

struct CollapsibleUserMessageView: View {

    var text: String
    /// Stable identity for the underlying user message. Used to key the
    /// per-message intrinsic-height cache the WKWebView renderer relies
    /// on. Optional — when nil, caching is skipped.
    var messageIdentity: String? = nil

    @State private var isExpanded: Bool?

    private let collapsedLineCount: Int = 15

    private var effectiveIsExpanded: Bool {
        // If isExpanded is nil (first load), determine based on line count.
        // Short messages (15 lines or less) start expanded.
        return isExpanded ?? (totalLineCount <= collapsedLineCount)
    }

    var totalLineCount: Int {
        return text.components(separatedBy: .newlines).count
    }

    var shouldShowExpandButton: Bool {
        return totalLineCount > collapsedLineCount
    }

    /// Source text to render through the Markdown view. When the message
    /// is long and the user hasn't expanded it, we feed the renderer
    /// only the leading slice — this keeps the rendered snippet
    /// proportional to the visual collapsed area and avoids the cost of
    /// rendering huge messages twice.
    var displayedContent: String {
        if effectiveIsExpanded || !shouldShowExpandButton {
            return text
        }
        let lines = text.components(separatedBy: .newlines)
        return lines.prefix(collapsedLineCount).joined(separator: "\n")
    }

    /// Cache key shared with ``MessageTextContentView``. We salt with the
    /// expansion state so the cached intrinsic height matches the slice
    /// of text we're actually rendering at the moment.
    private var renderIdentity: String? {
        guard let messageIdentity else { return nil }
        let suffix = self.effectiveIsExpanded ? "expanded" : "collapsed"
        return "user:\(messageIdentity):\(suffix)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !self.effectiveIsExpanded && self.shouldShowExpandButton {
                MessageTextContentView(
                    text: self.displayedContent,
                    isStreaming: false,
                    messageIdentity: self.renderIdentity
                )
                .frame(maxHeight: self.calculateCollapsedHeight(), alignment: .top)
                .clipped()
                .overlay(alignment: .bottom) {
                    VStack(spacing: 0) {
                        LinearGradient(
                            gradient: Gradient(stops: [
                                .init(color: Color(nsColor: .textBackgroundColor).opacity(0), location: 0),
                                .init(color: Color(nsColor: .textBackgroundColor).opacity(0.95), location: 0.5),
                                .init(color: Color(nsColor: .textBackgroundColor), location: 1)
                            ]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 50)
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                self.isExpanded = true
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 11, weight: .medium))
                                Text("Show all \(self.totalLineCount) lines")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.8))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 8)
                    }
                }
            } else {
                MessageTextContentView(
                    text: self.displayedContent,
                    isStreaming: false,
                    messageIdentity: self.renderIdentity
                )
            }

            if self.effectiveIsExpanded && self.shouldShowExpandButton {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        self.isExpanded = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 11, weight: .medium))
                        Text("Show less")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(.plain)
                .padding(.top, 10)
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// Visual height budget for the collapsed snippet. Sized off the
    /// rendered Markdown line metrics so a 15-line plain-text snippet
    /// shows ~all of its content under the gradient.
    private func calculateCollapsedHeight() -> CGFloat {
        let fontSize = NSFont.systemFontSize + 1.0
        // Match chat.css `--md-line-height: 1.55`.
        let lineHeight = fontSize * 1.55
        return CGFloat(self.collapsedLineCount) * lineHeight
    }
}



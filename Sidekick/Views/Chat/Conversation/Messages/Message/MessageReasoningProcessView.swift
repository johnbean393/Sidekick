//
//  MessageReasoningProcessView.swift
//  Sidekick
//
//  Created by John Bean on 2/6/25.
//

import AppKit
import SwiftUI

struct MessageReasoningProcessView: View {

    @Environment(\.colorScheme) private var colorScheme

    init(
        message: Message
    ) {
        let outputDidEnd: Bool = message.outputEnded
        let reasoningOutputDidEnd: Bool = message.reasoningText != nil && !message.responseText.isEmpty
        self._showReasoning = State(
            initialValue: !(outputDidEnd || reasoningOutputDidEnd)
        )
        self.message = message
        // Seed the cached reasoning height for the same reason the main
        // assistant message does — avoid a layout collapse when the
        // streaming host hands off to the persisted message view.
        let cacheKey = "reasoning:\(message.id.uuidString)"
        let seed: CGFloat = ChatMarkdownHeightCache.shared.height(for: cacheKey) ?? 1
        self._contentHeight = State(initialValue: seed)
    }

    @State var showReasoning: Bool
    @State private var contentHeight: CGFloat

    var message: Message

    private var reasoningText: String {
        return self.message.reasoningText ?? ""
    }

    private var isThinking: Bool {
        return !self.message.outputEnded && self.message.responseText.isEmpty
    }

    private var statusTitle: String {
        if self.isThinking {
            return "Thinking..."
        }
        return "Thought for \(self.formattedReasoningDuration)"
    }

    private var formattedReasoningDuration: String {
        // Prefer the moment the assistant finished its chain of
        // thought. Falls back to `lastUpdated` for messages persisted
        // before `reasoningEndTime` existed (or while reasoning is
        // still streaming, in which case `isThinking` is true and
        // this string isn't shown anyway).
        let endTime: Date = self.message.reasoningEndTime ?? self.message.lastUpdated
        let duration = max(
            0,
            endTime.timeIntervalSince(self.message.startTime)
        )
        if duration < 10 {
            return String(format: "%.2f seconds", duration)
        }
        return String(format: "%.0f seconds", duration)
    }

    /// Max height of the reasoning scroll viewport.
    private var viewportMaxHeight: CGFloat {
        self.isThinking ? 110 : 150
    }

    private var fontSize: CGFloat {
        // ~callout for the rendered Markdown so it stays visually
        // subordinate to the assistant's primary response.
        NSFont.systemFontSize - 1
    }

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 0
        ) {
            toggleReasoningButton.frame(height: 33)
            if self.showReasoning {
                Divider()
                reasoningPreview
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.purple.opacity(0.2))
        }
    }

    var toggleReasoningButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                self.showReasoning.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .frame(width: 10, height: 10)
                    .foregroundStyle(.purple)
                    .padding(.horizontal, 5)
                if self.isThinking {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: "brain.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.purple)
                }
                Text(self.statusTitle)
                    .font(.callout.weight(.semibold))
                    .opacity(0.8)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.up")
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary.opacity(0.8))
                    .rotationEffect(self.showReasoning ? .zero : .degrees(180))
            }
            .padding(.horizontal, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reasoning Process")
    }

    /// Inner viewport: a SwiftUI `ScrollView` containing the WKWebView so
    /// long reasoning traces can scroll inside the fixed-height window.
    /// The WKWebView itself doesn't scroll (its scroll-pass-through
    /// override forwards events to the enclosing scroll view).
    private var reasoningPreview: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ChatMarkdownWebView(
                        text: self.reasoningText,
                        isStreaming: self.isThinking,
                        colorScheme: self.colorScheme,
                        fontSize: self.fontSize,
                        mode: .reasoning,
                        cacheKey: "reasoning:\(self.message.id.uuidString)",
                        contentHeight: self.$contentHeight
                    )
                    .frame(
                        maxWidth: .infinity,
                        minHeight: max(self.contentHeight, 1),
                        alignment: .leading
                    )
                    .frame(height: max(self.contentHeight, 1))
                    Color.clear
                        .frame(height: 1)
                        .id("reasoning-bottom")
                }
                .padding(10)
            }
            .frame(
                minHeight: min(48, max(self.contentHeight + 20, 1)),
                maxHeight: self.viewportMaxHeight
            )
            .onAppear {
                self.scrollToBottom(proxy)
            }
            .onChange(of: self.reasoningText) { _, _ in
                self.scrollToBottom(proxy)
            }
            .onChange(of: self.contentHeight) { _, _ in
                self.scrollToBottom(proxy)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard self.isThinking else { return }
        DispatchQueue.main.async {
            proxy.scrollTo("reasoning-bottom", anchor: .bottom)
        }
    }

}

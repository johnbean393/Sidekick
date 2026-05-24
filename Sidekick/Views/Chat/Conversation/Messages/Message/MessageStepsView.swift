//
//  MessageStepsView.swift
//  Sidekick
//
//  Renders the per-iteration chain-of-thought + explainer text +
//  tool calls that the assistant produced during the agent loop.
//
//  Each step has its own collapsible reasoning banner (mirroring
//  ``MessageReasoningProcessView``), an optional Markdown body for
//  the user-facing narration the model emitted between thinking and
//  invoking tools, and a stack of function call pills for the tools
//  it ran at the end of the step.
//

import AppKit
import SwiftUI

/// Walks ``Message/steps`` and renders one ``MessageStepView`` per
/// captured iteration. The final iteration (the actual answer) is
/// not represented here — it lives in the parent
/// ``MessageContentView``'s reasoning banner + response text.
struct MessageStepsView: View {

    var message: Message

    var body: some View {
        // Single flat 4-pt VStack so every gap between adjacent pills
        // (reasoning banner ↔ explainer ↔ tool call, and crossing step
        // boundaries) is identical and visually consistent with the
        // legacy flat `FunctionCallsView` rhythm and the surrounding
        // `MessageContentView` VStack spacing.
        VStack(alignment: .leading, spacing: 4) {
            ForEach(self.message.steps) { step in
                MessageStepView(
                    messageId: self.message.id,
                    step: step
                )
            }
        }
    }
}

/// A single agent-loop iteration rendered as a self-contained card.
struct MessageStepView: View {

    @Environment(\.colorScheme) private var colorScheme

    init(messageId: UUID, step: MessageStep) {
        self.messageId = messageId
        self.step = step
        // Mirror MessageReasoningProcessView's seeding so the WKWebView
        // doesn't collapse on first paint while the height callback
        // settles.
        let cacheKey = "step-reasoning:\(messageId.uuidString):\(step.id.uuidString)"
        let seed: CGFloat = ChatMarkdownHeightCache.shared.height(for: cacheKey) ?? 1
        self._reasoningContentHeight = State(initialValue: seed)
    }

    private let messageId: UUID
    private let step: MessageStep

    @State private var showReasoning: Bool = false
    @State private var reasoningContentHeight: CGFloat

    private var fontSize: CGFloat {
        NSFont.systemFontSize - 1
    }

    private var statusTitle: String {
        if let duration = step.formattedReasoningDuration {
            return "Thought for \(duration)"
        }
        return "Thought"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if self.step.hasReasoning {
                self.reasoningBanner
            }
            if self.step.hasExplainerText {
                self.explainerBody
            }
            if !self.step.functionCallRecords.isEmpty {
                self.functionCalls
            }
        }
    }

    // MARK: - Reasoning banner

    private var reasoningBanner: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                    Image(systemName: "brain.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.purple)
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
                .frame(height: 33)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Step Reasoning Process")
            if self.showReasoning, let reasoning = self.step.reasoningText {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ChatMarkdownWebView(
                            text: reasoning,
                            isStreaming: false,
                            colorScheme: self.colorScheme,
                            fontSize: self.fontSize,
                            mode: .reasoning,
                            cacheKey: "step-reasoning:\(self.messageId.uuidString):\(self.step.id.uuidString)",
                            contentHeight: self.$reasoningContentHeight
                        )
                        .frame(
                            maxWidth: .infinity,
                            minHeight: max(self.reasoningContentHeight, 1),
                            alignment: .leading
                        )
                        .frame(height: max(self.reasoningContentHeight, 1))
                    }
                    .padding(10)
                }
                .frame(
                    minHeight: min(48, max(self.reasoningContentHeight + 20, 1)),
                    maxHeight: 150
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.purple.opacity(0.2))
        }
    }

    // MARK: - Explainer body

    private var explainerBody: some View {
        MessageTextContentView(
            text: self.step.explainerText,
            isStreaming: false,
            deprioritizeStreamingUpdates: false,
            messageIdentity: "step-explainer:\(self.messageId.uuidString):\(self.step.id.uuidString)"
        )
        .padding(.vertical, 2)
    }

    // MARK: - Function calls

    private var functionCalls: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(self.step.functionCallRecords, id: \.self) { call in
                FunctionCallsView.FunctionCallView(functionCall: call)
            }
        }
    }
}

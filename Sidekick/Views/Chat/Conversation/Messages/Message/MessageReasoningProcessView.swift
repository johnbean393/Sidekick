//
//  MessageReasoningProcessView.swift
//  Sidekick
//
//  Created by John Bean on 2/6/25.
//

import SwiftUI

struct MessageReasoningProcessView: View {

	init(
		message: Message
	) {
		let outputDidEnd: Bool = message.outputEnded
		let reasoningOutputDidEnd: Bool = message.reasoningText != nil && !message.responseText.isEmpty
		self._showReasoning = State(
			initialValue: !(outputDidEnd || reasoningOutputDidEnd)
		)
		self.message = message
	}
	
	@State var showReasoning: Bool

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
        let duration = max(
            0,
            self.message.lastUpdated.timeIntervalSince(self.message.startTime)
        )
        if duration < 10 {
            return String(format: "%.2f seconds", duration)
        }
        return String(format: "%.0f seconds", duration)
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

    private var reasoningPreview: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(self.reasoningText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear
                        .frame(height: 1)
                        .id("reasoning-bottom")
                }
                .padding(10)
            }
            .frame(minHeight: 48, maxHeight: self.isThinking ? 110 : 150)
            .onAppear {
                self.scrollToBottom(proxy)
            }
            .onChange(of: self.reasoningText) { _, _ in
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

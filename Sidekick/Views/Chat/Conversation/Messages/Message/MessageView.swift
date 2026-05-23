//
//  MessageView.swift
//  Sidekick
//
//  Created by Bean John on 10/8/24.
//

import AppKit
import SwiftUI

struct MessageView: View {
	
    @Environment(\.openWindow) var openWindow
    
    @EnvironmentObject private var model: Model
	@Environment(ConversationManager.self) private var conversationManager
	@Environment(ConversationState.self) private var conversationState
	@Environment(PromptController.self) private var promptController
    @Environment(MemoryIndex.self) private var memories
    
    @State private var isEditing: Bool = false
	@State private var isShowingSources: Bool = false
	@State private var isHovered: Bool = false
	/// Pending hide of the hover chips. Debounced so the user has
	/// time to move from the bubble across the gap to a chip — and
	/// so a stray `false` from the embedded WKWebView doesn't yank
	/// the controls out from under the pointer mid-click.
	@State private var hoverHideTask: Task<Void, Never>?
	/// Grace period before the chips fade out after the pointer
	/// leaves the message frame.
	private static let chipHideDelay: Duration = .milliseconds(280)
	
    var message: Message
    var shimmer: Bool = false
    var deprioritizeStreamingUpdates: Bool = false
    
    private var isGenerating: Bool {
        return !message.outputEnded && message.getSender() == .assistant
    }
    
    var selectedConversation: Conversation? {
        return self.conversationState.selectedConversation
    }
    
	var sources: Sources? {
		SourcesStore.getSources(id: message.id)
	}
	
	var showSources: Bool {
		let hasSources: Bool = !(sources?.sources.isEmpty ?? true)
		return hasSources && self.message.getSender() == .user
	}
    
    var memory: Memory? {
        return memories.getMemories(
            id: message.id
        )
    }
    
    var hasMemories: Bool {
        return (memory != nil)
    }
	
	private var timeDescription: String {
		return message.startTime.formatted(
			date: .abbreviated,
			time: .shortened
		)
	}
	
    var body: some View {
		HStack(
			alignment: .top,
			spacing: 0
		) {
			message.icon
				.padding(.trailing, 10)
			VStack(
				alignment: .leading,
				spacing: 8
			) {
				controls
				content
			}
		}
		.padding(.trailing)
		.contentShape(Rectangle())
		.onHover { hovering in
			self.updateHoverState(hovering)
		}
		.sheet(isPresented: $isShowingSources) {
			SourcesView(
				isShowingSources: $isShowingSources,
				sources: self.sources!
			)
			.frame(minWidth: 600, minHeight: 650, maxHeight: 700)
		}
    }
    
    var controls: some View {
        HStack {
            Text(timeDescription)
                .foregroundStyle(.secondary)
            // Stop button stays visible even when the chip row is
            // hidden — the user needs to be able to interrupt a
            // streaming reply without hunting for hover targets.
            if self.isGenerating {
                StopGenerationButton {
                    Task { @MainActor in
                        await self.model.interrupt()
                    }
                }
            }
            // Hover-revealed action chips, mirrored to user and
            // assistant messages so both sides get Copy / Rerun /
            // Edit / More affordances.
            actionChips
                .opacity(self.isHovered ? 1 : 0)
                .allowsHitTesting(self.isHovered)
                .onHover { hovering in
                    // Track the chip row directly so a brief gap
                    // between the bubble and the chips (or a
                    // child WebView swallowing the move event)
                    // doesn't cause the row to vanish mid-click.
                    self.updateHoverState(hovering)
                }
            if hasMemories, let memory {
                Spacer()
                // Show memory updated
                PopoverButton(
                    arrowEdge: .bottom
                ) {
                    Label("Memory updated", systemImage: "pencil.and.list.clipboard")
                        .foregroundStyle(.secondary)
                } content: {
                    VStack {
                        Text(memory.text)
                            .font(.body)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button {
                                self.memories.forget(memory)
                            } label: {
                                Text("Forget")
                                    .foregroundStyle(.red)
                            }
                            Button {
                                self.openWindow(id: "memory")
                            } label: {
                                Text("Manage Memories")
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(maxWidth: 400, maxHeight: 80)
                }
                .buttonStyle(.plain)
                .padding(.top, 3)
            }
        }
    }
    
    /// Inline hover-revealed action chips that match the ChatWise
    /// layout: Copy / Rerun / Edit / More. Applied to user and
    /// assistant messages alike. Hidden during generation because
    /// the actions would race the streaming output.
    var actionChips: some View {
        HStack {
            if showSources {
                sourcesButton
            }
            MessageCopyButton(message: message)
            if !self.isGenerating {
                RegenerateButton {
                    self.retryGeneration(message: message)
                }
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
            }
            if !self.isGenerating && !self.isEditing {
                editChip
            }
            MessageOptionsView(
                isEditing: $isEditing,
                message: message,
                canEdit: !self.isGenerating
            )
        }
    }
    
    var editChip: some View {
        Button {
            withAnimation(.linear(duration: 0.5)) {
                self.isEditing.toggle()
            }
        } label: {
            Image(systemName: "pencil")
                .imageScale(.medium)
                .background(.clear)
                .imageScale(.small)
                .padding(.leading, 1)
                .padding(.horizontal, 3)
                .frame(width: 15, height: 15)
                .scaleEffect(CGSize(width: 0.96, height: 0.96))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Edit")
    }
	
	var content: some View {
		Group {
			// Check for blank message or function calls
			if message.text.isEmpty && message.imageUrl == nil && message
                .getSender() == .assistant && self.message.outputEnded {
				RegenerateButton {
					self.retryGeneration(
                        message: message
                    )
				}
                .labelStyle(.titleAndIcon)
				.padding(11)
			} else {
                MessageContentView(
                    message: self.message,
                    isEditing: self.$isEditing,
                    shimmer: self.shimmer,
                    deprioritizeStreamingUpdates: self.deprioritizeStreamingUpdates
                )
			}
		}
		.background {
			MessageBackgroundView()
				.contextMenu {
					copyButton
				}
		}
	}
	
	var sourcesButton: some View {
		SourcesButton(showSources: $isShowingSources)
			.menuStyle(.circle)
			.foregroundStyle(.secondary)
			.disabled(!showSources)
			.padding(0)
			.padding(.vertical, 2)
	}
	
	var copyButton: some View {
		Button {
			self.message.text.copyWithFormatting()
		} label: {
			Text("Copy to Clipboard")
		}
	}
	
	/// Updates ``isHovered`` with a small debounce on the way out
	/// so the action chips don't disappear under the user's cursor
	/// while they're trying to click one.
	private func updateHoverState(_ hovering: Bool) {
		self.hoverHideTask?.cancel()
		self.hoverHideTask = nil
		if hovering {
			if !self.isHovered {
				withAnimation(.easeInOut(duration: 0.15)) {
					self.isHovered = true
				}
			}
			return
		}
		self.hoverHideTask = Task { @MainActor in
			try? await Task.sleep(for: Self.chipHideDelay)
			if Task.isCancelled { return }
			withAnimation(.easeInOut(duration: 0.15)) {
				self.isHovered = false
			}
		}
	}
	
	/// Re-runs the prompt that produced `message` (or, when `message`
	/// is itself a user prompt, re-runs `message`) directly through
	/// the existing send pipeline. Resolves the user prompt to
	/// resubmit, stages the request on ``PromptController``, and lets
	/// ``PromptInputField`` truncate the trailing messages and call
	/// `submit()`. Does **not** touch ``PromptController/prompt`` so
	/// nothing leaks into the prompt field.
	private func retryGeneration(
        message: Message
    ) {
        guard let conversation = self.selectedConversation else { return }
        // Resolve the user prompt to resend and the conversation
        // anchor to truncate to.
        let anchorUserMessage: Message?
        switch message.getSender() {
            case .user:
                anchorUserMessage = message
            default:
                // Walk backwards from this message to find the most
                // recent user prompt. Falls back to the conversation's
                // last user message for safety.
                anchorUserMessage = conversation.messages.previousElement(of: message)
                    ?? conversation.messages.last(where: { $0.getSender() == .user })
        }
        guard let userMessage = anchorUserMessage,
              userMessage.getSender() == .user else {
            return
        }
        let attachments: [URL] = userMessage.referencedURLs.map(\.url)
        self.promptController.requestResubmit(
            .init(
                prompt: userMessage.text,
                attachments: attachments,
                dropAfterMessageId: userMessage.id
            )
        )
	}
	
}

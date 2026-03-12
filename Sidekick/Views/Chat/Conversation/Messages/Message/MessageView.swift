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
    
	@EnvironmentObject private var conversationManager: ConversationManager
	@EnvironmentObject private var conversationState: ConversationState
	@EnvironmentObject private var promptController: PromptController
    @EnvironmentObject private var memories: Memories
    
    @State private var isEditing: Bool = false
	@State private var isShowingSources: Bool = false
	
    var message: Message
    var shimmer: Bool = false
    var deprioritizeStreamingUpdates: Bool = false
    
    private var isGenerating: Bool {
        return !message.outputEnded && message.getSender() == .assistant
    }
    
    var selectedConversation: Conversation? {
        guard let selectedConversationId = conversationState.selectedConversationId else {
            return nil
        }
        return self.conversationManager.getConversation(
            id: selectedConversationId
        )
    }
    
	var sources: Sources? {
		SourcesManager.shared.getSources(
			id: message.id
		)
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
            if showSources {
                sourcesButton
            }
            MessageCopyButton(
                message: message
            )
            if message.getSender() == .assistant {
                MessageReadAloudButton(
                    message: message
                )
                if !self.isGenerating {
                    RegenerateButton {
                        self.retryGeneration(
                            message: message
                        )
                    }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                }
            }
            MessageOptionsView(
                isEditing: $isEditing,
                message: message,
                canEdit: !self.isGenerating
            )
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
	
	private func retryGeneration(
        message: Message
    ) {
		// Get conversation
        guard var conversation = self.selectedConversation else { return }
		// Get drop count
        var count: Int = 0
        if let messageIndex = conversation.messages.firstIndex(where: { currMessage in
            currMessage.id == message.id
        }) {
            count = conversation.messages.count - (messageIndex - 1)
        } else {
            // If index not found, is pending message
            count = 1
        }
        // Check for safety
        count = max(min(count, conversation.messages.count), 0)
        // Set prompt
        let prevMessage: Message? = conversation.messages.previousElement(
            of: message
        ) ?? conversation.messages.last
        self.promptController.prompt = prevMessage?.text ?? ""
        // Set resources
        let urls: [URL] = prevMessage?.referencedURLs.map(
            keyPath: \.url
        ) ?? []
        self.promptController.tempResources += urls.map { url in
            return TemporaryResource(url: url)
        }
        // Delete messages
        conversation.messages = conversation.messages.dropLast(count)
		conversationManager.update(conversation)
	}
	
}

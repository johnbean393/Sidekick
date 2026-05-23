//
//  MessageOptionsView.swift
//  Sidekick
//
//  Created by Bean John on 11/12/24.
//

import MarkdownUI
import Splash
import SwiftUI

struct MessageOptionsView: View {
	
	@Environment(\.colorScheme) private var colorScheme
    @Environment(PromptController.self) private var promptController
    @Environment(ConversationManager.self) private var conversationManager
    @Environment(ConversationState.self) private var conversationState
    
    @StateObject private var speechSynthesizer: SpeechSynthesizer = .shared
	
	@State private var showNerdInfo: Bool = false
    @Binding var isEditing: Bool
	
	var message: Message
	var canEdit: Bool
	
	private var theme: Splash.Theme {
		switch self.colorScheme {
			case .dark: return .wwdc17(withFont: .init(size: 16))
			default: return .sunset(withFont: .init(size: 16))
		}
	}
	
	private var isGenerating: Bool {
		return !message.outputEnded && message.getSender() == .assistant
	}
    
    /// The conversation that owns ``message``. Looked up on demand
    /// so destructive actions always operate on the freshest copy.
    private var selectedConversation: Conversation? {
        return self.conversationState.selectedConversation
    }
    
    /// `true` when this user message has an assistant reply
    /// immediately after it that "Delete response" can target.
    private var hasPairedAssistantResponse: Bool {
        guard self.message.getSender() == .user,
              let conversation = self.selectedConversation,
              let index = conversation.messages.firstIndex(where: { $0.id == self.message.id }) else {
            return false
        }
        let nextIndex: Int = index + 1
        guard nextIndex < conversation.messages.count else { return false }
        return conversation.messages[nextIndex].getSender() == .assistant
    }
	
	private var nerdInfo: String {
		var tokensPerSecondStr: String = "Unknown"
		if let tokensPerSecond = message.tokensPerSecond {
			tokensPerSecondStr = "\(round(tokensPerSecond * 10) / 10)"
		}
		let infoDescription: String.LocalizationValue = """
Model: \(message.model)
Tokens per second: \(tokensPerSecondStr)
"""
		return String(localized: infoDescription)
	}
	
    var body: some View {
		Menu {
			optionsMenu
		} label: {
			Image(systemName: "ellipsis")
				.imageScale(.medium)
				.background(.clear)
				.imageScale(.small)
				.padding(.leading, 1)
				.padding(.horizontal, 3)
				.frame(width: 15, height: 15)
				.scaleEffect(CGSize(width: 0.96, height: 0.96))
				.foregroundStyle(.secondary)
				.background(.primary.opacity(0.00001)) // Needs to be clickable
		}
		.menuStyle(.circle)
		.popover(isPresented: $showNerdInfo) {
			Text(nerdInfo)
				.padding(12)
				.font(.caption)
				.textSelection(.enabled)
		}
		.disabled(isGenerating)
		.padding(0)
		.padding(.vertical, 2)
    }
	
	@ViewBuilder
	var optionsMenu: some View {
		// Copy group
		Button {
			self.message.text.copyWithFormatting()
		} label: {
			Label("Copy Message", systemImage: "square.on.square")
		}
		Button {
			self.message.text.copy()
		} label: {
			Label("Copy Raw Markdown", systemImage: "doc.on.doc")
		}
		Divider()
		// Playback
		Button {
			self.speechSynthesizer.toggleReading(text: self.message.readableText)
		} label: {
			if self.speechSynthesizer.isSpeaking {
				Label("Stop Reading", systemImage: "speaker.slash.fill")
			} else {
				Label("Read Aloud", systemImage: "speaker.wave.3")
			}
		}
		// Editing & regeneration
		if self.canEdit && !self.isEditing {
			Button {
				withAnimation(.linear(duration: 0.5)) {
					self.isEditing.toggle()
				}
			} label: {
				Label("Edit", systemImage: "pencil")
			}
		}
		if !self.isGenerating {
			Button {
				self.regenerate()
			} label: {
				Label("Regenerate", systemImage: "arrow.trianglehead.clockwise")
			}
		}
		Divider()
		// Conversation surgery
		Button {
			self.forkConversation()
		} label: {
			Label("Start a New Chat From Here", systemImage: "arrow.branch")
		}
		if self.hasPairedAssistantResponse {
			Button {
				self.deleteResponse()
			} label: {
				Label("Delete Response", systemImage: "arrow.uturn.backward")
			}
		}
		Button(role: .destructive) {
			self.deleteMessage()
		} label: {
			Label("Delete Message", systemImage: "trash")
		}
		.disabled(self.isGenerating)
		// Export submenus — Screenshot (PNG) and Save as PDF, each
		// with the same three scopes. Both routes share
		// ``ChatScreenshotExporter`` and render offscreen via a
		// WKWebView (SwiftUI's ImageRenderer can't see the chat
		// because the body is hosted in AppKit web content).
		Divider()
		Menu {
			Button {
				self.exportChat(.entireChat, as: .png)
			} label: {
				Label("Entire Chat", systemImage: "rectangle.stack")
			}
			Button {
				self.exportChat(.currentTurn(anchorId: self.message.id), as: .png)
			} label: {
				Label("Current Turn", systemImage: "bubble.left.and.bubble.right")
			}
			Button {
				self.exportChat(.singleMessage(id: self.message.id), as: .png)
			} label: {
				Label("Current Message", systemImage: "rectangle")
			}
		} label: {
			Label("Screenshot", systemImage: "camera")
		}
		.disabled(self.canCaptureScreenshot == false)
		Menu {
			Button {
				self.exportChat(.entireChat, as: .pdf)
			} label: {
				Label("Entire Chat", systemImage: "rectangle.stack")
			}
			Button {
				self.exportChat(.currentTurn(anchorId: self.message.id), as: .pdf)
			} label: {
				Label("Current Turn", systemImage: "bubble.left.and.bubble.right")
			}
			Button {
				self.exportChat(.singleMessage(id: self.message.id), as: .pdf)
			} label: {
				Label("Current Message", systemImage: "rectangle")
			}
		} label: {
			Label("Save as PDF", systemImage: "doc.richtext")
		}
		.disabled(self.canCaptureScreenshot == false)
		// Diagnostics
		if message.getSender() == .assistant {
			Divider()
			Button {
				showNerdInfo.toggle()
			} label: {
				Label("Stats for Nerds", systemImage: "info.circle")
			}
		}
	}
	
	/// Disable the screenshot menu while the assistant is still
	/// streaming — capturing an in-flight bubble produces a
	/// half-rendered image and races the WebKit layout.
	private var canCaptureScreenshot: Bool {
		guard let conversation = self.selectedConversation else { return false }
		return !self.isGenerating && !conversation.messages.isEmpty
	}
	
	/// Spawns the export pipeline on a detached task so the
	/// SwiftUI menu can dismiss immediately. The exporter handles
	/// its own progress HUD, save panel, and error reporting for
	/// both PNG screenshots and PDFs.
	private func exportChat(
		_ scope: ChatScreenshotScope,
		as format: ChatScreenshotFormat
	) {
		guard let conversation = self.selectedConversation else { return }
		let resolvedColorScheme: ColorScheme = self.colorScheme
		Task { @MainActor in
			let exporter = ChatScreenshotExporter()
			await exporter.capture(
				scope: scope,
				format: format,
				conversation: conversation,
				colorScheme: resolvedColorScheme
			)
		}
	}
	
	// MARK: - Actions
	
	/// Re-runs the prompt that produced this message (or the message
	/// itself when it's a user prompt) through the existing send
	/// pipeline. Mirrors ``MessageView/retryGeneration(message:)``.
	private func regenerate() {
		guard let conversation = self.selectedConversation else { return }
		let anchorUserMessage: Message?
		switch self.message.getSender() {
			case .user:
				anchorUserMessage = self.message
			default:
				anchorUserMessage = conversation.messages.previousElement(of: self.message)
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
	
	/// Spawns a new conversation that contains every message up to
	/// and including this one, then switches the sidebar selection
	/// to the fork so the user can continue from a different angle.
	private func forkConversation() {
		guard let conversation = self.selectedConversation,
			  let forked = conversation.fork(at: self.message.id) else {
			return
		}
		// Mirror ``ConversationState/newConversation`` placement so
		// the fork shows up at the top of the sidebar instead of the
		// bottom; ``ConversationManager/add(_:)`` appends, which
		// would otherwise bury new chats.
		withAnimation(.spring()) {
			var conversations: [Conversation] = self.conversationManager.conversations
			conversations.insert(forked, at: 0)
			self.conversationManager.conversations = conversations
			self.conversationState.selectedConversationId = forked.id
		}
	}
	
	/// Removes the assistant message paired with this user prompt,
	/// leaving the user prompt itself untouched.
	private func deleteResponse() {
		guard var conversation = self.selectedConversation else { return }
		guard conversation.deleteAssistantResponse(pairedWith: self.message.id) else {
			return
		}
		withAnimation(.spring()) {
			self.conversationManager.update(conversation)
		}
	}
	
	/// Removes just this message from the conversation.
	private func deleteMessage() {
		guard var conversation = self.selectedConversation else { return }
		conversation.removeMessage(id: self.message.id)
		withAnimation(.spring()) {
			self.conversationManager.update(conversation)
		}
	}
	
}

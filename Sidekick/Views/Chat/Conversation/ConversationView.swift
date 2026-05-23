//
//  ConversationView.swift
//  Sidekick
//
//  Created by Bean John on 10/8/24.
//

import SwiftUI
import ImagePlayground

struct ConversationView: View {
	
	@State private var promptController: PromptController = .init()
	
	@Environment(ConversationManager.self) private var conversationManager
		@Environment(ConversationState.self) private var conversationState
	
	var body: some View {
		@Bindable var promptController = self.promptController
		Group {
			if #available(macOS 15.2, *) {
				messages
					.imagePlaygroundSheet(
						isPresented: $promptController.isGeneratingImage,
						// Image playground concepts
						concepts: [
							ImagePlaygroundConcept.extracted(
								from: self.promptController.imageConcept ?? "",
								title: nil
							)
						]
					) { url in
						// Save the image to the conversation
						self.addImageToConversation(url)
					} onCancellation: {
						self.cancelImageGeneration()
					}
			} else {
				messages
			}
		}
		.environment(promptController)
	}
	
	var messages: some View {
		MessagesView()
			.padding(.leading)
			.overlay(alignment: .bottom) {
				ConversationControlsView()
					.padding(.trailing, 30)
			}
	}
	
	/// Function to add an image to the current conversation
	private func addImageToConversation(
		_ imageUrl: URL
	) {
		// Copy image
		let copiedImageDir: URL = Settings.containerUrl.appendingPathComponent(
			"Generated Images"
		)
		let copiedImageUrl: URL = copiedImageDir.appendingPathComponent(
			imageUrl.lastPathComponent
		)
		try? FileManager.default.createDirectory(
			at: copiedImageDir,
			withIntermediateDirectories: true
		)
		try? FileManager.default.copyItem(at: imageUrl, to: copiedImageUrl)
		// Formulate message
		let message: Message = Message(
			imageUrl: copiedImageUrl,
			prompt: self.promptController.imageConcept ?? "",
			expertId: promptController.sentExpertId
		)
		// Add message to conversation
		guard var currentConversation: Conversation = self.conversationState.selectedConversation else {
			print("Could not get conversation")
			return
		}
		let _ = currentConversation.addMessage(message)
		// Save. If this image landed in the in-memory blank chat,
		// promote it into the persisted store; otherwise update in
		// place as before.
		withAnimation(.linear) {
			if !self.conversationState.commitDraftIfNeeded(currentConversation) {
				self.conversationManager.update(currentConversation)
			}
		}
	}
	
	/// Function to handle image generation cancellation
	private func cancelImageGeneration() {
		// Remove previous message from conversation. By the time
		// we get here the conversation must already be persisted
		// (the user sent a prompt to produce the cancelled image),
		// so we can rely on the regular ``update`` path.
		guard var currentConversation: Conversation = self.conversationState.selectedConversation else {
			print("Could not get conversation")
			return
		}
		currentConversation.dropLastMessage()
		// Save
		withAnimation(.linear) {
			self.conversationManager.update(currentConversation)
		}
	}
	
}

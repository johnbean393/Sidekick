//
//  ConversationControlsView.swift
//  Sidekick
//
//  Created by Bean John on 10/8/24.
//

import SwiftUI
import SimilaritySearchKit

struct ConversationControlsView: View {
	
	@EnvironmentObject private var model: Model
	@EnvironmentObject private var conversationManager: ConversationManager
	@EnvironmentObject private var profileManager: ProfileManager
	@EnvironmentObject private var conversationState: ConversationState
	
	@FocusState private var isFocused: Bool
	
	@State private var prompt: String = ""
	
	@State private var sentConversation: Conversation? = nil
	
	var selectedConversation: Conversation? {
		guard let selectedConversationId = conversationState.selectedConversationId else {
			return nil
		}
		return self.conversationManager.getConversation(
			id: selectedConversationId
		)
	}
	
	var selectedProfile: Profile? {
		guard let selectedProfileId = conversationState.selectedProfileId else {
			return nil
		}
		return profileManager.getProfile(id: selectedProfileId)
	}
	@State private var profile: Profile = ProfileManager.shared.firstProfile!
	
	var messages: [Message] {
		return selectedConversation?.messages ?? []
	}
	
	var showQuickPrompts: Bool {
		return prompt.isEmpty && messages.isEmpty
	}
	
	var body: some View {
		VStack {
			if showQuickPrompts {
				ConversationQuickPromptsView(input: $prompt)
			}
			HStack {
				inputField
				if conversationState.selectedProfileId != nil {
					ConversationResourceButton(
						profile: $profile
					)
					.keyboardShortcut("r", modifiers: .command)
				}
			}
		}
	}
	
	var inputField: some View {
		TextField(
			"Message",
			text: $prompt.animation(.linear),
			axis: .vertical
		)
		.onSubmit(onSubmit)
		.focused($isFocused)
		.textFieldStyle(ChatStyle(isFocused: _isFocused))
		.submitLabel(.send)
		.padding([.vertical, .leading], 10)
		.onChange(of: conversationState.selectedConversationId) {
			self.isFocused = true
		}
		.onExitCommand {
			self.isFocused = false
		}
		.onReceive(
			NotificationCenter.default.publisher(
				for: Notifications.didSelectConversation.name
			)
		) { output in
			self.isFocused = false
		}
	}
	
	private func onSubmit() {
		// New line if shift or option pressed
		if CGKeyCode.kVK_Shift.isPressed || CGKeyCode.kVK_Option.isPressed {
			prompt += "\n"
		} else if prompt.trimmingCharacters(in: .whitespacesAndNewlines) != "" {
			// Send message
			self.submit()
		}
	}
	
	private func submit() {
		// Get previous content
		guard var conversation = selectedConversation else { return }
		// Make request message
		let newUserMessage: Message = Message(
			text: prompt,
			sender: .user
		)
		let _ = conversation.addMessage(newUserMessage)
		conversationManager.update(conversation)
		prompt = ""
		// Set sentConversation
		sentConversation = conversation
		// Get response
		Task {
			await getResponse()
		}
	}
	
	private func getResponse() async {
		// If processing, use recursion to update
		if (model.status == .processing || model.status == .coldProcessing) {
			Task {
				await model.interrupt()
				Task.detached(priority: .userInitiated) {
					try? await Task.sleep(for: .seconds(1))
					await getResponse()
				}
			}
			return
		}
		// Get conversation
		guard var conversation = sentConversation else { return }
		// Get response
		var response: LlamaServer.CompleteResponse
		do {
			let index: SimilarityIndex? = await selectedProfile?.resources.loadIndex()
			response = try await model.listenThinkRespond(
				sentConversationId: conversation.id,
				messages: self.messages,
				similarityIndex: index
			)
		} catch let error as LlamaServerError {
			print("Interupted response: \(error)")
			await model.interrupt()
			handleResponseError(error)
			return
		} catch {
			print("Agent listen threw unexpected error", error as Any)
			return
		}
		// Update UI
		await MainActor.run {
			// Exit if conversation is inactive
			if self.selectedConversation?.id != conversation.id {
				return
			}
			// Output final output to debug console
			// Make response message
			var responseMessage: Message = Message(
				text: "",
				sender: .assistant
			)
			responseMessage.update(
				newText: response.text,
				tokensPerSecond: response.predictedPerSecond ,
				responseStartSeconds: response.responseStartSeconds
			)
			responseMessage.end()
			// Update conversation
			let _ = conversation.addMessage(
				responseMessage
			)
			conversationManager.update(conversation)
			// Reset sendConversation
			self.sentConversation = nil
		}
	}
	
	@MainActor
	func handleResponseError(_ error: LlamaServerError) {
		print("Handle response error:", error.localizedDescription)
		let errorDescription: String = error.errorDescription ?? "Unknown Error"
		let recoverySuggestion: String = error.recoverySuggestion
		Dialogs.showAlert(
			title: "\(errorDescription): \(recoverySuggestion)"
		)
	}
	
}

//
//#Preview {
//    ConversationControlsView()
//}
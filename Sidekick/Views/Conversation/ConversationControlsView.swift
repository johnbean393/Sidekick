//
//  ConversationControlsView.swift
//  Sidekick
//
//  Created by Bean John on 10/8/24.
//

import SwiftUI
import SimilaritySearchKit

struct ConversationControlsView: View {
	
	@StateObject private var promptController: PromptController = .init()
	
	@EnvironmentObject private var model: Model
	@EnvironmentObject private var conversationManager: ConversationManager
	@EnvironmentObject private var profileManager: ProfileManager
	@EnvironmentObject private var conversationState: ConversationState
	
	@FocusState private var isFocused: Bool

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
	@State private var profile: Profile = .default
	
	var messages: [Message] {
		return selectedConversation?.messages ?? []
	}
	
	var showQuickPrompts: Bool {
		return promptController.prompt.isEmpty && messages.isEmpty
	}
	
	var body: some View {
		VStack {
			if showQuickPrompts {
				ConversationQuickPromptsView(
					input: $promptController.prompt
				)
			}
			HStack(spacing: 0) {
				inputField
				if conversationState.selectedProfileId != nil {
					ConversationResourceButton(
						profile: $profile
					)
					.keyboardShortcut("r", modifiers: .command)
					.padding(.leading, 7)
				}
				if ProcessInfo.processInfo.operatingSystemVersion.majorVersion <= 14 {
					lengthyTasksButton
				}
			}
		}
		.padding(.leading)
		.onChange(of: conversationState.selectedConversationId) {
			self.isFocused = true
			self.conversationState.selectedProfileId = profileManager.default?.id
		}
		.onChange(of: conversationState.selectedProfileId) {
			guard let selectedProfile else {
				return
			}
			self.profile = selectedProfile
		}
		.onReceive(
			NotificationCenter.default.publisher(
				for: Notifications.didSelectProfile.name
			)
		) { output in
			self.updateProfile()
		}
	}
	
	var inputField: some View {
		TextField(
			"Send a Message",
			text: $promptController.prompt.animation(.linear),
			axis: .vertical
		)
		.onSubmit(onSubmit)
		.focused($isFocused)
		.textFieldStyle(
			ChatStyle(
				isFocused: _isFocused,
				isRecording: $promptController.isRecording
			)
		)
		.overlay(alignment: .trailing) {
			recordingButton
		}
		.submitLabel(.send)
		.padding([.vertical, .leading], 10)
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
	
	var recordingButton: some View {
		Button {
			withAnimation(.linear) {
				self.promptController.toggleRecording()
			}
		} label: {
			Label("", systemImage: "microphone.fill")
				.foregroundStyle(
					promptController.isRecording ? .red : .secondary
				)
		}
		.buttonStyle(.plain)
		.padding([.trailing, .bottom], 3)
	}
	
	var lengthyTasksButton: some View {
		LengthyTasksToolbarButton(
			usePadding: true
		)
		.labelStyle(.iconOnly)
		.buttonStyle(ChatButtonStyle())
		.padding(.leading, 7)
	}
	
	/// Function to update the profile shown in the profile resource button
	private func updateProfile() {
		guard let selectedProfileId = conversationState.selectedProfileId else {
			return
		}
		guard let profile = profileManager.getProfile(id: selectedProfileId) else {
			return
		}
		self.profile = profile
	}
	
	/// Function to run when the `return` key is hit
	private func onSubmit() {
		// New line if shift or option pressed
		if CGKeyCode.kVK_Shift.isPressed || CGKeyCode.kVK_Option.isPressed {
			promptController.prompt += "\n"
		} else if promptController.prompt.trimmingCharacters(in: .whitespacesAndNewlines) != "" {
			// End recording
			self.promptController.stopRecording()
			// Send message
			self.submit()
		}
	}
	
	/// Function to send to bot
	private func submit() {
		// Make sound
		if Settings.playSoundEffects {
			SoundEffects.send.play()
		}
		// Get previous content
		guard var conversation = selectedConversation else { return }
		// Make request message
		let newUserMessage: Message = Message(
			text: promptController.prompt,
			sender: .user
		)
		let _ = conversation.addMessage(newUserMessage)
		conversationManager.update(conversation)
		// Set sentConversation
		sentConversation = conversation
		// Clear prompt
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
			self.promptController.prompt.removeAll()
		}
		// Get response
		Task {
			await self.getResponse()
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
			self.model.indicateStartedQuerying(
				sentConversationId: conversation.id
			)
			var index: SimilarityIndex? = nil
			// If there are resources
			if !((selectedProfile?.resources.resources.isEmpty) ?? true) {
				// Load
				index = await selectedProfile?.resources.loadIndex()
			}
			let useWebSearch: Bool = selectedProfile?.useWebSearch ?? true
			response = try await model.listenThinkRespond(
				messages: self.messages,
				similarityIndex: index,
				useWebSearch: useWebSearch
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
			// Make sound
			if Settings.playSoundEffects {
				SoundEffects.ping.play()
			}
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

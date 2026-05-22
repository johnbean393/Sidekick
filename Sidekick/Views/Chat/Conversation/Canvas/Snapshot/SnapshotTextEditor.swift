//
//  SnapshotTextEditor.swift
//  Sidekick
//
//  Created by John Bean on 3/20/25.
//

import CodeEditorView
import LanguageSupport
import SwiftUI

struct SnapshotTextEditor: View {
	
	@EnvironmentObject private var canvasController: CanvasController
	@Environment(ConversationState.self) private var conversationState
	@Environment(ConversationManager.self) private var conversationManager
	
	@Environment(\.colorScheme) private var colorScheme: ColorScheme
	@State private var messages: Set<TextLocated<LanguageSupport.Message>> = Set()
	
	var selectedConversation: Conversation? {
		guard let selectedConversationId = conversationState.selectedConversationId else {
			return nil
		}
		return self.conversationManager.getConversation(
			id: selectedConversationId
		)
	}
	
	var selectedSnapshotId: UUID? {
		guard let selectedMessageId = canvasController.selectedMessageId else {
			return nil
		}
		return selectedConversation?.getMessage(selectedMessageId)?.snapshot?.id
	}
	
	var selection: String? {
		// Get parameters
		guard let range = canvasController.position.selections.first else {
			return nil
		}
		let nsString: NSString = self.text as NSString
		// Validate the NSRange to ensure it is within the bounds of the string
		guard range.location < nsString.length,
			  range.location + range.length <= nsString.length else {
			return nil
		}
		return nsString.substring(with: range)
	}
	
	@State private var text: String = ""
	
	var body: some View {
		CodeEditor(
			text: self.$text,
			position: self.$canvasController.position,
			messages: self.$messages
		)
		.environment(
			\.codeEditorTheme, colorScheme == .dark ? Theme.defaultDark : Theme.defaultLight
		)
		.onAppear {
			self.loadSnapshotText()
		}
		.onChange(
			of: self.conversationState.selectedExpertId
		) {
			self.loadSnapshotText()
		}
		.onChange(
			of: self.canvasController.selectedMessageId
		) {
			self.loadSnapshotText()
		}
		.onChange(
			of: self.selectedSnapshotId
		) {
			self.loadSnapshotText()
		}
		.onChange(
			of: self.text
		) {
			self.saveSnapshotText()
		}
		.onChange(
			of: self.selection
		) {
			self.canvasController.selection = self.selection ?? ""
		}
	}
	
	/// Function to load the text from the currently selected snapshot
	private func loadSnapshotText() {
		// Reset selection
		self.canvasController.position = CodeEditor.Position()
		// Get text
		guard let conversation = self.conversationManager.conversations.first(where: { $0.id == self.conversationState.selectedConversationId }),
			  let message = conversation.messages.first(
				where: { $0.id == self.canvasController.selectedMessageId
				}),
				let snapshot = message.snapshot
		else {
			return
		}
		self.text = snapshot.text
	}
	
	/// Function to save the text to the currently selected snapshot
	private func saveSnapshotText() {
		// Get save location
		guard var conversation = self.conversationManager.conversations.first(where: { $0.id == self.conversationState.selectedConversationId }),
			  var message = conversation.messages.first(
				where: { $0.id == self.canvasController.selectedMessageId
				})
		else {
			return
		}
		// Save
		message.snapshot?.text = self.text
		conversation.updateMessage(message)
		self.conversationManager.update(conversation)
	}
	
}

#Preview {
    SnapshotTextEditor()
}

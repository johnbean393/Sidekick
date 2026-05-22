//
//  CanvasView.swift
//  Sidekick
//
//  Created by John Bean on 3/19/25.
//

import CodeEditorView
import SwiftUI
import WebViewKit

struct CanvasView: View {
	
	@EnvironmentObject private var canvasController: CanvasController
	@Environment(ConversationState.self) private var conversationState
	@Environment(ConversationManager.self) private var conversationManager
	
	var selectedConversation: Conversation? {
		guard let selectedConversationId = conversationState.selectedConversationId else {
			return nil
		}
		return self.conversationManager.getConversation(
			id: selectedConversationId
		)
	}
	
	var assistantMessages: [Message]? {
		guard let selectedConversation else {
			return nil
		}
		return selectedConversation.messages.filter { message in
			return message.getSender() == .assistant
		}
	}
	
	var body: some View {
		Group {
			ZStack {
				Color.clear
					.frame(minHeight: 0, maxHeight: .infinity)
				CanvasPreviewEditor()
					.id(self.canvasController.selectedMessageId) // Force re-render when selected message changes
			}
		}
		.onChange(
			of: canvasController.selectedMessageId
		) {
			self.canvasController.position = CodeEditor.Position()
		}
		.onChange(
			of: assistantMessages
		) {
			// If canvas is open
			if self.conversationState.useCanvas {
				// Extract snapshot
				Task { @MainActor in
					try? await self.canvasController.extractSnapshot(
						selectedConversation: selectedConversation
					)
				}
			}
		}
	}
	
}

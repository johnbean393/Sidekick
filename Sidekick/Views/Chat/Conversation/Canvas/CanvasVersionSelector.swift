//
//  CanvasVersionSelector.swift
//  Sidekick
//
//  Created by John Bean on 3/19/25.
//

import SwiftUI

struct CanvasVersionSelector: View {
	
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
	
	private var versions: [Version] {
		guard let selectedConversation else {
			return []
		}
		return selectedConversation
			.messagesWithSnapshots
			.enumerated()
			.map { index, message in
				return Version(
					numericVersion: (index + 1),
					messageId: message.id
				)
			}
	}
	
	private var selectedVersion: Version? {
		guard let selectedMessageId = self.canvasController.selectedMessageId else {
			return nil
		}
		return self.versions.first { $0.messageId == selectedMessageId }
	}
	
	private var selectedVersionTitle: String {
		return self.selectedVersion?.title ?? String(localized: "Select")
	}
	
	var body: some View {
		Picker(
			selection: self.$canvasController.selectedMessageId.animation(.linear)
		) {
			ForEach(versions) { version in
				Text(version.title)
					.fontWeight(.heavy)
					.tag(version.messageId)
			}
		}
		.pickerStyle(.segmented)
		.fixedSize()
	}
	
	private struct Version: Identifiable {
		
		/// An ID for `Identifiable` conformance
		public var id: Int { return self.numericVersion }
		
		/// The numeric version number of the content
		var numericVersion: Int
		/// The title displayed to the user
		var title: String {
			return "v\(numericVersion)"
		}
		
		/// The ID of the associated message
		var messageId: UUID
	}
	
}

#Preview {
    CanvasVersionSelector()
}

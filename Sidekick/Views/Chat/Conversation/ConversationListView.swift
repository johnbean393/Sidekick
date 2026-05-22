//
//  ConversationNavigationListView.swift
//  Sidekick
//
//  Created by Bean John on 10/8/24.
//

import SwiftUI

struct ConversationNavigationListView: View {
	
	@Environment(ConversationManager.self) private var conversationManager
		@Environment(ConversationState.self) private var conversationState
	
	var body: some View {
		@Bindable var conversationState = self.conversationState
		@Bindable var conversationManager = self.conversationManager
		List(
			$conversationManager.conversations,
			editActions: .move,
			selection: $conversationState.selectedConversationId
		) { conversation in
			NavigationLink(value: conversation.id) {
				ConversationNameEditor(conversation: conversation)
			}
        }
        .scrollIndicators(.never)
		.navigationSplitViewColumnWidth(
			min: 125,
			ideal: 175,
			max: 225
		)
	}
	
}

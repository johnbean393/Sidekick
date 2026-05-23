//
//  ConversationSidebarButtons.swift
//  Sidekick
//
//  Created by John Bean on 3/19/25.
//

import SwiftUI

struct ConversationSidebarButtons: View {
	
	@Environment(LengthyTasksController.self) private var lengthyTasksController
	@Environment(ConversationState.self) private var conversationState
	
    var body: some View {
		Group {
			if self.lengthyTasksController.hasTasks {
				LengthyTasksNavigationButton()
					.buttonStyle(.plain)
					.foregroundStyle(.secondary)
			}
			SidebarButtonView(
				title: String(localized: "New Chat"),
				systemImage: "square.and.pencil"
			) {
				self.conversationState.newConversation()
			}
		}
		.padding(.leading, 5)
		.padding(.trailing, 4)
    }
	
}

#Preview {
    ConversationSidebarButtons()
}

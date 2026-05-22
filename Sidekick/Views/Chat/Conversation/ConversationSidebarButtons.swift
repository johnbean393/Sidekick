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
	
	@State private var isViewingToolbox: Bool = false
	
	var tryToolsTip: TryToolsTip = .init()
	
    var body: some View {
		Group {
			if self.lengthyTasksController.hasTasks {
				LengthyTasksNavigationButton()
					.buttonStyle(.plain)
					.foregroundStyle(.secondary)
			}
			SidebarButtonView(
				title: String(localized: "Toolbox"),
				systemImage: "wrench.adjustable"
			) {
				self.isViewingToolbox.toggle()
			}
			.keyboardShortcut("t", modifiers: [.command])
			.sheet(isPresented: $isViewingToolbox) {
				ToolboxLibraryView(
					isPresented: $isViewingToolbox
				)
                .frame(maxWidth: 500, minHeight: 600)
			}
			.popoverTip(tryToolsTip)
			SidebarButtonView(
				title: String(localized: "New Conversation"),
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

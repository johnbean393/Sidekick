//
//  ContentView.swift
//  Sidekick
//
//  Created by Bean John on 10/4/24.
//

import FSKit_macOS
import SwiftUI

struct ContentView: View {
	
	@Environment(DownloadManager.self) private var downloadManager
		@Environment(ConversationManager.self) private var conversationManager
	
	@State private var conversationState: ConversationState = ConversationState()
	
	@State private var showSetup: Bool = Settings.showSetup
	
    var body: some View {
		@Bindable var conversationState = self.conversationState
		Group {
			if !showSetup {
				ConversationManagerView()
			} else {
				EmptyView()
			}
		}
		.sheet(
			isPresented: $showSetup
		) {
			SetupView(
				showSetup: $showSetup
			)
		}
		.sheet(
			isPresented: $conversationState.isManagingExperts
		) {
			ExpertManagerView()
				.frame(
					minWidth: 300,
					maxWidth: 450,
					minHeight: 450,
					maxHeight: 700
				)
		}
		.environment(conversationState)
    }
}

#Preview {
    ContentView()
}

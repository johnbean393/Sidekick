//
//  ContentView.swift
//  Sidekick
//
//  Created by Bean John on 10/4/24.
//

import FSKit_macOS
import SwiftUI

struct ContentView: View {
	
	@Environment(AppState.self) private var appState
	@Environment(DownloadManager.self) private var downloadManager
		@Environment(ConversationManager.self) private var conversationManager
	
	@State private var conversationState: ConversationState = ConversationState.shared
	
    var body: some View {
		@Bindable var appState = self.appState
		@Bindable var conversationState = self.conversationState
		Group {
			if !appState.isShowingSetup {
				ConversationManagerView()
			} else {
				EmptyView()
			}
		}
		.sheet(
			isPresented: $appState.isShowingSetup
		) {
			SetupView(
				showSetup: $appState.isShowingSetup
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

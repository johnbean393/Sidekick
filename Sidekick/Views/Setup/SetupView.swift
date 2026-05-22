//
//  SetupView.swift
//  Sidekick
//
//  Created by Bean John on 9/22/24.
//

import SwiftUI

struct SetupView: View {
	
	@Environment(ConversationState.self) private var conversationState
	
	@State private var selectedModel: Bool = Settings.hasModel
	
	@Binding var showSetup: Bool
	
    var body: some View {
		Group {
			if !selectedModel {
				// If no model, download or select a model
				ModelSelectionView(selectedModel: $selectedModel)
                    .padding(.vertical)
                    .padding()
			} else {
				// Else, show setup complete screen
				IntroductionView(showSetup: $showSetup)
                    .padding(.vertical)
			}
		}
		.interactiveDismissDisabled(true)
    }
	
}

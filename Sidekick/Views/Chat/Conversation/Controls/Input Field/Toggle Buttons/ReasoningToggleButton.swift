//
//  ReasoningToggleButton.swift
//  Sidekick
//
//  Created by Codex on 3/12/26.
//

import SwiftUI

struct ReasoningToggleButton: View {
    
    @EnvironmentObject private var promptController: PromptController
    
    var activatedFillColor: Color
    var modelIdentifier: String?
    
    @Binding var useReasoning: Bool
    
    var body: some View {
        CapsuleButton(
            label: String(localized: "Reason"),
            systemImage: "brain.head.profile",
            activatedFillColor: activatedFillColor,
            isActivated: self.$useReasoning
        ) { newValue in
            self.promptController.setManualReasoningPreference(
                newValue,
                modelIdentifier: self.modelIdentifier
            )
        }
    }
    
}

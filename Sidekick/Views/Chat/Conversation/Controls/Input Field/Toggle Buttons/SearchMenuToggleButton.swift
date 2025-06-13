//
//  SearchMenuToggleButton.swift
//  Sidekick
//
//  Created by John Bean on 5/7/25.
//

import SwiftUI

struct SearchMenuToggleButton: View {
    
    @EnvironmentObject private var promptController: PromptController
    
    var activatedFillColor: Color
    
    @Binding var useWebSearch: Bool
    @Binding var selectedSearchState: SearchState
    
    var selectedModel: KnownModel? {
        return Model.shared.selectedModel
    }
    
    var body: some View {
        CapsuleMenuButton(
            systemImage: "magnifyingglass",
            activatedFillColor: activatedFillColor,
            isActivated: self.$useWebSearch,
            selectedOption: self.$selectedSearchState
        ) { newValue in
            withAnimation(.linear) {
                self.onToggle(newValue: newValue)
            }
        } onSelectionChange: { newSelection in
            // Check Deep Research availability
            withAnimation(.linear) {
                self.checkDeepResearchAvailability()
            }
        }
    }
    
    private func onToggle(
        newValue: Bool
    ) {
        // Check if search is configured
        if !RetrievalSettings.canUseWebSearch {
            // If not, show error and return
            Dialogs.showAlert(
                title: String(localized: "Search not configured"),
                message: String(localized: "Search is not configured properly. Please configure it in \"Settings\" -> \"Retrieval\".")
            )
            // Set back to false
            self.useWebSearch = false
            return
        }
        // Check Deep Research
        self.checkDeepResearchAvailability()
    }
    
    private func checkDeepResearchAvailability() {
        // If not using Deep Research, return
        if !self.promptController.isUsingDeepResearch {
            return
        }
        // Check if function calling is activated
        if !Settings.useFunctions {
            // If not, show error and return
            Dialogs.showAlert(
                title: String(localized: "Not Available"),
                message: String(localized: "Functions must be turned on to use Deep Research.")
            )
            self.resetSearchState()
            return
        } else {
            // If functions can be used, force on
            self.promptController.useFunctions = true
        }
        // Check if reasoning is activated
        if !self.promptController.useReasoning {
            // Check if can reason
            if !(Model.shared.selectedModelCanReason ?? false) {
                // If not, show error and return
                Dialogs.showAlert(
                    title: String(localized: "Not Available"),
                    message: String(localized: "A reasoning model is required to use Deep Research.")
                )
                self.resetSearchState()
                return
            } else {
                // Force reasoning
                self.promptController.useReasoning = true
            }
        }
    }
    
    /// Function to reset search state
    private func resetSearchState() {
        self.useWebSearch = false // Set back to false
        self.selectedSearchState = .search
    }
    
}

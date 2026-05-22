//
//  UseFunctionsButton.swift
//  Sidekick
//
//  Created by John Bean on 4/14/25.
//

import SwiftData
import SwiftUI

struct UseFunctionsButton: View {

    @Environment(PromptController.self) private var promptController
    @Query private var enabledCategoryRows: [FunctionCategorySelectionEntity]

    var activatedFillColor: Color

    @Binding var useFunctions: Bool

    var useFunctionsTip: UseFunctionsTip = .init()

    var body: some View {
        CapsuleChecklistMenuButton(
            label: String(localized: "Functions"),
            systemImage: "function",
            activatedFillColor: activatedFillColor,
            isActivated: self.$useFunctions,
            enabledCategoryRawValues: Set(enabledCategoryRows.map(\.rawValue))
        ) { newValue in
            self.onToggle(newValue: newValue)
        }
        .popoverTip(self.useFunctionsTip)
    }

    private func onToggle(
        newValue: Bool
    ) {
        if !Settings.useFunctions {
            self.useFunctions = false
            Dialogs.showAlert(
                title: String(localized: "Functions Disabled"),
                message: String(localized: "Functions are disabled in Settings. Please configure it in \"Settings\" -> \"General\" -> \"Functions\".")
            )
            return
        }
        if self.promptController.isUsingDeepResearch {
            self.useFunctions = true
            Dialogs.showAlert(
                title: String(localized: "Not Available"),
                message: String(localized: "Functions must be turned on to use Deep Research.")
            )
            return
        }
    }

}

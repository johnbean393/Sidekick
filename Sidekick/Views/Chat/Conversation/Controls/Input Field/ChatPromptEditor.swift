//
//  ChatPromptEditor.swift
//  Sidekick
//
//  Created by John Bean on 4/20/25.
//

import SwiftUI

struct ChatPromptEditor: View {
    
    @Environment(\.colorScheme) var colorScheme
    @EnvironmentObject private var promptController: PromptController
    
    @AppStorage("useCommandReturn") private var useCommandReturn: Bool = Settings.useCommandReturn
    var sendDescription: String {
        return String(localized: "Enter a message. Press ") + Settings.SendShortcut(self.useCommandReturn).rawValue + String(localized: " to send.")
    }
    
    @FocusState var isFocused: Bool
    @Binding var isRecording: Bool
    
    /// Store a debouncing work item that we can cancel
    @State private var debouncedTask: DispatchWorkItem?
    
    var useAttachments: Bool = true
    var useDictation: Bool = true
    
    /// A `Bool` controlling whether space is reserved for options below the text field
    var bottomOptions: Bool = false
    
    var cornerRadius = 16.0
    var rect: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }
    
    var outlineColor: Color {
        if isRecording {
            return .red
        } else if isFocused {
            return .accentColor
        }
        return .primary
    }
    
    var body: some View {
        MultilineTextField(
            text: self.$promptController.prompt.animation(.linear),
            insertionPoint: self.$promptController.insertionPoint,
            prompt: sendDescription
        )
        .textFieldStyle(.plain)
        .frame(maxWidth: .infinity)
        .if(self.useAttachments) { view in
            view
                .padding(.leading, 24)
        }
        .if(self.useDictation) { view in
            view
                .padding(.trailing, 21)
        }
        .if(!self.useAttachments) { view in
            view
                .padding(.leading, 4)
        }
        .if(!self.useDictation) { view in
            view
                .padding(.trailing, 4)
        }
        .if(self.bottomOptions) { view in
            view
                .padding(.bottom, 30)
        }
        .padding(.vertical, 5)
        .cornerRadius(cornerRadius)
        .background(
            LinearGradient(
                colors: [
                    Color.textBackground,
                    Color.textBackground.opacity(0.9),
                    Color.textBackground.opacity(0.75),
                    Color.textBackground.opacity(0.5)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .mask(rect)
        .overlay(
            rect
                .stroke(style: StrokeStyle(lineWidth: 1))
                .foregroundStyle(outlineColor)
        )
        .animation(isFocused ? .easeIn(duration: 0.2) : .easeOut(duration: 0.0), value: isFocused)
        .onChange(of: self.promptController.prompt) {
            self.scheduleDebouncedAction()
        }
    }
    
    private func scheduleDebouncedAction() {
        // Cancel any existing scheduled work
        self.debouncedTask?.cancel()
        // Exit if prompt is empty
        if self.promptController.prompt.isEmpty {
            self.handleEmptyPrompt()
            return
        }
        // Create a new work item to run after a 1-second delay
        let task: DispatchWorkItem = DispatchWorkItem {
            self.determineIfReasoningNeeded()
        }
        // Store the new work item in our state variable
        self.debouncedTask = task
        // Schedule the work item
        // It will be executed in 0.33 seconds unless cancelled by another keystroke
        DispatchQueue.main.asyncAfter(deadline: .now() + (1/3), execute: task)
    }
    
    private func determineIfReasoningNeeded() {
        // Exit if prompt is empty
        if self.promptController.prompt.isEmpty {
            self.handleEmptyPrompt()
            return
        }
        // Exit if did manually toggle reasoning
        if self.promptController.didManuallyToggleReasoning {
            return
        }
        // Exit if using Deep Research
        if self.promptController.isUsingDeepResearch {
            return
        }
        // Determine if reasoning is needed
        if let useReasoning = PromptAnalyzer.isReasoningRequired(
            self.promptController.prompt
        ) {
            withAnimation(.linear) {
                self.promptController.useReasoning = useReasoning
            }
        }
    }
    
    private func handleEmptyPrompt() {
        // Reset reasoning status
        self.promptController.didManuallyToggleReasoning = false
        guard let isReasoningModel = Model.shared.selectedModelCanReason else {
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // If prompt is still empty
            withAnimation(.linear) {
                if self.promptController.prompt.isEmpty {
                    self.promptController.useReasoning = isReasoningModel
                }
            }
        }
    }
    
}

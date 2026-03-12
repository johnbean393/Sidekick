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
            text: self.$promptController.prompt,
            insertionPoint: self.$promptController.insertionPoint,
            prompt: sendDescription,
            onImageDrop: { url in
                Task {
                    await self.promptController.addFile(url)
                }
            }
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
    }
    
}

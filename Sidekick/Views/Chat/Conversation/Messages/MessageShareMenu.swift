//
//  MessageShareMenu.swift
//  Sidekick
//
//  Created by Bean John on 10/30/24.
//

import AppKit
import FSKit_macOS
import SwiftUI

struct MessageShareMenu: View {
    
    @Environment(\.colorScheme) var colorScheme
    
    @EnvironmentObject private var model: Model
    @Environment(ConversationManager.self) private var conversationManager
        @Environment(ConversationState.self) private var conversationState
    
    var messages: [Message] {
        return self.selectedConversation?.messages ?? []
    }
    
    var conversationName: String {
        return self.selectedConversation?.title ?? "conversation"
    }
    
    var selectedExpert: Expert? {
        guard let selectedExpertId = conversationState.selectedExpertId else {
            return nil
        }
        return ExpertManager.getExpert(id: selectedExpertId)
    }
    
    var toolbarTextColor: Color {
        guard let selectedExpert = selectedExpert else {
            return .primary
        }
        // Use the same logic as expert label/icon for consistency
        return selectedExpert.color.adaptedTextColor
    }
    
    var shouldInvert: Bool {
        guard let luminance = selectedExpert?.color.luminance else {
            return false
        }
        var shouldInvert: Bool = false
        if colorScheme == .dark { // Primary color is white
            shouldInvert = !(luminance < 0.5)
        } else { // Primary color is black
            shouldInvert = (luminance < 0.5)
        }
        return shouldInvert
    }
    
    var selectedConversation: Conversation? {
        guard let selectedConversationId = conversationState.selectedConversationId else {
            return nil
        }
        return self.conversationManager.getConversation(
            id: selectedConversationId
        )
    }
    
    var isGenerating: Bool {
        let statusPass: Bool = self.model.status.isWorking
        let conversationPass: Bool = self.selectedConversation?.id == self.model.sentConversationId
        return statusPass && conversationPass
    }
    
    var body: some View {
        Menu {
            self.saveTextButton
            self.saveHTMLButton
            self.savePNGButton
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
                .symbolRenderingMode(.monochrome)
                .if(self.shouldInvert) { view in
                    view.colorInvert()
                }
        }
        .disabled(isGenerating || self.messages.isEmpty)
    }
    
    var saveTextButton: some View {
        Button {
            self.saveText()
        } label: {
            Label("Save as Text", systemImage: "square.and.arrow.up")
                .labelStyle(.titleOnly)
        }
    }
    
    var saveHTMLButton: some View {
        Button {
            self.saveHTML()
        } label: {
            Label("Save as HTML", systemImage: "square.and.arrow.up")
                .labelStyle(.titleOnly)
        }
    }
    
    var savePNGButton: some View {
        Button {
            self.savePNG()
        } label: {
            Label("Save as PNG", systemImage: "square.and.arrow.up")
                .labelStyle(.titleOnly)
        }
    }
    
    /// Function to export messages as text
    private func saveText() {
        // Convert messages to text
        let text: String = self.messages.map({ message in
            return """
\(message.getSender().rawValue.capitalized):
\(message.text)
"""
        }).joined(separator: "\n\n")
        // Save text to file
        self.saveToFile(
            string: text,
            fileName: "\(self.conversationName).txt"
        )
    }
    
    /// Function to export messages as HTML
    private func saveHTML() {
        // Load the HTML template
        guard let templatePath = Bundle.main.path(
            forResource: "conversationExportTemplate",
            ofType: "html"
        ), var htmlTemplate = try? String(
            contentsOfFile: templatePath,
            encoding: .utf8
        ) else {
            // If failed to load the template, show error and exit
            self.showSaveErrorDialog()
            return
        }
        // Generate the message HTML
        let chatDataJS: String = self.generateChatDataJS(from: messages)
        htmlTemplate = htmlTemplate.replacingOccurrences(
            of: "// CHAT_DATA_PLACEHOLDER",
            with: chatDataJS
        )
        // Save the HTML to a file
        self.saveToFile(
            string: htmlTemplate,
            fileName: "\(self.conversationName).html"
        )
    }
    
    /// Function to produce JS code for message objects
    private func generateChatDataJS(from messages: [Message]) -> String {
        var js = "const chatData = [\n"
        for (index, message) in messages.enumerated() {
            let sender = message.getSender().rawValue
            let escapedContent = self.escapeJSString(message.responseText)
            let escapedReasoning = self.escapeJSString(message.reasoningText ?? "")
            js += """
        {
            id: \(index + 1),
            role: '\(sender)',
            content: `\(escapedContent)`,
            reasoning: `\(escapedReasoning)`,
            timestamp: ""
        },
        """
        }
        js += "];"
        return js
    }
    
    /// Function to apply escapes for special symbols in JS string
    private func escapeJSString(_ string: String) -> String {
        return string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
    }
    
    /// Function to save text to file
    private func saveToFile(
        string: String,
        fileName: String
    ) {
        // Get save location
        if let url = try? FileManager.selectFile(
            dialogTitle: String(localized: "Select a Save Location"),
            canSelectFiles: false
        ).first {
            // Save text to file
            do {
                let fileUrl: URL = url.appendingPathComponent(fileName)
                try string.write(
                    to: fileUrl,
                    atomically: true,
                    encoding: .utf8
                )
            } catch {
                self.showSaveErrorDialog()
            }
        }
    }
    
    /// Function to show save error dialog
    private func showSaveErrorDialog() {
        Dialogs.showAlert(
            title: String(localized: "Error"),
            message: String(localized: "Failed to save messages.")
        )
    }
    
    /// Function to export messages as PNG
    private func savePNG() {
        // Determine background color based on color scheme
        let backgroundColor: Color = colorScheme == .dark ? Color(red: 0.15, green: 0.15, blue: 0.15) : .white
        
        // Create a renderable view of all messages
        let renderView = ConversationRenderView(messages: self.messages, colorScheme: colorScheme)
            .environmentObject(model)
            .environment(conversationManager)
            .environment(conversationState)
            .environment(\.colorScheme, colorScheme) // Apply current color scheme
            .frame(width: 800) // Fixed width for rendering
            .padding()
            .background(backgroundColor)
        
        // Select save location
        guard var destination: URL = try? FileManager.selectFile(
            dialogTitle: String(localized: "Select a Save Location"),
            canSelectFiles: false,
            canSelectDirectories: true,
            allowMultipleSelection: false,
            persistPermissions: false
        ).first else {
            return
        }
        
        // Generate filename
        let filename: String = "\(self.conversationName).png"
        destination = destination.appendingPathComponent(filename)
        
        // Render and save
        let renderer = ImageRenderer(content: renderView)
        renderer.scale = 2.0
        
        // Get the actual size needed for the content
        let proposedSize = renderer.proposedSize
        
        // Set renderer to use the full size without constraints
        renderer.proposedSize = ProposedViewSize(width: 800, height: .infinity)
        
        guard let cgImage = renderer.cgImage else {
            self.showSaveErrorDialog()
            return
        }
        
        // Save the image
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        guard let imageData = bitmapRep.representation(
            using: .png,
            properties: [:]
        ) else {
            self.showSaveErrorDialog()
            return
        }
        
        do {
            try imageData.write(to: destination, options: .atomic)
        } catch {
            self.showSaveErrorDialog()
        }
    }
    
}

/// Helper view to render the conversation for export
private struct ConversationRenderView: View {
    let messages: [Message]
    let colorScheme: ColorScheme
    
    @EnvironmentObject private var model: Model
    @Environment(ConversationManager.self) private var conversationManager
        @Environment(ConversationState.self) private var conversationState
    
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            ForEach(messages) { message in
                MessageView(message: message)
                    .environmentObject(model)
                    .environment(conversationManager)
                    .environment(conversationState)
                    .environment(PromptController())
                    .environment(MemoryIndex.shared)
                    .environment(\.colorScheme, colorScheme)
            }
        }
    }
}

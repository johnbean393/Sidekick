//
//  MessageWrapperView.swift
//  Sidekick
//
//  Created by John Bean on 5/8/25.
//

import Foundation
import SwiftUI

struct MessageWrapperView<Content: View>: View {
    
    @EnvironmentObject private var model: Model
    @Environment(ConversationManager.self) private var conversationManager
    @Environment(ConversationState.self) private var conversationState
    @Environment(PromptController.self) private var promptController
    
    var selectedConversation: Conversation? {
        guard let selectedConversationId = conversationState.selectedConversationId else {
            return nil
        }
        return self.conversationManager.getConversation(
            id: selectedConversationId
        )
    }
    var time: Date
    private var timeDescription: String {
        return self.time.formatted(
            date: .abbreviated,
            time: .shortened
        )
    }
    
    var sender: Sender
    var view: () -> Content
    
    var body: some View {
        HStack(
            alignment: .top,
            spacing: 0
        ) {
            sender.icon
                .padding(.trailing, 10)
            VStack(
                alignment: .leading,
                spacing: 8
            ) {
                controls
                content
            }
        }
        .padding(.trailing)
    }
    
    var controls: some View {
        HStack {
            Text(timeDescription)
                .foregroundColor(.secondary)
            stopButton
        }
    }
    
    var content: some View {
        self.view()
            .padding(11)
            .background {
                MessageBackgroundView()
            }
    }

    var stopButton: some View {
        StopGenerationButton {
            self.stopGeneration()
        }
        .padding(0)
        .padding(.vertical, 2)
    }
    
    /// Function to stop generation
    private func stopGeneration() {
        Task.detached { @MainActor in
            await self.model.interrupt()
            self.retryGeneration()
        }
    }
    
    private func retryGeneration() {
        // Get conversation
        guard var conversation = self.selectedConversation else { return }
        // Set prompt
        let lastMessage: Message? = conversation.messages.last
        self.promptController.prompt = lastMessage?.text ?? ""
        // Set resources
        let urls: [URL] = lastMessage?.referencedURLs.map(
            keyPath: \.url
        ) ?? []
        self.promptController.tempResources += urls.map { url in
            return TemporaryResource(url: url)
        }
        // Delete messages
        conversation.messages = conversation.messages.dropLast(1)
        conversationManager.update(conversation)
    }
    
}

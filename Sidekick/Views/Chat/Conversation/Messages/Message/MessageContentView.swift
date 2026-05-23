//
//  MessageContentView.swift
//  Sidekick
//
//  Created by John Bean on 5/8/25.
//

import SwiftUI

struct MessageContentView: View {
    
    init(
        message: Message,
        isEditing: Binding<Bool>,
        shimmer: Bool = false,
        deprioritizeStreamingUpdates: Bool = false
    ) {
        self.messageText = message.text
        self.message = message
        self._isEditing = isEditing
        self.shimmer = shimmer
        self.deprioritizeStreamingUpdates = deprioritizeStreamingUpdates
    }
    
    @Environment(ConversationManager.self) private var conversationManager
    @Environment(ConversationState.self) private var conversationState
    @Environment(PromptController.self) private var promptController
    
    @Binding private var isEditing: Bool
    @State private var messageText: String

    var message: Message
    var shimmer: Bool
    var deprioritizeStreamingUpdates: Bool
    
    var selectedConversation: Conversation? {
        return self.conversationState.selectedConversation
    }
    
    var viewReferenceTip: ViewReferenceTip = .init()
    
    private var isGenerating: Bool {
        return !message.outputEnded && message.getSender() == .assistant
    }
    
    var body: some View {
        switch message.contentType {
            case .text:
                textContent
            case .image:
                imageContent
        }
    }
    
    var imageContent: some View {
        message.image
            .padding(0.5)
    }
    
    var textContent: some View {
        Group {
            if self.isEditing {
                contentEditor
            } else {
                VStack(
                    alignment: .leading,
                    spacing: 4
                ) {
                    // Show function calls if availible
                    if self.message.hasFunctionCallRecords {
                        FunctionCallsView(message: self.message)
                            .if(
                                !self.message.text
                                    .isEmpty || (self.message.functionCallRecords?.count ?? 0) > 1
                            ) { view in
                                view.padding(.bottom, 5)
                            }
                    }
                    // Show reasoning process if availible
                    if self.message.hasReasoning {
                        MessageReasoningProcessView(message: self.message)
                            .if(!self.message.responseText.isEmpty) { view in
                                view.padding(.bottom, 5)
                            }
                    }
                    if self.message.getSender() == .user && !self.message.referencedURLs.isEmpty {
                        userMessageReferences
                    }
                    // Show message response
                    Group {
                        if self.message.getSender() != .user {
                            MessageTextContentView(
                                text: self.message.responseText,
                                isStreaming: !self.message.outputEnded,
                                deprioritizeStreamingUpdates: self.deprioritizeStreamingUpdates,
                                messageIdentity: self.message.id.uuidString
                            )
                        } else {
                            CollapsibleUserMessageView(
                                text: self.message.responseText,
                                messageIdentity: self.message.id.uuidString
                            )
                        }
                    }
                    .if(shimmer) { view in
                        view.shimmering()
                    }
                    // Show references if needed
                    if self.message.getSender() != .user && !self.message.referencedURLs.isEmpty {
                        messageReferences
                    }
                }
            }
        }
        .padding(11)
    }
    
    var contentEditor: some View {
        VStack {
            TextEditor(
                text: self.$messageText
            )
            .frame(minWidth: 0, maxWidth: .infinity)
            .font(.title3)
            HStack {
                Spacer()
                Button {
                    self.cancelEdit()
                } label: {
                    Text("Cancel")
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    self.saveEdit()
                } label: {
                    Text("Save")
                }
                .keyboardShortcut("s", modifiers: .command)
                if self.message.getSender() == .user {
                    Button {
                        self.sendEdit()
                    } label: {
                        Text("Send")
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(self.isGenerating)
                }
            }
        }
    }
    
    var messageReferences: some View {
        VStack(
            alignment: .leading
        ) {
            Text("References:")
                .bold()
                .font(.body)
                .foregroundStyle(Color.secondary)
            ForEach(
                self.message.referencedURLs.indices,
                id: \.self
            ) { index in
                self.message.referencedURLs[index].openButton
                    .if(index == 0) { view in
                        view.popoverTip(
                            viewReferenceTip,
                            arrowEdge: .top
                        ) { action in
                            // Open reference
                            self.message.referencedURLs[index].open()
                        }
                    }
            }
        }
        .padding(.top, 8)
        .onAppear {
            ViewReferenceTip.hasReference = true
        }
    }
    
    var userMessageReferences: some View {
        HStack(
            alignment: .center,
            spacing: 6
        ) {
            ForEach(
                Array(self.message.referencedURLs.enumerated()),
                id: \.element
            ) { _, referencedURL in
                UserMessageAttachmentView(referencedURL: referencedURL)
            }
        }
        .padding(.bottom, 8)
    }
    
    private func updateMessage() {
        guard var conversation = selectedConversation else { return }
        var message: Message = self.message
        message.text = messageText
        conversation.updateMessage(message)
        conversationManager.update(conversation)
    }
    
    /// Discards in-flight edits and exits edit mode.
    private func cancelEdit() {
        self.messageText = self.message.text
        withAnimation(.linear(duration: 0.5)) {
            self.isEditing = false
        }
    }
    
    /// Persists the edited text in place and exits edit mode without
    /// triggering a new model response.
    private func saveEdit() {
        self.updateMessage()
        withAnimation(.linear(duration: 0.5)) {
            self.isEditing = false
        }
    }
    
    /// Persists the edit, drops every message after this user
    /// message, and asks ``PromptInputField`` to resubmit the edited
    /// text so the assistant produces a fresh reply.
    private func sendEdit() {
        guard self.message.getSender() == .user else { return }
        self.updateMessage()
        let attachments: [URL] = self.message.referencedURLs.map(\.url)
        self.promptController.requestResubmit(
            .init(
                prompt: self.messageText,
                attachments: attachments,
                dropAfterMessageId: self.message.id
            )
        )
        withAnimation(.linear(duration: 0.5)) {
            self.isEditing = false
        }
    }
    
}

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
    
    @EnvironmentObject private var conversationManager: ConversationManager
    @EnvironmentObject private var conversationState: ConversationState
    
    @Binding private var isEditing: Bool
    @State private var messageText: String

    var message: Message
    var shimmer: Bool
    var deprioritizeStreamingUpdates: Bool
    
    var selectedConversation: Conversation? {
        guard let selectedConversationId = conversationState.selectedConversationId else {
            return nil
        }
        return self.conversationManager.getConversation(
            id: selectedConversationId
        )
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
                                deprioritizeStreamingUpdates: self.deprioritizeStreamingUpdates
                            )
                        } else {
                            CollapsibleUserMessageView(text: self.message.responseText)
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
                    withAnimation(
                        .linear(duration: 0.5)
                    ) {
                        self.isEditing.toggle()
                    }
                } label: {
                    Text("Cancel")
                }
                Button {
                    self.updateMessage()
                    withAnimation(
                        .linear(duration: 0.5)
                    ) {
                        self.isEditing.toggle()
                    }
                } label: {
                    Text("Save")
                }
                .keyboardShortcut("s", modifiers: .command)
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
    
}

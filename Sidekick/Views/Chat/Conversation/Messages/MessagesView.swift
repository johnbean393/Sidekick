//
//  MessagesView.swift
//  Sidekick
//
//  Created by Bean John on 10/8/24.
//

import AppKit
import Combine
import SwiftUI

struct MessagesView: View {
    
    @Environment(\.colorScheme) var colorScheme
    
    @EnvironmentObject private var model: Model
    @Environment(PromptController.self) private var promptController
    @Environment(ConversationManager.self) private var conversationManager
    @Environment(ConversationState.self) private var conversationState
    
    @State private var scrollViewProxy: NSScrollView?
    @State private var savedScrollPosition: CGPoint?
    @State private var wasShowingPreview: Bool = false
    @State private var isActivelyScrolling: Bool = false
    @State private var scrollResetTask: DispatchWorkItem?
    
    var selectedConversation: Conversation? {
        return self.conversationState.selectedConversation
    }
    
    var messages: [Message] {
        return self.selectedConversation?.messages ?? []
    }
    
    var body: some View {
        ScrollView {
            HStack(alignment: .top) {
                LazyVStack(alignment: .leading, spacing: 13) {
                    Group {
                        self.messagesView
                        PendingMessageHost(
                            conversationId: self.selectedConversation?.id,
                            isActivelyScrolling: self.isActivelyScrolling
                        ) { oldValue, newValue in
                            self.handlePreviewVisibilityChange(
                                oldValue: oldValue,
                                newValue: newValue
                            )
                        }
                    }
                }
                .padding(.vertical)
                .padding(.bottom, 175)
                Spacer()
            }
        }
        .background(NSScrollViewAccessor(scrollView: $scrollViewProxy))
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSScrollView.willStartLiveScrollNotification
            )
        ) { output in
            guard let scrollView = output.object as? NSScrollView,
                  scrollView === self.scrollViewProxy else {
                return
            }
            self.scrollResetTask?.cancel()
            self.isActivelyScrolling = true
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSScrollView.didLiveScrollNotification
            )
        ) { output in
            guard let scrollView = output.object as? NSScrollView,
                  scrollView === self.scrollViewProxy else {
                return
            }
            self.scheduleScrollReset()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSScrollView.didEndLiveScrollNotification
            )
        ) { output in
            guard let scrollView = output.object as? NSScrollView,
                  scrollView === self.scrollViewProxy else {
                return
            }
            self.scheduleScrollReset(delay: 0.05)
        }
        .onChange(of: messages.count) { oldCount, newCount in
            // When a message finishes generating and is added to the array
            if wasShowingPreview && newCount > oldCount {
                // Restore the saved scroll position after a brief delay
                // to ensure the new content has been laid out
                if let savedPosition = savedScrollPosition, let scrollView = scrollViewProxy {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        scrollView.contentView.scroll(to: savedPosition)
                        // Clear the saved position after restoring
                        savedScrollPosition = nil
                        wasShowingPreview = false
                    }
                }
            }
        }
    }
    
    var messagesView: some View {
        ForEach(
            self.messages
        ) { message in
            MessageView(message: message)
                .id(message.id)
        }
    }

    private func scheduleScrollReset(
        delay: TimeInterval = 0.12
    ) {
        self.scrollResetTask?.cancel()
        let task = DispatchWorkItem {
            self.isActivelyScrolling = false
            self.scrollResetTask = nil
        }
        self.scrollResetTask = task
        DispatchQueue.main.asyncAfter(
            deadline: .now() + delay,
            execute: task
        )
    }

    private func handlePreviewVisibilityChange(
        oldValue: Bool,
        newValue: Bool
    ) {
        if newValue {
            self.wasShowingPreview = true
        }
        if oldValue && !newValue, let scrollView = self.scrollViewProxy {
            self.savedScrollPosition = scrollView.documentVisibleRect.origin
        }
    }
    
}

private struct PendingMessageHost: View {

    @EnvironmentObject private var model: Model

    let conversationId: UUID?
    let isActivelyScrolling: Bool
    let onVisibilityChange: (Bool, Bool) -> Void

    var body: some View {
        let run = self.model.chatRun(for: self.conversationId)
        let statusPass = run?.status.isWorking == true && run?.status != .backgroundTask
        let isVisible = statusPass
        let contentType = self.model.displayedContentType(for: self.conversationId)
        let message = self.model.displayedPendingMessage(for: self.conversationId)
        Group {
            if isVisible {
                switch contentType {
                    case .text, .indicator:
                        MessageView(
                            message: message,
                            shimmer: contentType == .indicator,
                            deprioritizeStreamingUpdates: self.isActivelyScrolling
                        )
                        .id(message.id)
                    case .preview:
                        self.model.agent(for: self.conversationId)?.preview ?? AnyView(EmptyView())
                }
            }
        }
        .onChange(of: isVisible) { oldValue, newValue in
            self.onVisibilityChange(oldValue, newValue)
        }
    }

}

/// A helper view to access the underlying NSScrollView
struct NSScrollViewAccessor: NSViewRepresentable {
    
    @Binding var scrollView: NSScrollView?
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            self.findNSScrollView(in: view)
        }
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            self.findNSScrollView(in: nsView)
        }
    }
    
    private func findNSScrollView(in view: NSView) {
        if let scrollView = view.enclosingScrollView {
            self.scrollView = scrollView
            return
        }
        
        var parent = view.superview
        while parent != nil {
            if let scrollView = parent as? NSScrollView {
                self.scrollView = scrollView
                return
            }
            parent = parent?.superview
        }
    }
}

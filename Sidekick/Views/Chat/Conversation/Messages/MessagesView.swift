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
    @EnvironmentObject private var conversationManager: ConversationManager
    @EnvironmentObject private var conversationState: ConversationState
    
    @State private var scrollViewProxy: NSScrollView?
    @State private var savedScrollPosition: CGPoint?
    @State private var wasShowingPreview: Bool = false
    @State private var isActivelyScrolling: Bool = false
    @State private var scrollResetTask: DispatchWorkItem?
    
    var selectedConversation: Conversation? {
        guard let selectedConversationId = conversationState.selectedConversationId else {
            return nil
        }
        return self.conversationManager.getConversation(
            id: selectedConversationId
        )
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
                            model: self.model,
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

    @StateObject private var presenter: PendingMessagePresenter = .init()

    let model: Model
    let conversationId: UUID?
    let isActivelyScrolling: Bool
    let onVisibilityChange: (Bool, Bool) -> Void

    var body: some View {
        let snapshot = self.presenter.snapshot
        Group {
            if snapshot.isVisible {
                switch snapshot.contentType {
                    case .text, .indicator:
                        MessageView(
                            message: snapshot.message,
                            shimmer: snapshot.contentType == .indicator,
                            deprioritizeStreamingUpdates: self.isActivelyScrolling
                        )
                        .id(snapshot.message.id)
                    case .preview:
                        snapshot.preview
                }
            }
        }
        .onAppear {
            self.presenter.configure(
                model: self.model,
                conversationId: self.conversationId
            )
            self.presenter.setScrolling(
                self.isActivelyScrolling
            )
        }
        .onChange(of: self.presenter.snapshot.isVisible) { oldValue, newValue in
            self.onVisibilityChange(oldValue, newValue)
        }
        .onChange(of: self.conversationId) { _, newValue in
            self.presenter.configure(
                model: self.model,
                conversationId: newValue
            )
        }
        .onChange(of: self.isActivelyScrolling) { _, newValue in
            self.presenter.setScrolling(newValue)
        }
    }

}

@MainActor
private final class PendingMessagePresenter: ObservableObject {

    struct Snapshot {
        var isVisible: Bool
        var message: Message
        var contentType: Model.DisplayedContentType
        var preview: AnyView

        static let hidden: Self = .init(
            isVisible: false,
            message: Message(text: "", sender: .assistant),
            contentType: .indicator,
            preview: AnyView(EmptyView())
        )
    }

    @Published private(set) var snapshot: Snapshot = .hidden

    private var cancellables: Set<AnyCancellable> = []
    private weak var model: Model?
    private var conversationId: UUID?
    private var isScrolling: Bool = false

    func configure(
        model: Model,
        conversationId: UUID?
    ) {
        let modelChanged = self.model !== model
        let conversationChanged = self.conversationId != conversationId

        self.model = model
        self.conversationId = conversationId

        if modelChanged {
            self.bind(to: model)
        }

        if modelChanged || conversationChanged {
            self.refresh(force: true)
        }
    }

    func setScrolling(
        _ isScrolling: Bool
    ) {
        guard self.isScrolling != isScrolling else {
            return
        }
        self.isScrolling = isScrolling
        if !isScrolling {
            self.refresh(force: true)
        }
    }

    private func bind(
        to model: Model
    ) {
        self.cancellables.removeAll()

        model.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.refresh()
                }
            }
            .store(in: &self.cancellables)
    }

    private func refresh(
        force: Bool = false
    ) {
        guard force || !self.isScrolling else {
            return
        }
        guard let model else {
            self.snapshot = .hidden
            return
        }

        let statusPass = model.status.isWorking && model.status != .backgroundTask
        let conversationPass = self.conversationId == model.sentConversationId
        let isVisible = statusPass && conversationPass

        guard isVisible else {
            self.snapshot = .hidden
            return
        }

        self.snapshot = Snapshot(
            isVisible: true,
            message: model.displayedPendingMessage,
            contentType: model.displayedContentType,
            preview: model.agent?.preview ?? AnyView(EmptyView())
        )
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

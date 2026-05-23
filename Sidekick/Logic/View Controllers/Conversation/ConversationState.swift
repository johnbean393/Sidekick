//
//  ConversationState.swift
//  Sidekick
//
//  Created by Bean John on 10/14/24.
//
//  Converted from `ObservableObject` to `@Observable` as part of
//  Phase 1 of the SwiftData migration.
//

import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
public final class ConversationState {

    /// Process-wide instance. Cmd+N and other non-view entry
    /// points need a stable reference to the state so they can
    /// create/reuse the in-memory draft conversation without
    /// going through `@Environment` injection.
    public static let shared: ConversationState = .init()

    var isManagingExperts: Bool = false

    var selectedConversationId: UUID? = ConversationState.topmostConversation?.id {
        didSet {
            // If the selection moves away from the in-memory draft,
            // discard the draft - we only ever keep one blank chat
            // around, and it lives wherever the user is currently
            // focused.
            if let draft = self.draftConversation,
               selectedConversationId != draft.id {
                self.draftConversation = nil
            }
        }
    }

    /// An in-memory "blank chat" that has not yet been persisted.
    /// It is intentionally absent from
    /// ``ConversationManager.conversations`` (and therefore from
    /// the sidebar list) until the user sends their first message,
    /// at which point ``commitDraftIfNeeded(_:)`` promotes it into
    /// the persisted list.
    public internal(set) var draftConversation: Conversation?

    /// The topmost conversation listed in the sidebar
    static var topmostConversation: Conversation? {
        return ConversationManager.shared.conversations.first
    }

    /// The currently selected conversation. Returns the in-memory
    /// draft when the selection points at it, otherwise falls
    /// through to the persisted ``ConversationManager`` store.
    public var selectedConversation: Conversation? {
        guard let selectedConversationId = self.selectedConversationId else {
            return nil
        }
        if let draft = self.draftConversation,
           draft.id == selectedConversationId {
            return draft
        }
        return ConversationManager.shared.getConversation(
            id: selectedConversationId
        )
    }

    var selectedExpertId: UUID? = ConversationManager.shared.conversations.first?.messages.last?.expertId ?? ExpertManager.default?.id

    var useCanvas: Bool = false

    /// Function to start a new conversation. Rather than
    /// immediately writing a fresh row to ``ConversationManager``
    /// (and thereby polluting the sidebar with blank chats), this
    /// keeps the new conversation in memory as ``draftConversation``
    /// and only commits it on the first user message via
    /// ``commitDraftIfNeeded(_:)``. If a draft is already around,
    /// the same one is reused so the user can never accumulate
    /// multiple blank chats.
    ///
    /// All state mutations are bundled into a single
    /// ``withAnimation`` transaction so SwiftUI sees the draft
    /// creation and the selection change as one atomic update.
    /// Splitting them across transactions can leave consumers
    /// observing an intermediate state where the selection still
    /// points at the previous conversation - that's how we used
    /// to land on the wrong (non-centered) layout until something
    /// else (e.g. a prompt edit) forced a re-render.
    public func newConversation() {
        withAnimation(.linear) {
            if self.draftConversation == nil {
                let defaultTitle: String = Date.now.formatted(
                    date: .abbreviated,
                    time: .shortened
                )
                self.draftConversation = Conversation(
                    title: defaultTitle,
                    createdAt: .now,
                    messages: []
                )
            }
            // Force-unwrap is safe: we just ensured the draft
            // exists (or it already did).
            let targetId: UUID = self.draftConversation!.id
            self.selectedExpertId = ExpertManager.default?.id
            self.selectedConversationId = targetId
        }
        NotificationCenter.default.post(
            name: Notifications.newConversation.name,
            object: nil
        )
    }

    /// Promotes the in-memory draft into a persisted conversation
    /// if the supplied conversation is the current draft. Inserts
    /// at the top of the list to mirror the historical placement
    /// used by ``ConversationManager.newConversation``. Returns
    /// `true` when the conversation was committed (so the caller
    /// can skip the regular `update(_:)` path that would otherwise
    /// no-op because the conversation isn't in the array yet).
    @discardableResult
    public func commitDraftIfNeeded(_ conversation: Conversation) -> Bool {
        guard let draft = self.draftConversation,
              draft.id == conversation.id else {
            return false
        }
        var conversations: [Conversation] = ConversationManager.shared.conversations
        conversations.insert(conversation, at: 0)
        ConversationManager.shared.conversations = conversations
        self.draftConversation = nil
        return true
    }
}

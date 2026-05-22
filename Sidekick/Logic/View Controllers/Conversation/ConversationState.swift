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

    var isManagingExperts: Bool = false

    var selectedConversationId: UUID? = ConversationState.topmostConversation?.id

    /// The topmost conversation listed in the sidebar
    static var topmostConversation: Conversation? {
        return ConversationManager.shared.conversations.first
    }

    /// The currently selected conversation
    public var selectedConversation: Conversation? {
        guard let selectedConversationId = self.selectedConversationId else {
            return nil
        }
        return ConversationManager.shared.getConversation(
            id: selectedConversationId
        )
    }

    var selectedExpertId: UUID? = ConversationManager.shared.conversations.first?.messages.last?.expertId ?? ExpertManager.default?.id

    var useCanvas: Bool = false

    /// Function to create a new conversation
    public func newConversation() {
        ConversationManager.shared.newConversation()
        withAnimation(.linear) {
            self.selectedExpertId = ExpertManager.default?.id
        }
        if let recentConversationId = ConversationManager.shared.recentConversation?.id {
            withAnimation(.linear) {
                self.selectedConversationId = recentConversationId
            }
        }
    }
}

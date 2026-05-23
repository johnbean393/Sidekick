//
//  ChatScreenshotScope.swift
//  Sidekick
//
//  Created by John Bean on 5/23/26.
//
//  Describes which messages should be included in a chat screenshot.
//  Used by ``ChatScreenshotExporter`` to drive
//  ``ChatScreenshotHTMLBuilder`` and the offscreen
//  ``ChatScreenshotRenderer``.
//

import Foundation
import UniformTypeIdentifiers

/// The output format produced by the chat exporter.
public enum ChatScreenshotFormat: String, CaseIterable {
    
    case png
    case pdf
    
    /// File extension used in the default save filename.
    public var fileExtension: String {
        return self.rawValue
    }
    
    /// `UTType` used to constrain `NSSavePanel`.
    public var contentType: UTType {
        switch self {
            case .png: return .png
            case .pdf: return .pdf
        }
    }
    
    /// Short, user-visible name (e.g. `"PNG"`, `"PDF"`).
    public var displayName: String {
        switch self {
            case .png: return String(localized: "PNG")
            case .pdf: return String(localized: "PDF")
        }
    }
    
    /// Verb used in the progress HUD title — "Capturing …" for
    /// image, "Exporting …" for document formats.
    public var progressVerb: String {
        switch self {
            case .png: return String(localized: "Capturing")
            case .pdf: return String(localized: "Exporting")
        }
    }
}

/// Selects the slice of a conversation a screenshot should cover.
public enum ChatScreenshotScope: Equatable {
    
    /// Every message in the conversation, in display order.
    case entireChat
    
    /// One user turn plus its paired assistant reply. ``anchorId`` is
    /// the message the user invoked the action from; the resolver
    /// expands the slice to include the other half of the turn.
    case currentTurn(anchorId: UUID)
    
    /// A single message bubble, identified by its ``Message/id``.
    case singleMessage(id: UUID)
    
    /// User-visible name for filename composition and progress UI.
    public var displayName: String {
        switch self {
            case .entireChat:
                return String(localized: "Entire Chat")
            case .currentTurn:
                return String(localized: "Current Turn")
            case .singleMessage:
                return String(localized: "Current Message")
        }
    }
    
    /// Filename-safe shorthand for the scope.
    public var filenameTag: String {
        switch self {
            case .entireChat:
                return "chat"
            case .currentTurn:
                return "turn"
            case .singleMessage:
                return "message"
        }
    }
    
    /// Resolves the scope against a concrete conversation, returning
    /// the messages to render in display order.
    ///
    /// `currentTurn` semantics:
    /// - When the anchor is a user message, the slice is the anchor
    ///   plus the next assistant message, if any.
    /// - When the anchor is an assistant message, the slice is the
    ///   preceding user message (if any) plus the anchor.
    /// - When the other half of the turn is missing, the slice
    ///   degrades gracefully to whatever is available.
    public func resolve(in conversation: Conversation) -> [Message] {
        switch self {
            case .entireChat:
                return conversation.messages
            case .singleMessage(let id):
                if let message = conversation.messages.first(where: { $0.id == id }) {
                    return [message]
                }
                return []
            case .currentTurn(let anchorId):
                guard let anchorIndex = conversation.messages.firstIndex(where: { $0.id == anchorId }) else {
                    return []
                }
                let anchor: Message = conversation.messages[anchorIndex]
                switch anchor.getSender() {
                    case .user:
                        // Anchor first, plus the next assistant reply
                        // (if any). Drop anything beyond the single
                        // reply to keep "turn" tight.
                        let nextIndex: Int = anchorIndex + 1
                        if nextIndex < conversation.messages.count,
                           conversation.messages[nextIndex].getSender() == .assistant {
                            return [anchor, conversation.messages[nextIndex]]
                        }
                        return [anchor]
                    default:
                        // Find the immediately preceding user message;
                        // include it plus the anchor.
                        var precedingUser: Message?
                        if anchorIndex > 0 {
                            for index in stride(from: anchorIndex - 1, through: 0, by: -1) {
                                if conversation.messages[index].getSender() == .user {
                                    precedingUser = conversation.messages[index]
                                    break
                                }
                            }
                        }
                        if let precedingUser {
                            return [precedingUser, anchor]
                        }
                        return [anchor]
                }
        }
    }
}

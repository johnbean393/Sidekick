//
//  Conversation.swift
//  Sidekick
//
//  Created by Bean John on 10/4/24.
//

import Foundation

public struct Conversation: Identifiable, Codable, Hashable {
	
	/// Stored property for `Identifiable` conformance
	public var id: UUID = UUID()
	
	/// Stored property for conversation title
	public var title: String
	
	/// Stored property for the selected expert's ID. Defaults are
	/// applied lazily on the main actor when a conversation is
	/// instantiated outside a SwiftData-aware context.
	public var expertId: UUID? = nil

	/// Computed property returning the selected expert
	@MainActor
	public var expert: Expert? {
		guard let expertId else { return nil }
		return ExpertManager.getExpert(id: expertId)
	}
	
	/// Computed property returning the system prompt used
	@MainActor
	public var systemPrompt: String? {
		return expert?.systemPrompt
	}
	
	/// Stored property for creation date
	public var createdAt: Date = .now
	
	/// Stored property for messages
	public var messages: [Message] = []
	
	/// An array of messages with snapshots
	public var messagesWithSnapshots: [Message] {
		return self.messages.filter { message in
			return message.snapshot != nil
		}
	}
	
	/// A `Bool` representing whether the conversation contains snapshots
	public var hasSnapshots: Bool {
		return !self.messagesWithSnapshots.isEmpty
	}
	
	/// Computed property for most recent update
	public var lastUpdated: Date {
		if let lastUpdate: Date = self.messages.map({
			$0.lastUpdated
		}).max() {
			return lastUpdate
		} else {
			return self.createdAt
		}
	}
	
	/// The length of the conversation in tokens, of type `Int`
	public var tokenCount: Int?
	
	/// Function to add a new message, returns `true` if successful
	public mutating func addMessage(_ message: Message) -> Bool {
		// Check if different sender
		let lastSender: Sender? = self.messages.last?.getSender()
		if lastSender != nil {
			let differentSender: Bool = lastSender != message.getSender()
			if !differentSender {
				return false
			}
		}
		// Check if blank if user
		if message.text.isEmpty && message.getSender() == .user {
			return false
		}
		// Make new message
		self.messages.append(message)
		// Set title if needed
		if self.messages.isEmpty {
			self.title = message.text
		}
		return true
	}
	
	/// Function to update an existing message
	public mutating func updateMessage(_ message: Message) {
		for index in self.messages.indices {
			if self.messages[index].id == message.id {
				self.messages[index] = message
				return
			}
		}
	}
	
	/// Function to get a message with an ID
	public func getMessage(
		_ id: UUID
	) -> Message? {
		return self.messages.filter({ $0.id == id }).first
	}
	
	/// Function to drop last message
	public mutating func dropLastMessage() {
		self.messages.removeLast()
	}
	
	/// Removes the message with the given `id` from the conversation,
	/// preserving the relative order of every other message.
	public mutating func removeMessage(id: UUID) {
		self.messages.removeAll { $0.id == id }
	}
	
	/// Drops every message that appears after the message with the
	/// supplied `id`. When `inclusive` is `true`, the anchor message
	/// itself is also removed.
	public mutating func truncateAfter(
		id: UUID,
		inclusive: Bool
	) {
		guard let index = self.messages.firstIndex(where: { $0.id == id }) else {
			return
		}
		// Keep messages up to and including the anchor when not inclusive
		let upperBound: Int = inclusive ? index : index + 1
		self.messages = Array(self.messages.prefix(upperBound))
	}
	
	/// Removes the assistant reply that immediately follows the user
	/// message identified by `userMessageId`, if any. Returns `true`
	/// when something was deleted.
	@discardableResult
	public mutating func deleteAssistantResponse(
		pairedWith userMessageId: UUID
	) -> Bool {
		guard let userIndex = self.messages.firstIndex(where: { $0.id == userMessageId }) else {
			return false
		}
		let nextIndex: Int = userIndex + 1
		guard nextIndex < self.messages.count,
			  self.messages[nextIndex].getSender() == .assistant else {
			return false
		}
		self.messages.remove(at: nextIndex)
		return true
	}
	
	/// Returns a brand-new conversation containing every message up
	/// to and including the message identified by `messageId`. Each
	/// copied message receives a fresh `UUID` so the SwiftData upsert
	/// in ``ConversationManager`` doesn't collide with the source
	/// rows. Returns `nil` when the anchor message cannot be found.
	public func fork(
		at messageId: UUID,
		newTitle: String? = nil
	) -> Conversation? {
		guard let anchorIndex = self.messages.firstIndex(where: { $0.id == messageId }) else {
			return nil
		}
		let slice: [Message] = Array(self.messages.prefix(anchorIndex + 1))
		let rebasedMessages: [Message] = slice.map { source in
			var copy: Message = source
			copy.id = UUID()
			if copy.snapshot != nil {
				copy.snapshot?.id = UUID()
				copy.snapshot?.site?.id = UUID()
			}
			return copy
		}
		let resolvedTitle: String = newTitle ?? self.title
		var forked: Conversation = Conversation(
			id: UUID(),
			title: resolvedTitle,
			expertId: self.expertId,
			createdAt: .now,
			messages: rebasedMessages
		)
		forked.tokenCount = nil
		return forked
	}
	
	/// Static function for equatable conformance
	public static func == (lhs: Conversation, rhs: Conversation) -> Bool {
		return lhs.id == rhs.id
	}
	
}

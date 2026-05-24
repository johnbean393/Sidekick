//
//  ConversationManager.swift
//  Sidekick
//
//  Created by Bean John on 10/4/24.
//
//  Migrated to SwiftData on 5/23/26. Storage now lives in
//  ``ConversationEntity`` + ``MessageEntity`` (with cascade-deleted
//  ``SourceEntity`` / ``MemoryEntity`` / ``SnapshotEntity`` rows);
//  the public API — a `@Published` `[Conversation]` array, plus
//  `add/update/delete` — is unchanged. To avoid an O(n) rewrite of
//  every conversation on each `didSet`, the save path performs an
//  id-based upsert against the SwiftData store.
//

import Foundation
import FSKit_macOS
import Observation
import os.log
import SwiftData
import SwiftUI

@MainActor
@Observable
public final class ConversationManager {

    /// A `Logger` object for the `ConversationManager` object
    @ObservationIgnored
    private static let logger: Logger = .init(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: ConversationManager.self)
    )

    init() {
        let signpost = StartupMetrics.begin("ConversationManager.init")
        self.patchFileIntegrity()
        self.loadAsync()
        StartupMetrics.end("ConversationManager.init", signpost)
    }

    /// Process-wide instance. Kept (rather than fully deleted) so
    /// the streaming inference path can mutate conversations and
    /// rely on the debounced ``MessageStreamCoordinator`` to batch
    /// the resulting SwiftData saves, instead of relying on
    /// ``@Query`` reactivity which would otherwise require a far
    /// larger view refactor.
    public static let shared: ConversationManager = .init()

    /// All conversations. Persists to ``ConversationEntity`` via
    /// the debounced ``MessageStreamCoordinator`` so streaming
    /// tokens no longer rewrite the entire conversations.json file
    /// (now a SwiftData table) on every change.
    public var conversations: [Conversation] = [] {
        didSet {
            self.scheduleSave()
        }
    }

    /// Observable state tracking whether the datastore has been
    /// loaded.
    public private(set) var isLoaded: Bool = false

    /// Task handling the asynchronous datastore load
    @ObservationIgnored
    private var loadTask: Task<Void, Never>?

    /// Computed property returning the IDs of all messages
    var allMessagesIds: [UUID] {
        return self.conversations.flatMap(\.messages).map(\.id)
    }

    /// Computed property returning the first conversation
    var firstConversation: Conversation? {
        guard self.isLoaded else { return nil }
        return self.conversations.first
    }

    /// Computed property returning the last conversation
    var lastConversation: Conversation? {
        guard self.isLoaded else { return nil }
        return self.conversations.last
    }

    /// Computed property returning the most recent conversation
    var recentConversation: Conversation? {
        guard self.isLoaded else { return nil }
        return self.conversations.sorted(
            by: \.createdAt
        ).last
    }

    /// A `Bool` representing whether a backup exists
    var backupExists: Bool {
        return self.backupDatastoreUrl.fileExists
    }

    /// Coalesces back-to-back `didSet` notifications (which happen
    /// every streaming token) into a single SwiftData write per
    /// ``MessageStreamCoordinator.debounceInterval``.
    private func scheduleSave() {
        MessageStreamCoordinator.shared.noteChange { [weak self] in
            self?.save()
        }
    }

    /// Forces an immediate flush of any pending debounced write.
    /// Call from streaming inference when generation completes so
    /// the terminal message text is persisted without waiting for
    /// the debounce window.
    public func flushPendingSaves() {
        MessageStreamCoordinator.shared.flush()
    }

    /// Function to save conversations to SwiftData using an
    /// id-based upsert against ``ConversationEntity`` /
    /// ``MessageEntity`` (and their cascaded children).
    public func save() {
        let context = ModelContext(PersistenceController.shared.container)
        do {
            let existingConversations = try context.fetch(FetchDescriptor<ConversationEntity>())
            var existingById: [UUID: ConversationEntity] = [:]
            for entity in existingConversations {
                existingById[entity.id] = entity
            }
            let desiredIds = Set(self.conversations.map(\.id))

            // Delete conversations that no longer exist.
            for (id, entity) in existingById where !desiredIds.contains(id) {
                context.delete(entity)
            }
            // Upsert remaining conversations.
            for conversation in self.conversations {
                let entity = existingById[conversation.id] ?? ConversationEntity(
                    id: conversation.id,
                    title: conversation.title,
                    createdAt: conversation.createdAt,
                    expertId: conversation.expertId,
                    tokenCount: conversation.tokenCount
                )
                if existingById[conversation.id] == nil {
                    context.insert(entity)
                }
                Self.apply(conversation, to: entity, in: context)
            }
            try context.save()
        } catch {
            Self.logger.error("Failed to save conversations to SwiftData: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Loads conversations off the main actor to avoid blocking startup
    private func loadAsync(
        fromBackup: Bool = false
    ) {
        if let loadTask = self.loadTask, !loadTask.isCancelled {
            return
        }
        self.loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            let signpost = StartupMetrics.begin("ConversationManager.loadDatastore")
            defer { StartupMetrics.end("ConversationManager.loadDatastore", signpost) }
            guard let self else { return }
            await MainActor.run {
                self.load(fromBackup: fromBackup)
                self.isLoaded = true
                self.loadTask = nil
            }
        }
    }

    /// Function returning a conversation with the given ID.
    /// Only resolves persisted conversations; the unpersisted
    /// blank-chat draft is owned by ``ConversationState`` and
    /// surfaced by ``ConversationState.selectedConversation``.
    public func getConversation(
        id conversationId: UUID
    ) -> Conversation? {
        return self.conversations.filter({ $0.id == conversationId }).first
    }

    /// Function to load conversations from SwiftData, with a
    /// one-time fallback to the legacy JSON file.
    public func load(
        fromBackup: Bool = false
    ) {
        // Allow opting into the backup JSON path for the existing
        // `restoreFromBackup()` affordance.
        if fromBackup {
            let targetUrl = self.backupDatastoreUrl
            if let rawData = try? Data(contentsOf: targetUrl),
               let legacy = try? JSONDecoder().decode([Conversation].self, from: rawData) {
                self.conversations = legacy
                self.isLoaded = true
                return
            }
        }

        let context = ModelContext(PersistenceController.shared.container)
        do {
            let descriptor = FetchDescriptor<ConversationEntity>(
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
            let rows = try context.fetch(descriptor)
            if !rows.isEmpty {
                self.conversations = rows.map(Self.conversation(from:))
                self.isLoaded = true
                return
            }
        } catch {
            Self.logger.error("Failed to read conversations from SwiftData: \(error.localizedDescription, privacy: .public)")
        }
        // Fall back to JSON on first launch with SwiftData.
        if let rawData = try? Data(contentsOf: self.datastoreUrl),
           let legacy = try? JSONDecoder().decode([Conversation].self, from: rawData) {
            self.conversations = legacy
            self.isLoaded = true
        } else {
            self.newDatastore()
        }
    }

    /// Function to delete a conversation
    public func delete(_ conversation: Binding<Conversation>) {
        withAnimation(.spring()) {
            self.conversations = self.conversations.filter {
                $0.id != conversation.wrappedValue.id
            }
        }
    }

    /// Function to delete a conversation
    public func delete(_ conversation: Conversation) {
        withAnimation(.spring()) {
            self.conversations = self.conversations.filter {
                $0.id != conversation.id
            }
        }
    }

    /// Function to add a conversation
    public func add(_ conversation: Conversation) {
        withAnimation(.spring()) {
            self.conversations.append(conversation)
        }
    }

    /// Function to update a conversation
    public func update(_ conversation: Conversation) {
        for conversationIndex in self.conversations.indices {
            if conversation.id == self.conversations[conversationIndex].id {
                self.conversations[conversationIndex] = conversation
                return
            }
        }
    }

    /// Function to update a conversation
    public func update(_ conversation: Binding<Conversation>) {
        withAnimation(.spring()) {
            let targetId: UUID = conversation.wrappedValue.id
            for index in self.conversations.indices {
                if targetId == self.conversations[index].id {
                    self.conversations[index] = conversation.wrappedValue
                    break
                }
            }
        }
    }

    /// Function to make new datastore
    public func newDatastore() {
        self.patchFileIntegrity()
        self.conversations = []
        self.isLoaded = true
    }

    /// Function to reset datastore
    public func resetDatastore() {
        let _ = Dialogs.showConfirmation(
            title: String(localized: "Delete All Conversations"),
            message: String(localized: "Are you sure you want to delete all conversations?")
        ) {
            self.newDatastore()
        }
    }

    /// Function to create backup for datastore. The JSON file is
    /// still useful as an exportable, human-readable snapshot of
    /// the user's history.
    public func createBackup() {
        do {
            let data = try JSONEncoder().encode(self.conversations)
            try? FileManager.default.createDirectory(
                at: self.datastoreDirUrl,
                withIntermediateDirectories: true
            )
            if self.backupDatastoreUrl.fileExists {
                try? FileManager.default.removeItem(at: self.backupDatastoreUrl)
            }
            try data.write(to: self.backupDatastoreUrl, options: .atomic)
        } catch {
            Self.logger.error("Failed to create backup: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Function to restore from backup
    public func retoreFromBackup() {
        let _ = Dialogs.showConfirmation(
            title: String(localized: "Restore"),
            message: String(localized: "Are you sure you want to restore conversations from a backup? All current conversations will be deleted.")
        ) {
            self.load(fromBackup: true)
            self.save()
        }
    }

    /// Function to patch file integrity. The directory is kept so
    /// the legacy JSON fallback / backup paths continue to work.
    public func patchFileIntegrity() {
        if !self.datastoreDirExists {
            try? FileManager.default.createDirectory(
                at: datastoreDirUrl,
                withIntermediateDirectories: true
            )
        }
    }

    /// Legacy datastore directory (kept for the JSON fallback /
    /// backup affordances).
    public var datastoreDirUrl: URL {
        return Settings.containerUrl.appendingPathComponent(
            "Conversations"
        )
    }

    private var datastoreDirExists: Bool {
        return self.datastoreDirUrl.fileExists
    }

    /// Legacy datastore url (kept for the JSON fallback).
    public var datastoreUrl: URL {
        return self.datastoreDirUrl.appendingPathComponent(
            "conversations.json"
        )
    }

    /// Backup datastore url.
    public var backupDatastoreUrl: URL {
        return self.datastoreDirUrl.appendingPathComponent(
            "conversationsBackup.json"
        )
    }
}

// MARK: - Struct <-> Entity mapping

extension ConversationManager {

    fileprivate static func apply(
        _ conversation: Conversation,
        to entity: ConversationEntity,
        in context: ModelContext
    ) {
        entity.title = conversation.title
        entity.createdAt = conversation.createdAt
        entity.expertId = conversation.expertId
        entity.tokenCount = conversation.tokenCount

        var existingMessages: [UUID: MessageEntity] = [:]
        for messageEntity in entity.messages {
            existingMessages[messageEntity.id] = messageEntity
        }
        let desiredIds = Set(conversation.messages.map(\.id))
        for (id, messageEntity) in existingMessages where !desiredIds.contains(id) {
            context.delete(messageEntity)
        }
        for message in conversation.messages {
            let messageEntity = existingMessages[message.id] ?? MessageEntity(
                id: message.id,
                text: message.text,
                senderRaw: message.getSender().rawValue,
                model: message.model
            )
            if existingMessages[message.id] == nil {
                messageEntity.conversation = entity
                context.insert(messageEntity)
            }
            apply(message, to: messageEntity, in: context)
        }
    }

    fileprivate static func apply(
        _ message: Message,
        to entity: MessageEntity,
        in context: ModelContext
    ) {
        let encoder = JSONEncoder()
        entity.text = message.text
        entity.senderRaw = message.getSender().rawValue
        entity.model = message.model
        entity.expertId = message.expertId
        entity.imageUrl = message.imageUrl
        entity.startTime = message.startTime
        entity.lastUpdated = message.lastUpdated
        entity.reasoningEndTime = message.reasoningEndTime
        entity.responseStartSeconds = message.responseStartSeconds
        entity.tokensPerSecond = message.tokensPerSecond
        entity.outputEnded = message.outputEnded
        entity.functionCallRecordsData = message.functionCallRecords.flatMap {
            try? encoder.encode($0)
        }
        entity.stepsData = message.steps.isEmpty
            ? nil
            : (try? encoder.encode(message.steps))
        entity.referencedURLsData = try? encoder.encode(message.referencedURLs)

        // Snapshot is 1:1 with cascade delete.
        if let snapshot = message.snapshot {
            let snapshotEntity = entity.snapshot ?? SnapshotEntity(id: snapshot.id)
            snapshotEntity.createdAt = snapshot.createdAt
            snapshotEntity.text = snapshot.text
            snapshotEntity.originalText = snapshot.originalText
            snapshotEntity.siteId = snapshot.site?.id
            snapshotEntity.siteHTML = snapshot.site?.html
            snapshotEntity.siteCSS = snapshot.site?.css
            snapshotEntity.siteJS = snapshot.site?.js
            if entity.snapshot == nil {
                context.insert(snapshotEntity)
                entity.snapshot = snapshotEntity
            }
        } else if let existing = entity.snapshot {
            context.delete(existing)
        }
    }

    fileprivate static func conversation(from entity: ConversationEntity) -> Conversation {
        var conversation = Conversation(
            id: entity.id,
            title: entity.title,
            expertId: entity.expertId,
            createdAt: entity.createdAt,
            messages: entity.messages
                .sorted(by: { $0.startTime < $1.startTime })
                .map(message(from:))
        )
        conversation.tokenCount = entity.tokenCount
        return conversation
    }

    fileprivate static func message(from entity: MessageEntity) -> Message {
        let decoder = JSONDecoder()
        let functionCallRecords: [FunctionCallRecord]? = entity.functionCallRecordsData.flatMap {
            try? decoder.decode([FunctionCallRecord].self, from: $0)
        }
        let steps: [MessageStep] = {
            guard let data = entity.stepsData else { return [] }
            return (try? decoder.decode([MessageStep].self, from: data)) ?? []
        }()
        let referencedURLs: [ReferencedURL] = {
            guard let data = entity.referencedURLsData else { return [] }
            return (try? decoder.decode([ReferencedURL].self, from: data)) ?? []
        }()
        let snapshot: Snapshot? = entity.snapshot.map { snap in
            var site: Snapshot.Site?
            if let html = snap.siteHTML {
                var resolvedSite = Snapshot.Site(
                    html: html,
                    css: snap.siteCSS,
                    js: snap.siteJS
                )
                if let siteId = snap.siteId {
                    resolvedSite.id = siteId
                }
                site = resolvedSite
            }
            var result = Snapshot(text: snap.text, site: site)
            result.id = snap.id
            result.originalText = snap.originalText
            return result
        }
        return Message(
            id: entity.id,
            text: entity.text,
            sender: Sender(rawValue: entity.senderRaw) ?? .assistant,
            model: entity.model,
            expertId: entity.expertId,
            imageUrl: entity.imageUrl,
            startTime: entity.startTime,
            lastUpdated: entity.lastUpdated,
            reasoningEndTime: entity.reasoningEndTime,
            responseStartSeconds: entity.responseStartSeconds,
            tokensPerSecond: entity.tokensPerSecond,
            outputEnded: entity.outputEnded,
            functionCallRecords: functionCallRecords,
            steps: steps,
            referencedURLs: referencedURLs,
            snapshot: snapshot
        )
    }
}

// MARK: - Conversation hydration

extension Conversation {
    /// Convenience initialiser used by ``ConversationManager`` to
    /// hydrate a struct from a ``ConversationEntity``.
    init(
        id: UUID,
        title: String,
        expertId: UUID?,
        createdAt: Date,
        messages: [Message]
    ) {
        self.id = id
        self.title = title
        self.expertId = expertId
        self.createdAt = createdAt
        self.messages = messages
    }
}

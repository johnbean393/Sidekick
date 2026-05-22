//
//  Memories.swift
//  Sidekick
//
//  Created by John Bean on 4/22/25.
//
//  Migrated to SwiftData on 5/23/26. The public API is unchanged
//  (a `@Published` `[Memory]` array plus `remember/forget/update/recall`),
//  but persistence now lives in ``MemoryEntity`` rows linked to their
//  source ``MessageEntity`` (via `messageId`). The embedding-bearing
//  `IndexItem` is JSON-encoded into ``MemoryEntity.indexItemData``,
//  which is annotated `@Attribute(.externalStorage)` to keep large
//  vectors out of the main SQLite blob. The recall path is unchanged
//  apart from sourcing rows from SwiftData.
//

import Foundation
import Observation
import OSLog
import SimilaritySearchKit
import SimilaritySearchKitDistilbert
import SwiftData
import SwiftUI

/// Observable, SwiftData-backed memory recall service.
///
/// Replaces the legacy `Memories: ObservableObject` singleton. The
/// in-memory cache is still kept (memories are typically small in
/// volume and the recall path needs random access for the
/// embedding-similarity search) but the storage half is now plain
/// SwiftData and reactivity flows through the Observation
/// framework, matching the rest of the migrated services.
@MainActor
@Observable
public final class MemoryIndex {

    /// A `Logger` object for ``MemoryIndex``.
    @ObservationIgnored
    private static let logger: Logger = .init(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: MemoryIndex.self)
    )

    public init() {
        let signpost = StartupMetrics.begin("MemoryIndex.init")
        self.patchFileIntegrity()
        self.loadAsync()
        StartupMetrics.end("MemoryIndex.init", signpost)
    }

    /// Process-wide instance. Kept for convenience: this is an
    /// `@Observable` service (not a heavy `ObservableObject`
    /// singleton) and is injected into the environment from
    /// ``SidekickApp``.
    public static let shared: MemoryIndex = .init()

    /// Computed property returning the datastore's directory's url
    public static var datastoreDirUrl: URL {
        return Settings.containerUrl.appendingPathComponent(
            "Memory"
        )
    }

    /// Computed property returning if datastore directory exists
    private static var datastoreDirExists: Bool {
        return Self.datastoreDirUrl.fileExists
    }

    /// Computed property returning the datastore's url (legacy JSON
    /// path, retained for the one-time migration fallback).
    public static var datastoreUrl: URL {
        return Self.datastoreDirUrl.appendingPathComponent(
            "memories.json"
        )
    }

    /// All memories.
    public var memories: [Memory] = []
    /// Whether the datastore has been loaded.
    public private(set) var isLoaded: Bool = false
    /// Task handling asynchronous datastore loading.
    @ObservationIgnored
    private var loadTask: Task<Void, Never>?
    /// The memories similarity index.
    @ObservationIgnored
    private var similarityIndex: SimilarityIndex?
    /// Function to initialize similarity index
    private func initSimilarityIndex() async {
        if self.similarityIndex != nil {
            return
        }
        guard RetrievalSettings.useMemory else {
            return
        }
        let signpost = StartupMetrics.begin("Memories.initSimilarityIndex")
        self.similarityIndex = await SimilarityIndex(
            model: DistilbertEmbeddings(),
            metric: CosineSimilarity()
        )
        StartupMetrics.end("Memories.initSimilarityIndex", signpost)
    }
    
    /// Function to make new datastore
    public func newDatastore() {
        self.patchFileIntegrity()
        self.memories = []
        self.isLoaded = true
        self.save()
    }
    
    /// Loads memories asynchronously to avoid blocking startup
    private func loadAsync() {
        if let loadTask = self.loadTask, !loadTask.isCancelled {
            return
        }
        self.loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            let signpost = StartupMetrics.begin("Memories.loadDatastore")
            defer { StartupMetrics.end("Memories.loadDatastore", signpost) }
            guard let self else { return }
            await MainActor.run {
                self.load()
                self.loadTask = nil
            }
        }
    }
    
    /// Function to reset datastore
    @MainActor
    public func resetDatastore() {
        let _ = Dialogs.showConfirmation(
            title: String(localized: "Delete All Memories"),
            message: String(localized: "Are you sure you want to delete all memories?")
        ) {
            self.newDatastore()
        }
    }
    
    /// Function to load memories from SwiftData with a one-time
    /// fallback to the legacy JSON file.
    private func load() {
        let context = ModelContext(PersistenceController.shared.container)
        do {
            let rows = try context.fetch(FetchDescriptor<MemoryEntity>())
            if !rows.isEmpty {
                self.memories = rows.compactMap(Self.memory(from:))
                self.isLoaded = true
                return
            }
        } catch {
            Self.logger.error("Failed to read memories from SwiftData: \(error.localizedDescription, privacy: .public)")
        }
        if let rawData = try? Data(contentsOf: Self.datastoreUrl),
           let legacy = try? JSONDecoder().decode([Memory].self, from: rawData) {
            self.memories = legacy
            self.isLoaded = true
            self.save()
        } else {
            self.newDatastore()
        }
    }
    
    /// Function to save memories to SwiftData. We rewrite the
    /// memory table on each save — the volume is small (memories
    /// accumulate slowly and are typically <1k entries) so a full
    /// rewrite stays cheap, and an upsert path would buy little.
    public func save() {
        let context = ModelContext(PersistenceController.shared.container)
        do {
            let existing = try context.fetch(FetchDescriptor<MemoryEntity>())
            var existingById: [UUID: MemoryEntity] = [:]
            for entity in existing {
                existingById[entity.id] = entity
            }
            let desiredIds = Set(self.memories.map(\.id))
            for (id, entity) in existingById where !desiredIds.contains(id) {
                context.delete(entity)
            }
            let messages = try context.fetch(FetchDescriptor<MessageEntity>())
            var messageById: [UUID: MessageEntity] = [:]
            for message in messages {
                messageById[message.id] = message
            }
            let encoder = JSONEncoder()
            for memory in self.memories {
                let entity = existingById[memory.id] ?? MemoryEntity(
                    id: memory.id,
                    messageId: memory.messageId,
                    createdAt: memory.createdAt,
                    text: memory.text
                )
                if existingById[memory.id] == nil {
                    context.insert(entity)
                }
                entity.messageId = memory.messageId
                entity.createdAt = memory.createdAt
                entity.text = memory.text
                entity.indexItemData = try? encoder.encode(memory.indexItem)
                entity.message = messageById[memory.messageId]
            }
            try context.save()
        } catch {
            Self.logger.error("Failed to save memories to SwiftData: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    /// Function to patch file integrity. The directory is preserved
    /// so the legacy JSON fallback continues to work.
    public func patchFileIntegrity() {
        if !Self.datastoreDirExists {
            do {
                try FileManager.default.createDirectory(
                    at: Self.datastoreDirUrl,
                    withIntermediateDirectories: true
                )
            } catch {
                Self.logger.error("Failed to create directory for datastore: \(error, privacy: .public)")
            }
        }
    }
    
    /// Function to recall related memory
    public func recall(
        prompt: String,
        maxResults: Int = 5
    ) async -> [String]? {
        if self.similarityIndex == nil {
            await self.initSimilarityIndex()
        }
        if let similarityIndex = self.similarityIndex {
            similarityIndex.indexItems = memories.map(
                keyPath: \.indexItem
            )
            let threshold: Float = 0.6
            let results = await similarityIndex.search(
                prompt,
                top: maxResults,
                metric: CosineSimilarity()
            ).filter { result in
                result.score >= threshold
            }
            return results.map { result in
                return result.text
            }
        } else {
            return nil
        }
    }
    
    /// Function to delete a memory
    public func forget(_ memory: Memory) {
        withAnimation(.linear) {
            self.memories = self.memories.filter {
                $0.id != memory.id
            }
        }
        self.save()
    }
    
    /// Function to add a memory
    public func remember(_ memory: Memory) {
        withAnimation(.linear) {
            self.memories.append(memory)
        }
        self.save()
    }
    
    /// Function to update a memory
    public func update(_ memory: Memory) {
        withAnimation(.linear) {
            for memoryIndex in self.memories.indices {
                if memory.id == self.memories[memoryIndex].id {
                    self.memories[memoryIndex] = memory
                    break
                }
            }
        }
        self.save()
    }
    
    /// Function to update a memory
    public func update(_ memory: Binding<Memory>) {
        withAnimation(.spring()) {
            let targetId: UUID = memory.wrappedValue.id
            for index in self.memories.indices {
                if targetId == self.memories[index].id {
                    self.memories[index] = memory.wrappedValue
                    break
                }
            }
        }
        self.save()
    }
    
    /// Function to remember if needed
    public func rememberIfNeeded(
        messageId: UUID,
        text: String
    ) async {
        if !RetrievalSettings.useMemory {
            return
        }
        let messageText: String = """
The user sent the message below. What personal information / opinion does this reveal about the user? Do not extract the information if it is very message specific, such as a specific request. 

Respond in the format `The user [verb] [information]`. If there is no personal information / opinion, respond with the word "nil".

Example responses:
1. The user has a dog named Biscuit.
2. The user thinks Hollywood peaked in the 90s
3. nil

"\(text)"
"""
        let systemPromptMessage: Message = Message(
            text: InferenceSettings.systemPrompt,
            sender: .system
        )
        let commandMessage: Message = Message(
            text: messageText,
            sender: .user
        )
        Model.shared.indicateStartedBackgroundTask()
        if let response: String = (try? await Model.shared.listenThinkRespond(
            messages: [
                systemPromptMessage,
                commandMessage
            ],
            modelType: .worker,
            mode: .default
        ))?.text {
            let formatPass: Bool = response.hasPrefix(
                "The user"
            ) && (15...400).contains(response.count)
            if formatPass,
               let memory: Memory = await Memory(
                messageId: messageId,
                text: response
               ) {
                self.remember(memory)
            }
        }
    }
    
    /// Function to find memories related to a message
    public func getMemories(
        id messageId: UUID
    ) -> Memory? {
        return self.memories.filter({
            $0.messageId == messageId
        }).first
    }
    
}

// MARK: - Memory <-> MemoryEntity mapping

extension MemoryIndex {

    fileprivate static func memory(from entity: MemoryEntity) -> Memory? {
        // The `SimilarityIndex.IndexItem` memberwise initialiser is
        // not exposed outside its defining module, so we can only
        // hydrate memories whose embedding vector survived the
        // JSON round-trip. Rows with missing/corrupt index data are
        // dropped; they'll be regenerated the next time the user
        // exercises the memory recall path on the matching message.
        guard let data = entity.indexItemData,
              let indexItem = try? JSONDecoder().decode(
                SimilarityIndex.IndexItem.self,
                from: data
              ) else {
            return nil
        }
        return Memory(
            id: entity.id,
            messageId: entity.messageId,
            createdAt: entity.createdAt,
            indexItem: indexItem
        )
    }
}

// MARK: - Memory hydration

extension Memory {
    /// Convenience initialiser used by ``MemoryIndex`` to hydrate
    /// a struct from a ``MemoryEntity`` row.
    init(
        id: UUID,
        messageId: UUID,
        createdAt: Date,
        indexItem: SimilarityIndex.IndexItem
    ) {
        self.id = id
        self.messageId = messageId
        self.createdAt = createdAt
        self.indexItem = indexItem
    }
}

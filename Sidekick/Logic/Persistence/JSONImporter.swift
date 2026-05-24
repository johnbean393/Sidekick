//
//  JSONImporter.swift
//  Sidekick
//
//  One-time importer that lifts legacy JSON datastores into the
//  SwiftData store. Triggered by ``Refactorer`` on first launch
//  after the SwiftData migration is enabled.
//
//  Importing is idempotent at the row level: if a row with a
//  matching `id` already exists in SwiftData, the JSON copy is
//  skipped. After all phases complete successfully, the source
//  JSON files are moved to `…/Legacy/<filename>.json.legacy` as a
//  safety net.
//

import Foundation
import OSLog
import SwiftData

/// Imports legacy JSON datastores into SwiftData.
public enum JSONImporter {

    private static let logger: Logger = .init(
        subsystem: Bundle.main.bundleIdentifier!,
        category: "JSONImporter"
    )

    /// Runs every importer stage on a fresh `ModelContext` derived
    /// from the supplied container.
    ///
    /// Throws on the first stage that fails; the caller (typically
    /// ``Refactorer``) is responsible for preserving the legacy
    /// files when this throws.
    @MainActor
    public static func importAll(into container: ModelContainer) throws {
        let context = ModelContext(container)

        try importExperts(context: context)
        try importConversations(context: context)
        try importSourcesIfNeeded(context: context)
        try importMemoriesIfNeeded(context: context)
        try importLocalModels(context: context)
        try importServerArguments(context: context)
        try importInferenceRecords(context: context)
        try importFunctionSelection(context: context)

        try context.save()
        Self.logger.info("JSONImporter.importAll completed successfully.")
    }

    /// `true` when at least one of the legacy JSON datastores is
    /// still on disk, indicating a one-time import is required.
    public static var legacyJSONExists: Bool {
        return legacyJSONURLs.contains(where: { $0.fileExists })
    }

    /// Centralised list of every legacy JSON file the importer
    /// knows about. Used by both the existence check and the
    /// archiver below to keep the two in sync.
    private static var legacyJSONURLs: [URL] {
        [
            Settings.containerUrl.appendingPathComponent("Conversations").appendingPathComponent("conversations.json"),
            Settings.containerUrl.appendingPathComponent("Conversations").appendingPathComponent("conversationsBackup.json"),
            Settings.containerUrl.appendingPathComponent("Profiles").appendingPathComponent("profiles.json"),
            Settings.containerUrl.appendingPathComponent("Memory").appendingPathComponent("memories.json"),
            Settings.containerUrl.appendingPathComponent("Sources").appendingPathComponent("sources.json"),
            Settings.containerUrl.appendingPathComponent("Commands").appendingPathComponent("commands.json"),
            Settings.containerUrl.appendingPathComponent("Models").appendingPathComponent("models.json"),
            Settings.containerUrl.appendingPathComponent("Server Arguments").appendingPathComponent("serverArguments.json"),
            Settings.containerUrl.appendingPathComponent("Inference Records").appendingPathComponent("records.json"),
            Settings.containerUrl.appendingPathComponent("Cache").appendingPathComponent("function_selection.json")
        ]
    }

    /// Moves every legacy JSON store under
    /// `…/com.pattonium.Sidekick/Legacy/`. Safe to call repeatedly;
    /// missing files are silently skipped.
    public static func archiveLegacyJSON() {
        let legacyRoot = Settings.containerUrl.appendingPathComponent("Legacy", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: legacyRoot,
            withIntermediateDirectories: true
        )
        for url in legacyJSONURLs where url.fileExists {
            let destination = legacyRoot.appendingPathComponent("\(url.lastPathComponent).legacy")
            if destination.fileExists {
                try? FileManager.default.removeItem(at: destination)
            }
            try? FileManager.default.moveItem(at: url, to: destination)
        }
    }

    // MARK: - Conversations / messages / snapshots

    @MainActor
    private static func importConversations(context: ModelContext) throws {
        let url = Settings.containerUrl
            .appendingPathComponent("Conversations")
            .appendingPathComponent("conversations.json")
        guard let data = try? Data(contentsOf: url) else { return }
        let conversations = try JSONDecoder().decode([Conversation].self, from: data)

        let existingIds = try existingIdSet(MessageEntity.self, in: context, keyPath: \.id)
        let existingConvIds = try existingIdSet(ConversationEntity.self, in: context, keyPath: \.id)

        for convo in conversations where !existingConvIds.contains(convo.id) {
            let convoEntity = ConversationEntity(
                id: convo.id,
                title: convo.title,
                createdAt: convo.createdAt,
                expertId: convo.expertId,
                tokenCount: convo.tokenCount
            )
            context.insert(convoEntity)

            for message in convo.messages where !existingIds.contains(message.id) {
                let entity = mapMessage(message)
                entity.conversation = convoEntity
                context.insert(entity)
            }
        }
        Self.logger.info("Imported \(conversations.count) conversations from JSON")
    }

    private static func mapMessage(_ message: Message) -> MessageEntity {
        let encoder = JSONEncoder()
        let functionCallData = message.functionCallRecords.flatMap {
            try? encoder.encode($0)
        }
        let stepsData: Data? = message.steps.isEmpty
            ? nil
            : (try? encoder.encode(message.steps))
        let referencedURLsData = try? encoder.encode(message.referencedURLs)

        let entity = MessageEntity(
            id: message.id,
            text: message.text,
            senderRaw: message.getSender().rawValue,
            model: message.model,
            expertId: message.expertId,
            imageUrl: message.imageUrl,
            startTime: message.startTime,
            lastUpdated: message.lastUpdated,
            reasoningEndTime: message.reasoningEndTime,
            responseStartSeconds: message.responseStartSeconds,
            tokensPerSecond: message.tokensPerSecond,
            outputEnded: message.outputEnded,
            functionCallRecordsData: functionCallData,
            stepsData: stepsData,
            referencedURLsData: referencedURLsData
        )
        if let snapshot = message.snapshot {
            entity.snapshot = SnapshotEntity(
                id: snapshot.id,
                createdAt: snapshot.createdAt,
                text: snapshot.text,
                originalText: snapshot.originalText,
                siteId: snapshot.site?.id,
                siteHTML: snapshot.site?.html,
                siteCSS: snapshot.site?.css,
                siteJS: snapshot.site?.js
            )
        }
        return entity
    }

    // MARK: - Sources

    @MainActor
    private static func importSourcesIfNeeded(context: ModelContext) throws {
        let url = Settings.containerUrl
            .appendingPathComponent("Sources")
            .appendingPathComponent("sources.json")
        guard let data = try? Data(contentsOf: url) else { return }
        let sources = try JSONDecoder().decode([Sources].self, from: data)

        // Build a quick lookup of messages by id so the importer can
        // attach Source rows to the correct parent.
        let messages = try context.fetch(FetchDescriptor<MessageEntity>())
        var messageById: [UUID: MessageEntity] = [:]
        for message in messages {
            messageById[message.id] = message
        }

        var added = 0
        for bundle in sources {
            guard let parent = messageById[bundle.messageId] else { continue }
            for source in bundle.sources {
                let entity = SourceEntity(
                    id: source.id,
                    text: source.text,
                    source: source.source
                )
                entity.message = parent
                context.insert(entity)
                added += 1
            }
        }
        Self.logger.info("Imported \(added) sources from JSON")
    }

    // MARK: - Memories

    @MainActor
    private static func importMemoriesIfNeeded(context: ModelContext) throws {
        let url = Settings.containerUrl
            .appendingPathComponent("Memory")
            .appendingPathComponent("memories.json")
        guard let data = try? Data(contentsOf: url) else { return }
        let memories = try JSONDecoder().decode([Memory].self, from: data)

        let messages = try context.fetch(FetchDescriptor<MessageEntity>())
        var messageById: [UUID: MessageEntity] = [:]
        for message in messages {
            messageById[message.id] = message
        }

        let existingIds = try existingIdSet(MemoryEntity.self, in: context, keyPath: \.id)
        let encoder = JSONEncoder()
        for memory in memories where !existingIds.contains(memory.id) {
            let entity = MemoryEntity(
                id: memory.id,
                messageId: memory.messageId,
                createdAt: memory.createdAt,
                text: memory.text,
                indexItemData: try? encoder.encode(memory.indexItem)
            )
            if let parent = messageById[memory.messageId] {
                entity.message = parent
            }
            context.insert(entity)
        }
        Self.logger.info("Imported \(memories.count) memories from JSON")
    }

    // MARK: - Experts

    @MainActor
    private static func importExperts(context: ModelContext) throws {
        let url = Settings.containerUrl
            .appendingPathComponent("Profiles")
            .appendingPathComponent("profiles.json")
        guard let data = try? Data(contentsOf: url) else { return }
        let experts = try JSONDecoder().decode([Expert].self, from: data)

        let existingIds = try existingIdSet(ExpertEntity.self, in: context, keyPath: \.id)
        for expert in experts where !existingIds.contains(expert.id) {
            let entity = ExpertEntity(
                id: expert.id,
                name: expert.name,
                symbolName: expert.symbolName,
                colorHex: expert.color.toHex() ?? "0000_00FF",
                useWebSearch: expert.useWebSearch,
                systemPrompt: expert.systemPrompt,
                persistResources: expert.persistResources
            )

            let encoder = JSONEncoder()
            let resourcesSet = ResourcesSetEntity(
                id: expert.resources.id,
                statusRaw: expert.resources.status.map { resourcesStatusRawValue($0) },
                useGraphRAG: expert.resources.useGraphRAG,
                graphStatusRaw: expert.resources.graphStatus.map { resourcesGraphStatusRawValue($0) },
                graphProgressData: expert.resources.graphProgress.flatMap { try? encoder.encode($0) }
            )
            entity.resourcesSet = resourcesSet
            context.insert(entity)

            for resource in expert.resources.resources {
                let resourceEntity = mapResource(resource)
                resourceEntity.resourcesSet = resourcesSet
                context.insert(resourceEntity)
            }
        }
        Self.logger.info("Imported \(experts.count) experts from JSON")
    }

    private static func mapResource(_ resource: Resource) -> ResourceItemEntity {
        let entity = ResourceItemEntity(
            id: resource.id,
            urlString: resource.url.absoluteString,
            prevIndexDate: resource.prevIndexDate,
            indexStateRaw: resourceIndexStateRawValue(resource.indexState)
        )
        for child in resource.children {
            let childEntity = mapResource(child)
            childEntity.parent = entity
            entity.children.append(childEntity)
        }
        return entity
    }

    private static func resourcesStatusRawValue(_ status: Resources.Status) -> String {
        switch status {
        case .indexing: return "indexing"
        case .ready: return "ready"
        }
    }

    private static func resourcesGraphStatusRawValue(_ status: Resources.GraphStatus) -> String {
        switch status {
        case .building: return "building"
        case .ready: return "ready"
        case .error: return "error"
        }
    }

    private static func resourceIndexStateRawValue(_ state: Resource.IndexState) -> String {
        switch state {
        case .noIndex: return "noIndex"
        case .indexing: return "indexing"
        case .indexed: return "indexed"
        }
    }

    // MARK: - Local model files

    @MainActor
    private static func importLocalModels(context: ModelContext) throws {
        let url = Settings.containerUrl
            .appendingPathComponent("Models")
            .appendingPathComponent("models.json")
        guard let data = try? Data(contentsOf: url) else { return }
        let models = try JSONDecoder().decode([ModelManager.ModelFile].self, from: data)

        let existingIds = try existingIdSet(LocalModelFileEntity.self, in: context, keyPath: \.id)
        for model in models where !existingIds.contains(model.id) {
            let entity = LocalModelFileEntity(
                id: model.id,
                urlString: model.url.absoluteString
            )
            context.insert(entity)
        }
        Self.logger.info("Imported \(models.count) local models from JSON")
    }

    // MARK: - Server arguments

    @MainActor
    private static func importServerArguments(context: ModelContext) throws {
        let url = Settings.containerUrl
            .appendingPathComponent("Server Arguments")
            .appendingPathComponent("serverArguments.json")
        guard let data = try? Data(contentsOf: url) else { return }
        let arguments = try JSONDecoder().decode([ServerArgument].self, from: data)

        let existingIds = try existingIdSet(ServerArgumentEntity.self, in: context, keyPath: \.id)
        for (index, argument) in arguments.enumerated() where !existingIds.contains(argument.id) {
            let entity = ServerArgumentEntity(
                id: argument.id,
                isActive: argument.isActive,
                flag: argument.flag,
                value: argument.value,
                sortIndex: index
            )
            context.insert(entity)
        }
        Self.logger.info("Imported \(arguments.count) server arguments from JSON")
    }

    // MARK: - Inference records

    @MainActor
    private static func importInferenceRecords(context: ModelContext) throws {
        let url = Settings.containerUrl
            .appendingPathComponent("Inference Records")
            .appendingPathComponent("records.json")
        guard let data = try? Data(contentsOf: url) else { return }
        let records = try JSONDecoder().decode([InferenceRecord].self, from: data)

        let existingIds = try existingIdSet(InferenceRecordEntity.self, in: context, keyPath: \.id)
        for record in records where !existingIds.contains(record.id) {
            let entity = InferenceRecordEntity(
                id: record.id,
                name: record.name,
                startTime: record.startTime,
                endTime: record.endTime,
                typeRaw: record.type.rawValue,
                endpointString: record.endpoint?.absoluteString,
                inputTokens: record.inputTokens,
                outputTokens: record.outputTokens,
                tokensPerSecond: record.tokensPerSecond
            )
            context.insert(entity)
        }
        Self.logger.info("Imported \(records.count) inference records from JSON")
    }

    // MARK: - Function selection

    @MainActor
    private static func importFunctionSelection(context: ModelContext) throws {
        let url = Settings.containerUrl
            .appendingPathComponent("Cache")
            .appendingPathComponent("function_selection.json")
        guard let data = try? Data(contentsOf: url) else { return }
        let categories = try JSONDecoder().decode([FunctionCategory].self, from: data)

        let existing = try context.fetch(FetchDescriptor<FunctionCategorySelectionEntity>())
        let existingRawValues = Set(existing.map(\.rawValue))
        for category in categories where !existingRawValues.contains(category.rawValue) {
            context.insert(FunctionCategorySelectionEntity(rawValue: category.rawValue))
        }
        Self.logger.info("Imported \(categories.count) function categories from JSON")
    }

    // MARK: - Helpers

    private static func existingIdSet<Model: PersistentModel>(
        _ type: Model.Type,
        in context: ModelContext,
        keyPath: KeyPath<Model, UUID>
    ) throws -> Set<UUID> {
        let descriptor = FetchDescriptor<Model>()
        let rows = try context.fetch(descriptor)
        return Set(rows.map { $0[keyPath: keyPath] })
    }
}

//
//  SidekickSchema.swift
//  Sidekick
//
//  Created as part of the JSON → SwiftData migration.
//
//  Hosts every persisted `@Model` class and the `VersionedSchema`
//  that ties them together. The schema is intentionally compact:
//  large auxiliary Codable structs (function call records, referenced
//  URLs, graph progress, etc.) are stored as `Data` on their parent
//  entity to avoid an explosion of small tables, while top-level
//  domain types (Conversation, Message, Expert, …) and their
//  primary children get real relationships with cascade rules.
//
//  Filesystem sidecars (SimilaritySearchKit JSON vector indexes,
//  graph.sqlite, Cache/Canvas/*, Generated Images/, .gguf binaries)
//  stay on disk; SwiftData only persists metadata + UUIDs/paths.
//

import Foundation
import SwiftData

// MARK: - Schema

/// Versioned schema for Sidekick's SwiftData store.
///
/// All persisted `@Model` classes are listed in ``models``. To roll
/// out a schema change, add `SidekickSchemaV2` (a new
/// `VersionedSchema`) and extend `SidekickSchemaMigrationPlan` with
/// the appropriate migration stages.
public enum SidekickSchemaV1: VersionedSchema {

    public static var versionIdentifier: Schema.Version {
        Schema.Version(1, 0, 0)
    }

    public static var models: [any PersistentModel.Type] {
        [
            ConversationEntity.self,
            MessageEntity.self,
            SourceEntity.self,
            MemoryEntity.self,
            SnapshotEntity.self,
            ExpertEntity.self,
            ResourcesSetEntity.self,
            ResourceItemEntity.self,
            CommandEntity.self,
            LocalModelFileEntity.self,
            ServerArgumentEntity.self,
            InferenceRecordEntity.self,
            FunctionCategorySelectionEntity.self
        ]
    }
}

/// Migration plan for Sidekick's SwiftData store. Starts at V1 and
/// is expected to gain `MigrationStage` entries as the schema
/// evolves.
public enum SidekickSchemaMigrationPlan: SchemaMigrationPlan {

    public static var schemas: [any VersionedSchema.Type] {
        [SidekickSchemaV1.self]
    }

    public static var stages: [MigrationStage] {
        []
    }
}

// MARK: - Conversation

@Model
public final class ConversationEntity {

    @Attribute(.unique) public var id: UUID
    public var title: String
    public var createdAt: Date
    public var tokenCount: Int?

    /// Foreign key to ``ExpertEntity`` stored as a UUID. We keep this
    /// as a loose reference (rather than a SwiftData relationship)
    /// because the previous JSON store used UUID FKs and the rest of
    /// the app already looks experts up by id.
    public var expertId: UUID?

    @Relationship(deleteRule: .cascade, inverse: \MessageEntity.conversation)
    public var messages: [MessageEntity] = []

    public init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = .now,
        expertId: UUID? = nil,
        tokenCount: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.expertId = expertId
        self.tokenCount = tokenCount
    }
}

// MARK: - Message

@Model
public final class MessageEntity {

    @Attribute(.unique) public var id: UUID

    public var text: String
    /// Raw value of ``Sender`` (`user` / `assistant` / `system` / `tool`).
    public var senderRaw: String
    public var model: String
    public var expertId: UUID?

    public var imageUrl: URL?

    public var startTime: Date
    public var lastUpdated: Date
    public var responseStartSeconds: Double?
    public var tokensPerSecond: Double?
    public var outputEnded: Bool

    /// JSON-encoded `[FunctionCallRecord]?` — small payload, low
    /// cardinality, written once when a function call completes.
    public var functionCallRecordsData: Data?
    /// JSON-encoded `[ReferencedURL]` — small, rewritten once per
    /// streaming response when the assistant emits a reference list.
    public var referencedURLsData: Data?

    @Relationship(deleteRule: .cascade, inverse: \SnapshotEntity.message)
    public var snapshot: SnapshotEntity?

    @Relationship(deleteRule: .cascade, inverse: \SourceEntity.message)
    public var sources: [SourceEntity] = []

    @Relationship(deleteRule: .cascade, inverse: \MemoryEntity.message)
    public var memory: MemoryEntity?

    public var conversation: ConversationEntity?

    public init(
        id: UUID = UUID(),
        text: String,
        senderRaw: String,
        model: String,
        expertId: UUID? = nil,
        imageUrl: URL? = nil,
        startTime: Date = .now,
        lastUpdated: Date = .now,
        responseStartSeconds: Double? = nil,
        tokensPerSecond: Double? = nil,
        outputEnded: Bool = false,
        functionCallRecordsData: Data? = nil,
        referencedURLsData: Data? = nil
    ) {
        self.id = id
        self.text = text
        self.senderRaw = senderRaw
        self.model = model
        self.expertId = expertId
        self.imageUrl = imageUrl
        self.startTime = startTime
        self.lastUpdated = lastUpdated
        self.responseStartSeconds = responseStartSeconds
        self.tokensPerSecond = tokensPerSecond
        self.outputEnded = outputEnded
        self.functionCallRecordsData = functionCallRecordsData
        self.referencedURLsData = referencedURLsData
    }
}

// MARK: - Source

@Model
public final class SourceEntity {

    @Attribute(.unique) public var id: UUID
    public var text: String
    public var source: String

    public var message: MessageEntity?

    public init(
        id: UUID = UUID(),
        text: String,
        source: String
    ) {
        self.id = id
        self.text = text
        self.source = source
    }
}

// MARK: - Memory

@Model
public final class MemoryEntity {

    @Attribute(.unique) public var id: UUID
    public var messageId: UUID
    public var createdAt: Date
    public var text: String
    /// Embedded JSON-encoded `SimilarityIndex.IndexItem` snapshot
    /// (kept in external storage because the embedding vector can be
    /// large enough to be worth keeping out of the main SQLite blob).
    @Attribute(.externalStorage) public var indexItemData: Data?

    public var message: MessageEntity?

    public init(
        id: UUID = UUID(),
        messageId: UUID,
        createdAt: Date = .now,
        text: String,
        indexItemData: Data? = nil
    ) {
        self.id = id
        self.messageId = messageId
        self.createdAt = createdAt
        self.text = text
        self.indexItemData = indexItemData
    }
}

// MARK: - Snapshot

@Model
public final class SnapshotEntity {

    @Attribute(.unique) public var id: UUID
    public var createdAt: Date

    public var text: String
    public var originalText: String?

    /// When the snapshot represents a canvas site, this identifies
    /// the on-disk cache directory at `Cache/Canvas/{siteId}/`.
    /// `nil` indicates a text-only snapshot.
    public var siteId: UUID?
    /// Stored HTML/CSS/JS for the snapshot. We keep these so the
    /// snapshot can be re-rendered even if the on-disk cache is
    /// missing.
    public var siteHTML: String?
    public var siteCSS: String?
    public var siteJS: String?

    public var message: MessageEntity?

    public init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        text: String = "",
        originalText: String? = nil,
        siteId: UUID? = nil,
        siteHTML: String? = nil,
        siteCSS: String? = nil,
        siteJS: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.text = text
        self.originalText = originalText
        self.siteId = siteId
        self.siteHTML = siteHTML
        self.siteCSS = siteCSS
        self.siteJS = siteJS
    }
}

// MARK: - Expert

@Model
public final class ExpertEntity {

    @Attribute(.unique) public var id: UUID

    public var name: String
    public var symbolName: String
    /// Hex-encoded RGBA string for the expert's color.
    public var colorHex: String
    public var useWebSearch: Bool
    public var systemPrompt: String?
    public var persistResources: Bool

    @Relationship(deleteRule: .cascade, inverse: \ResourcesSetEntity.expert)
    public var resourcesSet: ResourcesSetEntity?

    public init(
        id: UUID = UUID(),
        name: String,
        symbolName: String,
        colorHex: String,
        useWebSearch: Bool = true,
        systemPrompt: String? = nil,
        persistResources: Bool = true
    ) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.colorHex = colorHex
        self.useWebSearch = useWebSearch
        self.systemPrompt = systemPrompt
        self.persistResources = persistResources
    }
}

// MARK: - Resources

@Model
public final class ResourcesSetEntity {

    @Attribute(.unique) public var id: UUID

    /// Raw value of `Resources.Status` (`indexing` / `ready`). `nil`
    /// means the set has never been indexed.
    public var statusRaw: String?

    public var useGraphRAG: Bool
    /// Raw value of `Resources.GraphStatus`.
    public var graphStatusRaw: String?
    /// JSON-encoded `Resources.GraphProgress`.
    public var graphProgressData: Data?

    @Relationship(deleteRule: .cascade, inverse: \ResourceItemEntity.resourcesSet)
    public var items: [ResourceItemEntity] = []

    public var expert: ExpertEntity?

    public init(
        id: UUID = UUID(),
        statusRaw: String? = nil,
        useGraphRAG: Bool = false,
        graphStatusRaw: String? = nil,
        graphProgressData: Data? = nil
    ) {
        self.id = id
        self.statusRaw = statusRaw
        self.useGraphRAG = useGraphRAG
        self.graphStatusRaw = graphStatusRaw
        self.graphProgressData = graphProgressData
    }
}

// MARK: - Resource item

@Model
public final class ResourceItemEntity {

    @Attribute(.unique) public var id: UUID
    public var urlString: String
    public var prevIndexDate: Date
    /// Raw value of `Resource.IndexState` (`noIndex` / `indexing` / `indexed`).
    public var indexStateRaw: String

    @Relationship(deleteRule: .cascade, inverse: \ResourceItemEntity.parent)
    public var children: [ResourceItemEntity] = []

    public var parent: ResourceItemEntity?
    public var resourcesSet: ResourcesSetEntity?

    public init(
        id: UUID = UUID(),
        urlString: String,
        prevIndexDate: Date = .distantPast,
        indexStateRaw: String = "noIndex"
    ) {
        self.id = id
        self.urlString = urlString
        self.prevIndexDate = prevIndexDate
        self.indexStateRaw = indexStateRaw
    }
}

// MARK: - Command

@Model
public final class CommandEntity {

    @Attribute(.unique) public var id: UUID
    public var name: String
    public var prompt: String

    public init(
        id: UUID = UUID(),
        name: String,
        prompt: String
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
    }
}

// MARK: - Local model file

@Model
public final class LocalModelFileEntity {

    @Attribute(.unique) public var id: UUID
    public var urlString: String

    public init(
        id: UUID = UUID(),
        urlString: String
    ) {
        self.id = id
        self.urlString = urlString
    }
}

// MARK: - Server argument

@Model
public final class ServerArgumentEntity {

    @Attribute(.unique) public var id: UUID
    public var isActive: Bool
    public var flag: String
    public var value: String
    /// Preserves the user's chosen order so the dashboard renders
    /// arguments deterministically.
    public var sortIndex: Int

    public init(
        id: UUID = UUID(),
        isActive: Bool = false,
        flag: String,
        value: String,
        sortIndex: Int = 0
    ) {
        self.id = id
        self.isActive = isActive
        self.flag = flag
        self.value = value
        self.sortIndex = sortIndex
    }
}

// MARK: - Inference record

@Model
public final class InferenceRecordEntity {

    @Attribute(.unique) public var id: UUID
    public var name: String
    public var startTime: Date
    public var endTime: Date
    /// Raw value of `InferenceRecord.UsageType`.
    public var typeRaw: String
    public var endpointString: String?

    public var inputTokens: Int
    public var outputTokens: Int
    public var tokensPerSecond: Double

    public init(
        id: UUID = UUID(),
        name: String,
        startTime: Date,
        endTime: Date,
        typeRaw: String,
        endpointString: String? = nil,
        inputTokens: Int,
        outputTokens: Int,
        tokensPerSecond: Double
    ) {
        self.id = id
        self.name = name
        self.startTime = startTime
        self.endTime = endTime
        self.typeRaw = typeRaw
        self.endpointString = endpointString
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.tokensPerSecond = tokensPerSecond
    }
}

// MARK: - Function category selection

@Model
public final class FunctionCategorySelectionEntity {

    @Attribute(.unique) public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

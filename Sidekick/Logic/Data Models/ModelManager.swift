//
//  ModelManager.swift
//  Sidekick
//
//  Created by Bean John on 11/8/24.
//
//  Replaced in Phase 2 of the SwiftData migration. ``ModelManager``
//  is now a namespace of static helpers backed by the
//  ``LocalModelFileEntity`` table; the legacy `ObservableObject`
//  singleton is gone. Views read models directly via SwiftData's
//  `@Query`.
//
//  The ``ModelManager/ModelFile`` value type is retained so the
//  many existing references (`ModelManager.ModelFile`, etc.) keep
//  compiling.
//

import Foundation
import FSKit_macOS
import OSLog
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

@MainActor
public enum ModelManager {

    private static let logger: Logger = .init(
        subsystem: Bundle.main.bundleIdentifier!,
        category: "ModelManager"
    )

    /// `UTI` for `.gguf` model files.
    private static let ggufType: UTType = UTType("com.npc-pet.Chats.gguf") ?? .data

    /// Returns the persisted model list in alphabetical order. Lazy
    /// migration: if SwiftData is empty, the legacy `models.json` is
    /// read and mirrored to SwiftData on first call.
    @discardableResult
    public static func models() -> [ModelFile] {
        let context = ModelContext(PersistenceController.shared.container)
        do {
            let rows = try context.fetch(FetchDescriptor<LocalModelFileEntity>())
            if !rows.isEmpty {
                return rows
                    .compactMap { row -> ModelFile? in
                        guard let url = URL(string: row.urlString) else { return nil }
                        return ModelFile(id: row.id, url: url)
                    }
                    .sorted(by: { $0.name < $1.name })
            }
        } catch {
            Self.logger.error(
                "Failed to read models: \(error.localizedDescription, privacy: .public)"
            )
        }
        if let rawData = try? Data(contentsOf: legacyDatastoreUrl),
           let legacy = try? JSONDecoder().decode([ModelFile].self, from: rawData) {
            replace(with: legacy)
            return legacy.sorted(by: { $0.name < $1.name })
        }
        if let currentModelUrl: URL = Settings.modelUrl {
            let seed = [ModelFile(url: currentModelUrl)]
            replace(with: seed)
            return seed
        }
        return []
    }

    /// Wholesale replace the persisted model list.
    public static func replace(with models: [ModelFile]) {
        let context = ModelContext(PersistenceController.shared.container)
        do {
            let existing = try context.fetch(FetchDescriptor<LocalModelFileEntity>())
            for row in existing {
                context.delete(row)
            }
            for model in models {
                context.insert(
                    LocalModelFileEntity(
                        id: model.id,
                        urlString: model.url.absoluteString
                    )
                )
            }
            try context.save()
        } catch {
            Self.logger.error(
                "Failed to save models: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Append a model URL if it isn't already present.
    public static func add(_ modelUrl: URL) {
        let context = ModelContext(PersistenceController.shared.container)
        do {
            let urlString = modelUrl.absoluteString
            let existing = try context.fetch(
                FetchDescriptor<LocalModelFileEntity>(
                    predicate: #Predicate { $0.urlString == urlString }
                )
            )
            if !existing.isEmpty { return }
            context.insert(
                LocalModelFileEntity(
                    id: UUID(),
                    urlString: urlString
                )
            )
            try context.save()
        } catch {
            Self.logger.error(
                "Failed to add model: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Delete a model by id.
    public static func delete(id: UUID) {
        let context = ModelContext(PersistenceController.shared.container)
        do {
            let descriptor = FetchDescriptor<LocalModelFileEntity>(
                predicate: #Predicate { $0.id == id }
            )
            if let row = try context.fetch(descriptor).first {
                context.delete(row)
                try context.save()
            }
        } catch {
            Self.logger.error(
                "Failed to delete model: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Presents an open-file dialog and adds the selected `.gguf` file.
    @discardableResult
    public static func addModel() -> Bool {
        guard
            let modelUrls = try? FileManager.selectFile(
                dialogTitle: String(localized: "Select a Model"),
                canSelectDirectories: false,
                allowedContentTypes: [Self.ggufType],
                allowMultipleSelection: false,
                persistPermissions: true
            ),
            let modelUrl = modelUrls.first
        else {
            return false
        }
        Self.add(modelUrl)
        return true
    }

    /// Presents an open-file dialog and returns the picked URL after
    /// inserting it into the model table. Used by the new add-model
    /// flow that needs to follow up with a load-config sheet.
    @discardableResult
    public static func pickAndAdd() -> URL? {
        guard
            let modelUrls = try? FileManager.selectFile(
                dialogTitle: String(localized: "Select a Model"),
                canSelectDirectories: false,
                allowedContentTypes: [Self.ggufType],
                allowMultipleSelection: false,
                persistPermissions: true
            ),
            let modelUrl = modelUrls.first
        else {
            return nil
        }
        Self.add(modelUrl)
        return modelUrl
    }

    /// Look up the persisted entity for a given model URL.
    public static func entity(for url: URL) -> LocalModelFileEntity? {
        let context = ModelContext(PersistenceController.shared.container)
        let urlString = url.absoluteString
        do {
            return try context.fetch(
                FetchDescriptor<LocalModelFileEntity>(
                    predicate: #Predicate { $0.urlString == urlString }
                )
            ).first
        } catch {
            Self.logger.error(
                "Failed to fetch model entity: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// A value snapshot of a model entity's load + sampling fields.
    /// We hand snapshots to non-MainActor code (e.g. ``LlamaServer``)
    /// because `LocalModelFileEntity` is itself bound to a
    /// `ModelContext` and not safe to share across actors.
    public struct LoadConfig: Equatable {

        public var contextLength: Int?
        public var temperature: Double?
        public var topP: Double?
        public var topK: Int?
        public var minP: Double?
        public var repetitionPenalty: Double?
        public var presencePenalty: Double?
        public var frequencyPenalty: Double?

        public var trainedContextLength: Int?
        public var safeMaxContextLength: Int?
        public var safeMaxComputedAt: Date?
        public var safeMaxComputedForMemoryGB: Int?

        public init(
            contextLength: Int? = nil,
            temperature: Double? = nil,
            topP: Double? = nil,
            topK: Int? = nil,
            minP: Double? = nil,
            repetitionPenalty: Double? = nil,
            presencePenalty: Double? = nil,
            frequencyPenalty: Double? = nil,
            trainedContextLength: Int? = nil,
            safeMaxContextLength: Int? = nil,
            safeMaxComputedAt: Date? = nil,
            safeMaxComputedForMemoryGB: Int? = nil
        ) {
            self.contextLength = contextLength
            self.temperature = temperature
            self.topP = topP
            self.topK = topK
            self.minP = minP
            self.repetitionPenalty = repetitionPenalty
            self.presencePenalty = presencePenalty
            self.frequencyPenalty = frequencyPenalty
            self.trainedContextLength = trainedContextLength
            self.safeMaxContextLength = safeMaxContextLength
            self.safeMaxComputedAt = safeMaxComputedAt
            self.safeMaxComputedForMemoryGB = safeMaxComputedForMemoryGB
        }
    }

    /// Snapshot the persisted load configuration for `url`. Safe to
    /// call from any actor; returns `nil` when the model isn't
    /// registered.
    nonisolated public static func loadConfig(for url: URL) -> LoadConfig? {
        let context = ModelContext(PersistenceController.shared.container)
        let urlString = url.absoluteString
        do {
            guard let row = try context.fetch(
                FetchDescriptor<LocalModelFileEntity>(
                    predicate: #Predicate { $0.urlString == urlString }
                )
            ).first else {
                return nil
            }
            return LoadConfig(
                contextLength: row.contextLength,
                temperature: row.temperature,
                topP: row.topP,
                topK: row.topK,
                minP: row.minP,
                repetitionPenalty: row.repetitionPenalty,
                presencePenalty: row.presencePenalty,
                frequencyPenalty: row.frequencyPenalty,
                trainedContextLength: row.trainedContextLength,
                safeMaxContextLength: row.safeMaxContextLength,
                safeMaxComputedAt: row.safeMaxComputedAt,
                safeMaxComputedForMemoryGB: row.safeMaxComputedForMemoryGB
            )
        } catch {
            return nil
        }
    }

    /// Mutate the persisted entity for `url`. The closure receives the
    /// live `LocalModelFileEntity` so callers can write multiple fields
    /// in one save. Inserts a new entity if none exists yet.
    public static func updateConfig(
        for url: URL,
        mutating mutation: (LocalModelFileEntity) -> Void
    ) {
        let context = ModelContext(PersistenceController.shared.container)
        let urlString = url.absoluteString
        do {
            let entity: LocalModelFileEntity
            if let existing = try context.fetch(
                FetchDescriptor<LocalModelFileEntity>(
                    predicate: #Predicate { $0.urlString == urlString }
                )
            ).first {
                entity = existing
            } else {
                entity = LocalModelFileEntity(
                    id: UUID(),
                    urlString: urlString
                )
                context.insert(entity)
            }
            mutation(entity)
            try context.save()
        } catch {
            Self.logger.error(
                "Failed to update model config: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Legacy `models.json` location, kept for one-shot migration.
    public static var legacyDatastoreUrl: URL {
        return Settings.containerUrl
            .appendingPathComponent("Models")
            .appendingPathComponent("models.json")
    }

    /// Value-type representation of a single local model file. Kept
    /// at this namespace so existing call sites (`ModelManager.ModelFile`)
    /// keep working.
    public struct ModelFile: Identifiable, Equatable, Codable {

        public var id: UUID = UUID()
        public let url: URL

        public var name: String {
            return url.deletingPathExtension().lastPathComponent
        }

        public init(url: URL) {
            self.url = url
        }

        public init(id: UUID, url: URL) {
            self.id = id
            self.url = url
        }
    }
}

/// Type-erased view of ``LocalModelFileEntity`` rows used by
/// `@Query`-driven views. Existing call sites continue to consume
/// ``ModelManager/ModelFile``; this extension just converts.
extension LocalModelFileEntity {
    /// Hydrate a value-type ``ModelManager/ModelFile`` from the row.
    public var modelFile: ModelManager.ModelFile? {
        guard let url = URL(string: urlString) else { return nil }
        return ModelManager.ModelFile(id: id, url: url)
    }
}

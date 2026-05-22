//
//  ExpertManager.swift
//  Sidekick
//
//  Created by Bean John on 10/6/24.
//
//  Replaced in Phase 3 of the SwiftData migration. The legacy
//  ``ExpertManager`` `ObservableObject` is gone; experts live in
//  ``ExpertEntity`` (+ ``ResourcesSetEntity`` / ``ResourceItemEntity``)
//  rows and SwiftUI views read them via `@Query`. The static
//  helpers below provide the small slice of API that non-view call
//  sites still need (defaults seeding, lookups, fall-back JSON
//  hydration, etc.).
//

import Foundation
import OSLog
import SwiftData
import SwiftUI

@MainActor
public enum ExpertManager {

    private static let logger: Logger = .init(
        subsystem: Bundle.main.bundleIdentifier!,
        category: "ExpertManager"
    )

    // MARK: - Read API

    /// Every expert in the store, in insertion order. Lazily seeds
    /// the defaults if empty.
    public static func experts() -> [Expert] {
        let context = ModelContext(PersistenceController.shared.container)
        do {
            let rows = try context.fetch(FetchDescriptor<ExpertEntity>())
            if !rows.isEmpty {
                return rows.map(Self.expert(from:))
            }
        } catch {
            Self.logger.error(
                "Failed to read experts: \(error.localizedDescription, privacy: .public)"
            )
        }
        // Fallback: legacy JSON → seed → return.
        if let rawData = try? Data(contentsOf: legacyDatastoreUrl),
           let legacy = try? JSONDecoder().decode([Expert].self, from: rawData) {
            replace(with: legacy)
            return legacy
        }
        replace(with: defaultExperts)
        return defaultExperts
    }

    /// The "Default" expert, lazily inserted if missing.
    public static var `default`: Expert? {
        let all = experts()
        if let match = all.first(where: { $0.name == String(localized: "Default") }) {
            return match
        }
        let seeded = [Expert.default] + all
        replace(with: seeded)
        return seeded.first
    }

    /// Returns the expert identified by `id`, if any.
    public static func getExpert(id: UUID) -> Expert? {
        let targetId = id
        let context = ModelContext(PersistenceController.shared.container)
        do {
            let descriptor = FetchDescriptor<ExpertEntity>(
                predicate: #Predicate { $0.id == targetId }
            )
            if let row = try context.fetch(descriptor).first {
                return Self.expert(from: row)
            }
        } catch {
            Self.logger.error(
                "Failed to fetch expert: \(error.localizedDescription, privacy: .public)"
            )
        }
        return nil
    }

    /// Returns the position of `expert` in the persisted list. Used
    /// by the navigation sidebar's keyboard shortcuts.
    public static func getExpertIndex(expert targetExpert: Expert) -> Int {
        for (index, expert) in experts().enumerated() {
            if expert == targetExpert {
                return index
            }
        }
        return 0
    }

    // MARK: - Write API

    /// Wholesale replace the persisted expert list. Used by the
    /// JSON-fallback path and by the “reset to defaults” action.
    public static func replace(with experts: [Expert]) {
        let context = ModelContext(PersistenceController.shared.container)
        do {
            let existingExperts = try context.fetch(FetchDescriptor<ExpertEntity>())
            for entity in existingExperts {
                context.delete(entity)
            }
            // Drop any orphaned children; the cascade should handle
            // these but we wipe explicitly to be safe.
            let existingResources = try context.fetch(FetchDescriptor<ResourceItemEntity>())
            for entity in existingResources { context.delete(entity) }
            let existingSets = try context.fetch(FetchDescriptor<ResourcesSetEntity>())
            for entity in existingSets { context.delete(entity) }

            for expert in experts {
                context.insert(Self.entity(from: expert))
            }
            try context.save()
        } catch {
            Self.logger.error(
                "Failed to save experts: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Append a new expert.
    public static func add(_ expert: Expert) {
        var current = experts()
        current.append(expert)
        replace(with: current)
    }

    /// Delete an expert by id.
    public static func delete(id: UUID) {
        let current = experts().filter { $0.id != id }
        replace(with: current)
    }

    /// Update an existing expert.
    public static func update(_ expert: Expert) {
        var current = experts()
        for index in current.indices {
            if current[index].id == expert.id {
                current[index] = expert
                replace(with: current)
                return
            }
        }
        // Wasn't found; insert as new to be safe.
        add(expert)
    }

    /// Create a fresh expert with the given identity and resources.
    public static func newExpert(
        name: String,
        symbolName: String,
        color: Color,
        resources: [Resource]
    ) async {
        var expert: Expert = Expert(
            name: name,
            symbolName: symbolName,
            color: color
        )
        await expert.resources.setup()
        await MainActor.run {
            expert.resources.addResources(resources)
        }
        Self.add(expert)
    }

    /// Append resources to the expert identified by `expertId`.
    public static func addResources(expertId: UUID, resources: [Resource]) async {
        guard var existing = getExpert(id: expertId) else { return }
        await MainActor.run {
            existing.resources.addResources(resources)
        }
        update(existing)
    }

    /// Restore the default expert set.
    public static func resetToDefaults() {
        replace(with: defaultExperts)
    }

    /// Remove resources for experts that do not persist them. Called
    /// on app termination.
    public static func removeUnpersistedResources() {
        var current = experts()
        for index in current.indices {
            if !current[index].persistResources {
                let dirUrl: URL = current[index].resources.indexUrl
                current[index].resources.resources.forEach { resource in
                    resource.deleteDirectory(resourcesDirUrl: dirUrl)
                }
                current[index].resources.resources.removeAll()
                Self.logger.notice(
                    "Removed resources for expert \(current[index].name, privacy: .public)."
                )
            }
        }
        replace(with: current)
    }

    /// Legacy JSON datastore URL (kept for first-launch migration).
    public static var legacyDatastoreUrl: URL {
        return Settings.containerUrl
            .appendingPathComponent("Profiles")
            .appendingPathComponent("profiles.json")
    }

    /// Static constant for default experts
    public static var defaultExperts: [Expert] {
        return [
            Expert.default
        ]
    }
}

// MARK: - Struct <-> Entity mapping

extension ExpertManager {

    /// Convert a persisted ``ExpertEntity`` row into the value-type
    /// ``Expert`` consumed throughout the app.
    public static func expert(from entity: ExpertEntity) -> Expert {
        var resources = Resources()
        if let set = entity.resourcesSet {
            resources = self.resources(from: set)
        }
        return Expert(
            id: entity.id,
            name: entity.name,
            symbolName: entity.symbolName,
            color: Color(hex: entity.colorHex),
            useWebSearch: entity.useWebSearch,
            resources: resources,
            systemPrompt: entity.systemPrompt,
            persistResources: entity.persistResources
        )
    }

    fileprivate static func entity(from expert: Expert) -> ExpertEntity {
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
            statusRaw: expert.resources.status.map(resourcesStatusRawValue),
            useGraphRAG: expert.resources.useGraphRAG,
            graphStatusRaw: expert.resources.graphStatus.map(resourcesGraphStatusRawValue),
            graphProgressData: expert.resources.graphProgress.flatMap { try? encoder.encode($0) }
        )
        entity.resourcesSet = resourcesSet
        for resource in expert.resources.resources {
            let item = resourceEntity(from: resource)
            item.resourcesSet = resourcesSet
            resourcesSet.items.append(item)
        }
        return entity
    }

    fileprivate static func resourceEntity(from resource: Resource) -> ResourceItemEntity {
        let entity = ResourceItemEntity(
            id: resource.id,
            urlString: resource.url.absoluteString,
            prevIndexDate: resource.prevIndexDate,
            indexStateRaw: resourceIndexStateRawValue(resource.indexState)
        )
        for child in resource.children {
            let childEntity = resourceEntity(from: child)
            childEntity.parent = entity
            entity.children.append(childEntity)
        }
        return entity
    }

    fileprivate static func resources(from entity: ResourcesSetEntity) -> Resources {
        let decoder = JSONDecoder()
        var resources = Resources()
        resources.id = entity.id
        if let raw = entity.statusRaw {
            resources.status = resourcesStatus(fromRawValue: raw)
        }
        resources.useGraphRAG = entity.useGraphRAG
        if let raw = entity.graphStatusRaw {
            resources.graphStatus = resourcesGraphStatus(fromRawValue: raw)
        }
        if let data = entity.graphProgressData,
           let progress = try? decoder.decode(Resources.GraphProgress.self, from: data) {
            resources.graphProgress = progress
        }
        let topLevel = entity.items.filter { $0.parent == nil }
        resources.resources = topLevel.map(resource(from:))
        return resources
    }

    fileprivate static func resource(from entity: ResourceItemEntity) -> Resource {
        var resource = Resource(
            url: URL(string: entity.urlString) ?? URL(fileURLWithPath: entity.urlString)
        )
        resource.id = entity.id
        resource.prevIndexDate = entity.prevIndexDate
        resource.indexState = resourceIndexState(fromRawValue: entity.indexStateRaw)
        resource.children = entity.children.map(resource(from:))
        return resource
    }

    fileprivate static func resourcesStatusRawValue(_ status: Resources.Status) -> String {
        switch status {
        case .indexing: return "indexing"
        case .ready: return "ready"
        }
    }

    fileprivate static func resourcesStatus(fromRawValue raw: String) -> Resources.Status? {
        switch raw {
        case "indexing": return .indexing
        case "ready": return .ready
        default: return nil
        }
    }

    fileprivate static func resourcesGraphStatusRawValue(_ status: Resources.GraphStatus) -> String {
        switch status {
        case .building: return "building"
        case .ready: return "ready"
        case .error: return "error"
        }
    }

    fileprivate static func resourcesGraphStatus(fromRawValue raw: String) -> Resources.GraphStatus? {
        switch raw {
        case "building": return .building
        case "ready": return .ready
        case "error": return .error
        default: return nil
        }
    }

    fileprivate static func resourceIndexStateRawValue(_ state: Resource.IndexState) -> String {
        switch state {
        case .noIndex: return "noIndex"
        case .indexing: return "indexing"
        case .indexed: return "indexed"
        }
    }

    fileprivate static func resourceIndexState(fromRawValue raw: String) -> Resource.IndexState {
        switch raw {
        case "indexing": return .indexing
        case "indexed": return .indexed
        default: return .noIndex
        }
    }
}

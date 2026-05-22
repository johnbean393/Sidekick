//
//  PersistenceController.swift
//  Sidekick
//
//  Owns the SwiftData `ModelContainer` used by the whole app.
//  Created as part of the JSON → SwiftData migration.
//

import Foundation
import OSLog
import SwiftData

/// Singleton owner of the app's SwiftData stack.
///
/// The container is built lazily on first access using
/// ``SidekickSchemaV1`` and stored at
/// `Settings.containerUrl/SidekickStore/SidekickStore.sqlite`.
/// It is intentionally non-CloudKit; if a user wants their data
/// synced across devices, that's a future schema version concern.
public final class PersistenceController {

    private static let logger: Logger = .init(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: PersistenceController.self)
    )

    /// Shared singleton used by the running app.
    public static let shared: PersistenceController = .init()

    /// The active `ModelContainer`. Crashes on construction failure
    /// — Sidekick cannot meaningfully run without persistence.
    public let container: ModelContainer

    private init() {
        let storeUrl = PersistenceController.storeUrl
        let parent = storeUrl.deletingLastPathComponent()
        if !parent.fileExists {
            try? FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true
            )
        }
        let configuration = ModelConfiguration(
            schema: Schema(versionedSchema: SidekickSchemaV1.self),
            url: storeUrl,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        do {
            self.container = try ModelContainer(
                for: Schema(versionedSchema: SidekickSchemaV1.self),
                migrationPlan: SidekickSchemaMigrationPlan.self,
                configurations: configuration
            )
            Self.logger.info("Loaded SwiftData store at \(storeUrl.path(), privacy: .public)")
        } catch {
            Self.logger.error(
                "Failed to load SwiftData store at \(storeUrl.path(), privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            // Last-ditch fallback: build an in-memory store so the
            // app at least launches; the user will see an alert via
            // ``Refactorer``.
            let fallback = ModelConfiguration(
                schema: Schema(versionedSchema: SidekickSchemaV1.self),
                isStoredInMemoryOnly: true
            )
            // swiftlint:disable:next force_try
            self.container = try! ModelContainer(
                for: Schema(versionedSchema: SidekickSchemaV1.self),
                configurations: fallback
            )
        }
    }

    /// In-memory `ModelContainer` used by tests and SwiftUI previews.
    public static func inMemoryContainer() -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: Schema(versionedSchema: SidekickSchemaV1.self),
            isStoredInMemoryOnly: true
        )
        // swiftlint:disable:next force_try
        return try! ModelContainer(
            for: Schema(versionedSchema: SidekickSchemaV1.self),
            configurations: configuration
        )
    }

    /// Location of the SQLite-backed SwiftData store.
    public static var storeUrl: URL {
        Settings.containerUrl
            .appendingPathComponent("SidekickStore", isDirectory: true)
            .appendingPathComponent("SidekickStore.sqlite")
    }
}

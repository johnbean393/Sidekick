//
//  SourcesManager.swift
//  Sidekick
//
//  Created by Bean John on 10/20/24.
//
//  Migrated to SwiftData on 5/23/26 and refactored to a static
//  namespace on the same date. The legacy ``SourcesManager``
//  `ObservableObject` singleton has been retired; storage lives in
//  ``SourceEntity`` rows attached to their parent
//  ``MessageEntity``. Views can either use `@Query<SourceEntity>`
//  directly or call ``SourcesStore`` helpers below. The legacy
//  type alias is kept so external snapshots (JSON exports) keep
//  decoding cleanly.
//

import Foundation
import os.log
import SwiftData
import SwiftUI

/// Static namespace replacing the old `SourcesManager` singleton.
///
/// Provides CRUD helpers that operate directly on
/// ``SourceEntity`` rows and a small set of legacy JSON-import
/// affordances used during the SwiftData migration.
@MainActor
public enum SourcesStore {

    /// Logger for the store.
    private static let logger: Logger = .init(
        subsystem: Bundle.main.bundleIdentifier!,
        category: "SourcesStore"
    )

    // MARK: - Reads

    /// Returns the persisted ``Sources`` bundle for the given
    /// `messageId`, if any.
    public static func getSources(id messageId: UUID) -> Sources? {
        let context = ModelContext(PersistenceController.shared.container)
        do {
            let descriptor = FetchDescriptor<SourceEntity>(
                predicate: #Predicate { entity in
                    entity.message?.id == messageId
                }
            )
            let rows = try context.fetch(descriptor)
            guard !rows.isEmpty else { return nil }
            return Sources(
                messageId: messageId,
                sources: rows.map { row in
                    Source(id: row.id, text: row.text, source: row.source)
                }
            )
        } catch {
            Self.logger.error(
                "Failed to fetch sources: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// Returns every persisted ``Sources`` bundle, grouped by
    /// `messageId`. Useful for export / debug surfaces.
    public static func allSources() -> [Sources] {
        let context = ModelContext(PersistenceController.shared.container)
        do {
            let rows = try context.fetch(FetchDescriptor<SourceEntity>())
            var bucket: [UUID: [Source]] = [:]
            for row in rows {
                guard let messageId = row.message?.id else { continue }
                bucket[messageId, default: []].append(
                    Source(id: row.id, text: row.text, source: row.source)
                )
            }
            return bucket.map { messageId, items in
                Sources(messageId: messageId, sources: items)
            }
        } catch {
            Self.logger.error(
                "Failed to fetch sources: \(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }

    // MARK: - Writes

    /// Persist a ``Sources`` bundle, attaching every contained
    /// ``Source`` to its parent ``MessageEntity``. No-op if the
    /// parent message has been deleted in the meantime.
    public static func add(_ sources: Sources) {
        let context = ModelContext(PersistenceController.shared.container)
        do {
            let messageId = sources.messageId
            let messages = try context.fetch(
                FetchDescriptor<MessageEntity>(
                    predicate: #Predicate { $0.id == messageId }
                )
            )
            guard let parent = messages.first else { return }
            for source in sources.sources {
                let entity = SourceEntity(
                    id: source.id,
                    text: source.text,
                    source: source.source
                )
                entity.message = parent
                context.insert(entity)
            }
            try context.save()
        } catch {
            Self.logger.error(
                "Failed to add sources: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Remove a ``Sources`` bundle by `messageId`.
    public static func delete(messageId: UUID) {
        let context = ModelContext(PersistenceController.shared.container)
        do {
            let descriptor = FetchDescriptor<SourceEntity>(
                predicate: #Predicate { entity in
                    entity.message?.id == messageId
                }
            )
            let rows = try context.fetch(descriptor)
            for row in rows {
                context.delete(row)
            }
            try context.save()
        } catch {
            Self.logger.error(
                "Failed to delete sources: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Maintenance

    /// Remove sources whose parent message no longer exists.
    /// Largely a no-op once SwiftData's cascade rule runs, but
    /// kept for the existing ``AppDelegate`` lifecycle hook.
    public static func removeStaleSources() {
        let context = ModelContext(PersistenceController.shared.container)
        do {
            let rows = try context.fetch(FetchDescriptor<SourceEntity>())
            var didDelete = false
            for row in rows where row.message == nil {
                context.delete(row)
                didDelete = true
            }
            if didDelete {
                try context.save()
            }
        } catch {
            Self.logger.error(
                "Failed to prune stale sources: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Reset every persisted source after user confirmation.
    public static func resetDatastore() {
        let _ = Dialogs.showConfirmation(
            title: String(localized: "Delete All Sources"),
            message: String(localized: "Are you sure you want to delete all sources?")
        ) {
            Self.deleteAll()
        }
    }

    private static func deleteAll() {
        let context = ModelContext(PersistenceController.shared.container)
        do {
            let rows = try context.fetch(FetchDescriptor<SourceEntity>())
            for row in rows {
                context.delete(row)
            }
            try context.save()
        } catch {
            Self.logger.error(
                "Failed to delete all sources: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Legacy JSON locations (preserved for migration)

    /// Legacy datastore directory used by the one-time JSON import.
    public static var datastoreDirUrl: URL {
        return Settings.containerUrl.appendingPathComponent("Sources")
    }

    /// Legacy datastore url used by the one-time JSON import.
    public static var datastoreUrl: URL {
        return Self.datastoreDirUrl.appendingPathComponent("sources.json")
    }
}

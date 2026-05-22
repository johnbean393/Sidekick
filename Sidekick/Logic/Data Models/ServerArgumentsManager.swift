//
//  ServerArgumentsManager.swift
//  Sidekick
//
//  Created by John Bean on 4/29/25.
//
//  Replaced in Phase 2 of the SwiftData migration. The legacy
//  ``ServerArgumentsManager`` `ObservableObject` is gone; all
//  storage lives in ``ServerArgumentEntity`` rows and views read
//  them via SwiftData's `@Query`. The static helpers below provide
//  the small slice of API that non-View call sites (the llama.cpp
//  server lifecycle) still need.
//

import Foundation
import OSLog
import SwiftData
import SwiftUI

@MainActor
public enum ServerArgumentsStore {

    private static let logger: Logger = .init(
        subsystem: Bundle.main.bundleIdentifier!,
        category: "ServerArgumentsStore"
    )

    /// Returns the persisted arguments, in sort order. Lazily seeds
    /// the store with the defaults on first read.
    public static func arguments() -> [ServerArgument] {
        let context = ModelContext(PersistenceController.shared.container)
        do {
            var descriptor = FetchDescriptor<ServerArgumentEntity>(
                sortBy: [SortDescriptor(\.sortIndex)]
            )
            descriptor.fetchLimit = 1024
            let rows = try context.fetch(descriptor)
            if rows.isEmpty {
                replace(with: ServerArgument.defaultServerArguments)
                return ServerArgument.defaultServerArguments
            }
            return rows.map {
                ServerArgument(
                    id: $0.id,
                    isActive: $0.isActive,
                    flag: $0.flag,
                    value: $0.value
                )
            }
        } catch {
            Self.logger.error(
                "Failed to read server arguments: \(error.localizedDescription, privacy: .public)"
            )
            return ServerArgument.defaultServerArguments
        }
    }

    /// Arguments that have a non-empty flag and are marked active.
    public static func activeArguments() -> [ServerArgument] {
        return arguments()
            .filter(\.isActive)
            .filter { !$0.flag.isEmpty }
    }

    /// Flattened argv slice produced by all active arguments.
    public static func allArguments() -> [String] {
        return activeArguments().flatMap(\.arguments)
    }

    /// Wholesale replace the persisted argument list.
    public static func replace(with arguments: [ServerArgument]) {
        let context = ModelContext(PersistenceController.shared.container)
        do {
            let existing = try context.fetch(FetchDescriptor<ServerArgumentEntity>())
            for row in existing {
                context.delete(row)
            }
            for (index, argument) in arguments.enumerated() {
                context.insert(
                    ServerArgumentEntity(
                        id: argument.id,
                        isActive: argument.isActive,
                        flag: argument.flag,
                        value: argument.value,
                        sortIndex: index
                    )
                )
            }
            try context.save()
        } catch {
            Self.logger.error(
                "Failed to save server arguments: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Append a new argument row.
    public static func add(_ argument: ServerArgument) {
        let context = ModelContext(PersistenceController.shared.container)
        do {
            var descriptor = FetchDescriptor<ServerArgumentEntity>(
                sortBy: [SortDescriptor(\.sortIndex)]
            )
            descriptor.fetchLimit = 1024
            let existing = try context.fetch(descriptor)
            let nextIndex = (existing.last?.sortIndex ?? -1) + 1
            context.insert(
                ServerArgumentEntity(
                    id: argument.id,
                    isActive: argument.isActive,
                    flag: argument.flag,
                    value: argument.value,
                    sortIndex: nextIndex
                )
            )
            try context.save()
        } catch {
            Self.logger.error(
                "Failed to add server argument: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Delete a single argument by id.
    public static func delete(id: UUID) {
        let context = ModelContext(PersistenceController.shared.container)
        do {
            let descriptor = FetchDescriptor<ServerArgumentEntity>(
                predicate: #Predicate { $0.id == id }
            )
            if let row = try context.fetch(descriptor).first {
                context.delete(row)
                try context.save()
            }
        } catch {
            Self.logger.error(
                "Failed to delete server argument: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Update an existing argument row's mutable fields.
    public static func update(_ argument: ServerArgument) {
        let id = argument.id
        let context = ModelContext(PersistenceController.shared.container)
        do {
            let descriptor = FetchDescriptor<ServerArgumentEntity>(
                predicate: #Predicate { $0.id == id }
            )
            if let row = try context.fetch(descriptor).first {
                row.isActive = argument.isActive
                row.flag = argument.flag
                row.value = argument.value
                try context.save()
            }
        } catch {
            Self.logger.error(
                "Failed to update server argument: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Restore the default argument set.
    public static func resetToDefaults() {
        replace(with: ServerArgument.defaultServerArguments)
    }
}

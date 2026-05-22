//
//  CommandManager.swift
//  Sidekick
//
//  Created by Bean John on 11/18/24.
//
//  Replaced in Phase 2 of the SwiftData migration. The legacy
//  ``CommandManager`` `ObservableObject` is gone; commands live in
//  ``CommandEntity`` rows and views read them via SwiftData's
//  `@Query`. The static helpers below provide the small slice of
//  API that non-view call sites still need.
//

import Foundation
import OSLog
import SwiftData
import SwiftUI

@MainActor
public enum CommandManager {

    private static let logger: Logger = .init(
        subsystem: Bundle.main.bundleIdentifier!,
        category: "CommandManager"
    )

    /// Returns every command, alphabetised, lazily seeding the
    /// store with the defaults if needed.
    public static func commands() -> [Command] {
        let context = ModelContext(PersistenceController.shared.container)
        do {
            let rows = try context.fetch(FetchDescriptor<CommandEntity>())
            if rows.isEmpty {
                replace(with: Command.defaults)
                return Command.defaults.sorted(by: \.name)
            }
            return rows
                .map { Command(id: $0.id, name: $0.name, prompt: $0.prompt) }
                .sorted(by: { $0.name < $1.name })
        } catch {
            Self.logger.error(
                "Failed to read commands: \(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }

    /// Wholesale replace the persisted command list.
    public static func replace(with commands: [Command]) {
        let context = ModelContext(PersistenceController.shared.container)
        do {
            let existing = try context.fetch(FetchDescriptor<CommandEntity>())
            for row in existing {
                context.delete(row)
            }
            for command in commands {
                context.insert(
                    CommandEntity(
                        id: command.id,
                        name: command.name,
                        prompt: command.prompt
                    )
                )
            }
            try context.save()
        } catch {
            Self.logger.error(
                "Failed to save commands: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Returns the command identified by `id`, if any.
    public static func getCommand(id: UUID) -> Command? {
        let context = ModelContext(PersistenceController.shared.container)
        do {
            let descriptor = FetchDescriptor<CommandEntity>(
                predicate: #Predicate { $0.id == id }
            )
            if let row = try context.fetch(descriptor).first {
                return Command(id: row.id, name: row.name, prompt: row.prompt)
            }
        } catch {
            Self.logger.error(
                "Failed to fetch command: \(error.localizedDescription, privacy: .public)"
            )
        }
        return nil
    }

    /// Insert a new command row.
    public static func add(_ command: Command) {
        let context = ModelContext(PersistenceController.shared.container)
        context.insert(
            CommandEntity(
                id: command.id,
                name: command.name,
                prompt: command.prompt
            )
        )
        try? context.save()
    }

    /// Delete a command by id.
    public static func delete(id: UUID) {
        let context = ModelContext(PersistenceController.shared.container)
        do {
            let descriptor = FetchDescriptor<CommandEntity>(
                predicate: #Predicate { $0.id == id }
            )
            if let row = try context.fetch(descriptor).first {
                context.delete(row)
                try context.save()
            }
        } catch {
            Self.logger.error(
                "Failed to delete command: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Update the mutable fields of a command row.
    public static func update(_ command: Command) {
        let id = command.id
        let context = ModelContext(PersistenceController.shared.container)
        do {
            let descriptor = FetchDescriptor<CommandEntity>(
                predicate: #Predicate { $0.id == id }
            )
            if let row = try context.fetch(descriptor).first {
                row.name = command.name
                row.prompt = command.prompt
                try context.save()
            }
        } catch {
            Self.logger.error(
                "Failed to update command: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Restore the default command set.
    public static func resetToDefaults() {
        replace(with: Command.defaults)
    }

    /// First command after a fresh seed (used by the inline
    /// assistant's initial selection).
    public static var firstCommand: Command? {
        return commands().first
    }

    /// Last command after a fresh seed.
    public static var lastCommand: Command? {
        return commands().last
    }
}

extension CommandEntity {
    /// Hydrate a value-type ``Command`` from a SwiftData row.
    public var command: Command {
        Command(id: id, name: name, prompt: prompt)
    }
}

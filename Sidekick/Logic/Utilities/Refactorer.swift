//
//  Refactorer.swift
//  Sidekick
//
//  Created by John Bean on 2/23/25.
//

import AppKit
import Foundation
import FSKit_macOS
import OSLog
import SwiftData

public class Refactorer {
    
    /// A `Logger` object for the ``Refactorer`` object
    private static let logger: Logger = .init(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: Refactorer.self)
    )
    
    private static let migrationDefaultsKey: String = "Refactorer.migrationVersion"
    /// Latest schema-migration version. Bumped to `2` for the
    /// JSON → SwiftData migration. Once a user is on v2, the
    /// JSON files are still archived (not deleted) for rollback
    /// safety.
    private static let currentMigrationVersion: Int = 2
    
    /// Function
    @MainActor
    static func refactor() {
        let defaults = UserDefaults.standard
        let storedVersion = defaults.integer(forKey: Self.migrationDefaultsKey)
        if storedVersion >= Self.currentMigrationVersion {
            Self.logger.debug("Skipping refactor; migration already completed.")
            return
        }
        // Filesystem relocations (idempotent — they no-op once the
        // destination already exists).
        var didRefactor: [Bool] = []
        didRefactor.append(Self.relocateOutOfSandbox())
        didRefactor.append(Self.relocateIntoContainer())

        // One-time JSON → SwiftData import. Each manager is also
        // wired to do a lazy fall-back import on first read, so this
        // serves primarily as a belt-and-braces step that archives
        // the legacy JSON files after a clean transition.
        let didImportFromJSON: Bool = Self.runSwiftDataImport()

        // Persist the bumped migration version regardless of whether
        // we actually moved files; otherwise we'd keep re-running
        // on every launch.
        defaults.set(Self.currentMigrationVersion, forKey: Self.migrationDefaultsKey)

        if didRefactor.contains(true) || didImportFromJSON {
            Dialogs.showAlert(
                title: String(localized: "Restart Sidekick"),
                message: String(localized: "To properly load your content, please restart Sidekick.")
            )
            NSApplication.shared.terminate(nil)
        }
    }

    /// Runs the JSON → SwiftData importer the first time the user
    /// is upgraded to migration version 2. Returns `true` if any
    /// legacy JSON file was detected and successfully imported.
    @MainActor
    private static func runSwiftDataImport() -> Bool {
        let hadLegacyData = JSONImporter.legacyJSONExists
        guard hadLegacyData else { return false }
        do {
            try JSONImporter.importAll(into: PersistenceController.shared.container)
            JSONImporter.archiveLegacyJSON()
            return true
        } catch {
            Self.logger.error("JSON → SwiftData import failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
    
    /// Function to move folders out of the app's sandbox
    @MainActor
    static func relocateOutOfSandbox() -> Bool {
        let legacyResources: URL = URL
            .libraryDirectory
            .appendingPathComponent("Containers")
            .appendingPathComponent("com.pattonium.Sidekick")
            .appendingPathComponent("Data")
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
        if let contents = legacyResources.contents,
           legacyResources.appendingPathComponent(
            "Conversations"
           ).fileExists {
            // Move all contents
            for content in contents {
                // Skip CrashReporter and symlinks
                if content.lastPathComponent == "" || !content.hasDirectoryPath {
                    continue
                }
                // Move content
                let newLocation: URL = URL
                    .applicationSupportDirectory
                    .appendingPathComponent(content.lastPathComponent)
                if newLocation.fileExists {
                    FileManager.removeItem(at: newLocation)
                }
                FileManager.moveItem(from: content, to: newLocation)
            }
            // Move settings
            let settingsLocation: URL = URL
                .libraryDirectory
                .appendingPathComponent("Containers")
                .appendingPathComponent("com.pattonium.Sidekick")
                .appendingPathComponent("Data")
                .appendingPathComponent("Library")
                .appendingPathComponent("Preferences")
                .appendingPathComponent("com.pattonium.Sidekick.plist")
            let newSettingsLocation: URL = URL
                .libraryDirectory
                .appendingPathComponent("Preferences")
                .appendingPathComponent("com.pattonium.Sidekick.plist")
            FileManager.moveItem(
                from: settingsLocation,
                to: newSettingsLocation
            )
            return true
        }
        return false
    }
    
    /// Function to relocate into new container within application support
    @MainActor
    static func relocateIntoContainer() -> Bool {
        // Create container directory
        FileManager.createDirectory(
            at: Settings.containerUrl,
            withIntermediateDirectories: true
        )
        // List directory names
        let directoryNames: [String] = [
            "Cache",
            "Commands",
            "Conversations",
            "Models",
            "Profiles",
            "Sources",
            "Generated Images",
            "Resources"
        ]
        // Move directories
        var didRelocate: Bool = false
        for directoryName in directoryNames {
            let sourceURL: URL = URL
                .applicationSupportDirectory
                .appendingPathComponent(directoryName)
            let destinationURL: URL = Settings
                .containerUrl
                .appendingPathComponent(directoryName)
            // Continue if destination URL exists
            if destinationURL.fileExists { continue }
            // If directory exists at source, move
            if sourceURL.fileExists {
                // Set didRelocate to true
                didRelocate = true
                FileManager.moveItem(
                    from: sourceURL,
                    to: destinationURL,
                    replacing: true
                )
            } else {
                // Else, create the directory
                FileManager.createDirectory(
                    at: destinationURL,
                    withIntermediateDirectories: true
                )
            }
        }
        // Return if relocated
        return didRelocate
    }
    
    /// Function to update endpoint
    @MainActor
    static func updateEndpoint() async {
        // Update endpoint url format if needed
        if InferenceSettings.endpointFormatVersion <= 0,
           !InferenceSettings.endpoint.isEmpty {
            // Create new endpoint
            let newEndpoint: String = InferenceSettings.endpoint + "/v1"
            // Test new endpoint
            if await Model.shared.remoteServerIsReachable(
                endpoint: newEndpoint
            ) {
                // If it works, set it
                InferenceSettings.endpoint = newEndpoint
                Self.logger.info(
                    "Updated endpoint to \(newEndpoint)"
                )
            } else {
                // Else, log and show error
                Self.logger.error(
                    "Failed to update endpoint to \(newEndpoint)"
                )
                Dialogs.showAlert(
                    title: String(localized: "Endpoint Error"),
                    message: String(
                        localized: """
Sidekick has adopted OpenAI's API endpoint format. Please navigate to `Settings` -> `Inference` and update your endpoint to end with `/v1`.
"""
                    )
                )
            }
            // Update version
            InferenceSettings.endpointFormatVersion = 1
        }
    }
    
}

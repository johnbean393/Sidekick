//
//  AppDelegate.swift
//  Sidekick
//
//  Created by Bean John on 10/5/24.
//

import AppKit
import Foundation
import FSKit_macOS
import OSLog
import SwiftUI
import TipKit

/// The app's delegate which handles life cycle events
public class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    
    /// A object of type  ``InlineAssistantController`` controller
    let inlineAssistantController: InlineAssistantController = .shared
    /// A object of type  ``CompletionsController`` controller
    let completionsController: CompletionsController = .shared
    
    /// Function that runs after the app is initialized
    public func applicationDidFinishLaunching(
        _ notification: Notification
    ) {
        Tips.hideAllTipsForTesting()
        print("Hid all tips")
        // Relocate legacy resources if setup finished
        if Settings.setupComplete {
            let signpost = StartupMetrics.begin("Refactorer.refactor")
            Refactorer.refactor()
            StartupMetrics.end("Refactorer.refactor", signpost)
        }
        // Configure Tip's data container
        try? Tips.configure(
            [
                .datastoreLocation(.applicationDefault),
                .displayFrequency(.daily)
            ]
        )
        // Configure keyboard shortcuts
        ShortcutController.setup()
        // Update endpoint format
        Task { @MainActor in
            await Refactorer.updateEndpoint()
        }
        // Make sure `Resources` are not indexing
        for expert in ExpertManager.experts() {
            var modExpert = expert
            if modExpert.resources.graphStatus != .ready {
                modExpert.resources.graphStatus = nil
                modExpert.resources.graphProgress = nil
            }
            ExpertManager.update(modExpert)
        }
    }
    
    /// Function that runs before the app is terminated
    public func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        // Stop server
        Task {
            await Model.shared.stopServers()
        }
        // Remove stale sources
        SourcesStore.removeStaleSources()
        // Remove non-persisted resources
        ExpertManager.removeUnpersistedResources()
        return .terminateNow
    }
    
}

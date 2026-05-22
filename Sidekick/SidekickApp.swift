//
//  SidekickApp.swift
//  Sidekick
//
//  Created by Bean John on 10/4/24.
//

import AppKit
import Foundation
import FSKit_macOS
import Sparkle
import SwiftData
import SwiftUI
import TipKit

@main
struct SidekickApp: App {
    
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    @State private var appState: AppState = .shared
    @State private var downloadManager: DownloadManager = .shared
    @State private var conversationManager: ConversationManager = .shared
    @State private var memories: MemoryIndex = .shared

    @State private var lengthyTasksController: LengthyTasksController = .shared
    
    /// Shared SwiftData container owning every persisted entity in
    /// ``SidekickSchemaV1``. Injected into every scene via
    /// `.modelContainer(...)`.
    private let persistenceContainer: ModelContainer = PersistenceController.shared.container
    
    /// Updater object for Sparkle
    private let updaterController: SPUStandardUpdaterController = .init(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    
    init() {
        // Hide all tips for now
        Tips.hideAllTipsForTesting()
        // Initialize model cache
        Task {
            let signpost = StartupMetrics.begin("KnownModel.initializeModelCache")
            await KnownModel.initializeModelCache()
            StartupMetrics.end("KnownModel.initializeModelCache", signpost)
        }
    }
    
    var body: some Scene {
        
        // Main window
        WindowGroup {
            ContentView()
                .environment(appState)
                .environment(downloadManager)
                .environment(conversationManager)
                .environment(lengthyTasksController)
                .environment(memories)
                .applyWindowMaterial()
        }
        .modelContainer(persistenceContainer)
        .windowToolbarStyle(.unified)
        .commands {
            // Commands for operations in conversations (e.g. Creating a new conversation)
            ConversationCommands.commands
            // Commands to use and manage experts
            ConversationCommands.expertCommands
            // Commands to change the window state / appearance
            WindowCommands.commands
            // Command replacing the help button
            HelpCommands.helpCommand
            // Commands useful for debugging
            DebugCommands.commands
            // Commands to obtain help and report problems
            HelpCommands.commands
            // Command to check for update
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
        }
        
        // Window for managing memories
        SwiftUI.Window("Memory", id: "memory") {
            MemoriesManagerView()
                .environment(memories)
                .frame(minWidth: 500, maxWidth: 600, maxHeight: 550)
        }
        .modelContainer(persistenceContainer)
        .windowResizability(.contentSize)
        .windowIdealSize(.fitToContent)
        
        // Window for Tool: Models
        SwiftUI.Window("Models", id: "models") {
            ModelExplorerView()
        }
        .modelContainer(persistenceContainer)
        
        // Window for Tool: Dashboard
        SwiftUI.Window("Dashboard", id: "dashboard") {
            DashboardView()
        }
        .modelContainer(persistenceContainer)
        
        // Window for Tool: Detector
        SwiftUI.Window("Detector", id: "detector") {
            DetectorView()
        }
        .modelContainer(persistenceContainer)
        
        // Window for Tool: Diagrammer
        SwiftUI.Window("Diagrammer", id: "diagrammer") {
            DiagrammerView()
        }
        .modelContainer(persistenceContainer)
        
        // Window for Tool: Slide Studio
        SwiftUI.Window("Slide Studio", id: "slideStudio") {
            SlideStudioView()
        }
        .modelContainer(persistenceContainer)
        
        // Settings window
        SwiftUI.Settings {
            SettingsView()
        }
        .modelContainer(persistenceContainer)
        
    }
    
}

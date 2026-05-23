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
    
    private static let logger: Logger = .init(
        subsystem: Bundle.main.bundleIdentifier ?? "Sidekick",
        category: String(describing: AppDelegate.self)
    )
    
    /// Hard ceiling on coordinated quit cleanup. Bigger than the per-server
    /// SIGTERM grace period so two servers can shut down sequentially before
    /// SIGKILL is escalated, but short enough that the app never feels stuck
    /// on quit.
    private static let shutdownTimeout: TimeInterval = 5.0
    
    /// Function that runs after the app is initialized
    public func applicationDidFinishLaunching(
        _ notification: Notification
    ) {
        // Wire up inference lifecycle so child processes are torn down on
        // any quit path (Cmd+Q, log out, `kill <pid>`, Ctrl-C, crash).
        self.configureInferenceShutdown()
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
    
    /// Function that runs before the app is terminated.
    ///
    /// Returns ``.terminateLater`` and runs an awaitable coordinated
    /// shutdown of every memory-intensive inference child process before
    /// telling AppKit it is safe to exit. This guarantees that on a normal
    /// quit no orphan `llama-server` / `llama-perplexity` survives.
    public func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        // Synchronous, cheap cleanup that must run before we yield.
        SourcesStore.removeStaleSources()
        ExpertManager.removeUnpersistedResources()
        // Run the heavy async shutdown off-actor and ask AppKit to wait.
        Task.detached { [weak self] in
            await self?.performCoordinatedShutdown()
            await MainActor.run {
                NSApplication.shared.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
    
    /// Last-chance cleanup. AppKit only fires this for normal quits — not
    /// for SIGKILL, but it is fired for `applicationShouldTerminate` → yes
    /// flows after our async work resolves. Use it as a belt-and-braces
    /// sweep so any PID that slipped past the coordinator is still killed.
    public func applicationWillTerminate(_ notification: Notification) {
        InferenceLifecycleCoordinator.shared.killAllRegisteredProcesses(
            gracePeriodSeconds: 0.5
        )
    }
    
    // MARK: - Inference Shutdown Wiring
    
    /// Register every owner of an inference child process with the
    /// coordinator and install UNIX signal handlers so that quit/kill paths
    /// converge on a single shutdown routine.
    private func configureInferenceShutdown() {
        let coordinator = InferenceLifecycleCoordinator.shared
        // Catch SIGTERM/SIGINT/SIGHUP — `kill <pid>`, terminal Ctrl-C, or
        // session logout. (SIGKILL is uninterceptable; the bundled
        // `llama-server-watchdog` handles that case.)
        coordinator.installSignalHandlers()
        // Hook: interrupt active streams + stop main & worker llama-servers.
        coordinator.registerShutdownHook(identifier: "Model") {
            await Model.shared.interrupt()
            await Model.shared.stopServers()
        }
    }
    
    /// Run every registered shutdown hook with a hard ceiling and then
    /// sweep the PID registry to make sure nothing survives.
    private func performCoordinatedShutdown() async {
        Self.logger.notice("AppDelegate beginning coordinated inference shutdown")
        await InferenceLifecycleCoordinator.shared.shutdownAll(
            timeout: Self.shutdownTimeout
        )
        Self.logger.notice("AppDelegate finished coordinated inference shutdown")
    }
    
}

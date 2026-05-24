//
//  LlamaServer+ServerLifecycle.swift
//  Sidekick
//
//  Created by Bean John on 10/9/24.
//

import Darwin
import Foundation
import FSKit_macOS
import OSLog

extension LlamaServer {
    
    /// Function to start a monitor process that will terminate the server when our app dies
    /// - Parameter serverPID: The process identifier of `llama-server`, of type `pid_t`
    func startAppMonitor(
        serverPID: pid_t
    ) throws {
        // Start `llama-server-watchdog`
        monitor = Process()
        monitor.executableURL = Bundle.main.url(forAuxiliaryExecutable: "llama-server-watchdog")
        monitor.arguments = [
            String(serverPID)
        ]
        // Send main app's heartbeat to show that the main app is still running
        let heartbeat = Pipe()
        self.heartbeatPipe = heartbeat
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        timer.schedule(deadline: .now(), repeating: 15.0)
        timer.setEventHandler { [weak heartbeat] in
            guard let heartbeat = heartbeat else { return }
            let data = ".".data(using: .utf8) ?? Data()
            // Writing to a closed pipe raises SIGPIPE; guard so a dead
            // watchdog never crashes the host app.
            do {
                try heartbeat.fileHandleForWriting.write(contentsOf: data)
            } catch {
                // Pipe was closed (watchdog exited); silently stop heartbeating.
            }
        }
        timer.resume()
        self.heartbeatTimer = timer
        monitor.standardInput = heartbeat
        // Start monitor
        try monitor.run()
        // Register both children so a coordinated shutdown can clean them up
        // regardless of which path the app exits through.
        InferenceLifecycleCoordinator.shared.register(pid: serverPID)
        InferenceLifecycleCoordinator.shared.register(pid: monitor.processIdentifier)
        Self.logger.notice(
            "Started monitor for server with PID \(serverPID)"
        )
    }
    
    /// Function to start the `llama-server` process
    public func startServer(
        canReachRemoteServer: Bool
    ) async throws {
        // If a model is missing, throw error
        let hasModel: Bool = self.modelUrl?.fileExists ?? false
        let usesSpeculativeModel: Bool = InferenceSettings.useSpeculativeDecoding && self.modelType == .regular
        let hasSpeculativeModel: Bool = InferenceSettings.speculativeDecodingModelUrl?.fileExists ?? false
        if !hasModel || (usesSpeculativeModel && !hasSpeculativeModel) {
            Self.logger.error("Main model or draft model is missing")
            throw LlamaServerError.modelError
        }
        // If server is running, or is starting server, or no model, exit
        guard !process.isRunning,
              !self.isStartingServer,
              let modelPath = self.modelUrl?.posixPath else {
            return
        }
        // Signal beginning of server initialization
        self.isStartingServer = true
        // Stop server if running
        await stopServer()
        // Initialize `llama-server` process
        process = Process()
        let startTime: Date = Date.now
        process.executableURL = Bundle.main.privateFrameworksURL?.appendingPathComponent("llama-server")
        
        // GPU acceleration is always on. The legacy CPU-only toggle has
        // been removed; users who genuinely need CPU-only inference can
        // override `--gpu-layers 0` via Advanced Parameters.
        let processors: Int = ProcessInfo.processInfo.activeProcessorCount
        let threadsToUse: Int = max(1, Int(ceil(Double(processors) / 3.0 * 2.0)))
        let gpuLayersToUse: String = "99"

        // Formulate arguments
        var arguments: [String: String] = [
            "--model": modelPath,
            "--threads": "\(threadsToUse)",
            "--threads-batch": "\(threadsToUse)",
            "--ctx-size": "\(self.totalContextLength)",
            "--parallel": "\(self.parallelSlots)",
            "--port": self.port,
            "--gpu-layers": gpuLayersToUse
        ]
        // Extra options for main model
        if self.modelType == .regular {
            // Only enable `--jinja` when the model's GGUF ships a chat template
            // that knows how to render and parse tool calls. Without that, the
            // flag either errors out (no template at all) or buys us nothing
            // and risks the server emitting text-mode tool calls that the
            // client can't recover.
            if Settings.useFunctions,
               GGUFMetadataReader.modelSupportsToolAwareJinja(
                at: URL(fileURLWithPath: modelPath)
               ) {
                arguments["--jinja"] = ""
            }
            // Use speculative decoding
            if InferenceSettings.useSpeculativeDecoding,
               let speculationModelUrl = InferenceSettings.speculativeDecodingModelUrl {
                // Formulate arguments
                let draft: Int =  16
                let draftMin: Int = 7
                let draftPMin: Double = 0.75
                let speculativeDecodingArguments: [String: String] = [
                    "--model-draft": speculationModelUrl.posixPath,
                    "--gpu-layers-draft": "\(gpuLayersToUse)",
                    "--draft-p-min": "\(draftPMin)",
                    "--draft": "\(draft)",
                    "--draft-min": "\(draftMin)"
                ]
                // Append
                speculativeDecodingArguments.forEach { element in
                    arguments[element.key] = element.value
                }
            }
            // Use multimodal
            if InferenceSettings.localModelUseVision,
               let multimodalModelUrl = InferenceSettings.projectorModelUrl {
                // Formulate argument
                let multimodalArguments: [String: String] = [
                    "--mmproj": multimodalModelUrl.posixPath
                ]
                // Append
                multimodalArguments.forEach { element in
                    arguments[element.key] = element.value
                }
            }
            // Remove duplicate arguments
            let activeArguments: [ServerArgument] = await MainActor.run { ServerArgumentsStore.activeArguments() }
            let activeFlags = activeArguments.map(keyPath: \.flag)
            arguments = arguments.filter { !activeFlags.contains($0.key) }
            // Convert dictionary to [String] format with each key and value as separate elements
            var formattedArguments: [String] = []
            arguments.forEach { key, value in
                formattedArguments.append(key)
                if !value.isEmpty {
                    formattedArguments.append(value)
                }
            }
            // Add custom arguments
            let allArguments: [String] = await MainActor.run { ServerArgumentsStore.allArguments() }
            formattedArguments += allArguments
            // Assign arguments
            process.arguments = formattedArguments
        } else {
            // Else, just convert and assign
            var formattedArguments: [String] = []
            arguments.forEach { key, value in
                formattedArguments.append(key)
                if !value.isEmpty  {
                    formattedArguments.append(value)
                }
            }
            process.arguments = formattedArguments
        }
        
        Self.logger.notice("Starting llama.cpp server \(self.process.arguments!.joined(separator: " "), privacy: .public)")
        
        process.standardInput = FileHandle.nullDevice
        
        // To debug with server's output, comment these 2 lines to inherit stdout.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        
        try process.run()
        
        try await self.waitForServer(
            canReachRemoteServer: canReachRemoteServer
        )
        
        try startAppMonitor(serverPID: process.processIdentifier)
        
        let endTime: Date = Date.now
        let elapsedTime: Double = endTime.timeIntervalSince(startTime)
        
#if DEBUG
        print("Started server process in \(elapsedTime) secs")
#endif
        self.isStartingServer = false
    }
    
    /// Function to stop the `llama-server` process.
    ///
    /// Performs a graceful `SIGTERM`, waits up to ``gracePeriodSeconds`` for
    /// the process to exit, then escalates to `SIGKILL` to guarantee that
    /// memory-intensive inference children are released before this call
    /// returns. Any active streaming requests are cancelled first so their
    /// callbacks unblock before the server disappears.
    public func stopServer(
        gracePeriodSeconds: TimeInterval = 1.5
    ) async {
        // Cancel any in-flight streaming requests so their continuations
        // don't outlive the underlying process.
        self.pendingCancellationForAllRequests = true
        for context in self.activeRequests.values {
            context.cancel()
        }
        self.activeRequests.removeAll()
        // Stop heartbeat first so the watchdog doesn't keep firing while
        // we tear the server down ourselves.
        self.heartbeatTimer?.cancel()
        self.heartbeatTimer = nil
        try? self.heartbeatPipe?.fileHandleForWriting.close()
        self.heartbeatPipe = nil
        let serverPID: pid_t = self.process.isRunning ? self.process.processIdentifier : 0
        let monitorPID: pid_t = self.monitor.isRunning ? self.monitor.processIdentifier : 0
        // SIGTERM both children.
        if self.process.isRunning {
            self.process.terminate()
        }
        if self.monitor.isRunning {
            self.monitor.terminate()
        }
        // Wait for them to actually exit. Never blocks forever — falls back
        // to SIGKILL if the grace period elapses without exit.
        await self.awaitChildExit(
            process: self.process,
            fallbackPID: serverPID,
            timeoutSeconds: gracePeriodSeconds
        )
        await self.awaitChildExit(
            process: self.monitor,
            fallbackPID: monitorPID,
            timeoutSeconds: gracePeriodSeconds
        )
        // Make sure neither PID is still tracked.
        InferenceLifecycleCoordinator.shared.unregister(pid: serverPID)
        InferenceLifecycleCoordinator.shared.unregister(pid: monitorPID)
        self.process = Process()
        self.monitor = Process()
        self.pendingCancellationForAllRequests = false
    }
    
    /// Wait for ``process`` to exit, escalating from `SIGTERM` to `SIGKILL`
    /// if ``timeoutSeconds`` expires. Uses `kill(pid, 0)` as the authoritative
    /// liveness check because `Process.isRunning` lags behind kernel state.
    private func awaitChildExit(
        process: Process,
        fallbackPID: pid_t,
        timeoutSeconds: TimeInterval
    ) async {
        let pid: pid_t = process.processIdentifier > 0 ? process.processIdentifier : fallbackPID
        guard pid > 0 || process.isRunning else { return }
        let deadline: Date = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if !process.isRunning && (pid <= 0 || kill(pid, 0) != 0) {
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if process.isRunning || (pid > 0 && kill(pid, 0) == 0) {
            Self.logger.warning(
                "llama child PID \(pid, privacy: .public) did not exit within \(timeoutSeconds, privacy: .public)s; sending SIGKILL"
            )
            if pid > 0 {
                _ = kill(pid, SIGKILL)
            }
            for _ in 0..<10 {
                if !process.isRunning && (pid <= 0 || kill(pid, 0) != 0) {
                    break
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }
    
    /// Function showing if connection was interrupted
    public func interrupt(requestID: UUID? = nil) async {
        if let requestID,
           let context = self.activeRequests[requestID] {
            context.cancel()
            return
        }
        
        guard requestID == nil else {
            return
        }
        
        self.pendingCancellationForAllRequests = true
        for context in self.activeRequests.values {
            context.cancel()
        }
    }
    
    /// Function run for waiting for the server
    func waitForServer(
        canReachRemoteServer: Bool
    ) async throws {
        // Check health
        guard process.isRunning else { return }
        // Init server health project
        let serverHealth = ServerHealth()
        await serverHealth.updateURL(
            self.url(
                "/health",
                openAiCompatiblePath: false,
                canReachRemoteServer: canReachRemoteServer,
                mustUseLocalServer: true
            ).url
        )
        await serverHealth.check()
        // Set check parameters
        var timeout = 30 // Timeout after 30 seconds
        let tick = 1 // Check every second
        while true {
            let score = await serverHealth.score
            if score >= 0.25 { break }
            try await Task.sleep(for: .seconds(tick))
            timeout -= tick
            if timeout <= 0 {
                Self.logger.error("llama-server did not respond in reasonable time")
                // Display error
                throw LlamaServerError.modelError
            }
            await serverHealth.check()
        }
    }
    
}

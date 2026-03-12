//
//  LlamaServer+ServerLifecycle.swift
//  Sidekick
//
//  Created by Bean John on 10/9/24.
//

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
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        timer.schedule(deadline: .now(), repeating: 15.0)
        timer.setEventHandler { [weak heartbeat] in
            guard let heartbeat = heartbeat else { return }
            let data = ".".data(using: .utf8) ?? Data()
            heartbeat.fileHandleForWriting.write(data)
        }
        timer.resume()
        monitor.standardInput = heartbeat
        // Start monitor
        try monitor.run()
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
        
        let gpuLayers: Int = 99
        let processors: Int = ProcessInfo.processInfo.activeProcessorCount
        let threadsToUseIfGPU: Int = max(1, Int(ceil(Double(processors) / 3.0 * 2.0)))
        let threadsToUseIfCPU: Int = processors
        let threadsToUse: Int = InferenceSettings.useGPUAcceleration ? threadsToUseIfGPU : threadsToUseIfCPU
        let gpuLayersToUse: String = InferenceSettings.useGPUAcceleration ? "\(gpuLayers)" : "0"
        
        // Formulate arguments
        var arguments: [String: String] = [
            "--model": modelPath,
            "--threads": "\(threadsToUse)",
            "--threads-batch": "\(threadsToUse)",
            "--ctx-size": "\(self.contextLength)",
            "--port": self.port,
            "--gpu-layers": gpuLayersToUse
        ]
        // Extra options for main model
        if self.modelType == .regular {
            // Use jinja chat template if tools are used
            if Settings.useFunctions {
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
            let activeArguments: [ServerArgument] = ServerArgumentsManager.shared.activeArguments
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
            let allArguments: [String] = ServerArgumentsManager.shared.allArguments
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
    
    /// Function to stop the `llama-server` process
    public func stopServer() async {
        // Terminate processes
        if self.process.isRunning {
            self.process.terminate()
        }
        if self.monitor.isRunning {
            self.monitor.terminate()
        }
        self.process = Process()
        self.monitor = Process()
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
            await serverHealth.check()
            let score = await serverHealth.score
            if score >= 0.25 { break }
            await serverHealth.check()
            try await Task.sleep(for: .seconds(tick))
            timeout -= tick
            if timeout <= 0 {
                Self.logger.error("llama-server did not respond in reasonable time")
                // Display error
                throw LlamaServerError.modelError
            }
        }
    }
    
}

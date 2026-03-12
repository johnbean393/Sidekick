//
//  Model+Inference.swift
//  Sidekick
//
//  Created by Bean John on 9/22/24.
//

import Foundation
import OSLog
import SimilaritySearchKit
import SwiftUI

extension Model {
    
    /// Function for the main loop
    /// Listen -> respond -> update mental model and save checkpoint
    /// Stream response to avoid a long delay after user input
    func listenThinkRespond(
        messages: [Message],
        modelType: ModelType,
        mode: Model.Mode,
        similarityIndex: SimilarityIndex? = nil,
        useWebSearch: Bool = false,
        useFunctions: Bool = false,
        functions: [AnyFunctionBox]? = nil,
        expert: Expert? = nil,
        enableThinking: Bool? = nil,
        useCanvas: Bool = false,
        canvasSelection: String? = nil,
        temporaryResources: [TemporaryResource] = [],
        showPreview: Bool = false,
        handleResponseUpdate: @escaping (
            String, // Full message
            String // Delta
        ) -> Void = { _, _ in },
        handleResponseFinish: @escaping (
            String, // Pending message
            String,  // Final message
            Int? // Tokens used
        ) -> Void = { _, _, _ in }
    ) async throws -> LlamaServer.CompleteResponse {
        // Reset pending message
        if showPreview {
            self.pendingMessage = nil
        }
        // Set flag
        let preQueryStatus: Status = self.status
        if preQueryStatus.isForegroundTask {
            let isDeepResearching: Bool = self.status == .deepResearch
            self.status = (mode.isAgent || isDeepResearching) ? .deepResearch : .querying
        }
        // Check if remote server is reachable
        let canReachRemoteServer: Bool = await self.remoteServerIsReachable()
        // Formulate message subset
        let useServer: Bool = canReachRemoteServer && InferenceSettings.useServer
        let lastIndex: Int = messages.count - 1
        let hasVision: Bool = LlamaServer.modelHasVision(
            type: modelType,
            usingRemoteModel: useServer
        )
        let messagesWithSources: [Message.MessageSubset] = await messages
            .enumerated()
            .asyncMap { index, message in
                return await Message.MessageSubset(
                    modelType: modelType,
                    usingRemoteModel: useServer,
                    message: message,
                    similarityIndex: similarityIndex,
                    temporaryResources: temporaryResources,
                    shouldAddSources: (
                        index == lastIndex
                    ),
                    useVisionContent: hasVision,
                    useWebSearch: useWebSearch,
                    useCanvas: useCanvas,
                    canvasSelection: canvasSelection
                )
            }
        // Respond to prompt
        if self.status.isForegroundTask && self.status != .deepResearch {
            if preQueryStatus == .cold {
                self.status = .coldProcessing
            } else {
                self.status = .processing
            }
        }
        // Send different response based on mode
        var response: LlamaServer.CompleteResponse? = nil
        switch mode {
            case .`default`:
                if modelType == .worker {
                    let shouldUseDedicatedWorkerServer: Bool = (
                        canReachRemoteServer && InferenceSettings.useServer
                    ) || (InferenceSettings.workerModelUrl?.fileExists ?? false)
                    let progressHandler: @Sendable (String) -> Void = { partialResponse in
                        DispatchQueue.main.async {
                            self.handleCompletionProgress(
                                showPreview: showPreview,
                                partialResponse: partialResponse,
                                handleResponseUpdate: handleResponseUpdate
                            )
                        }
                    }
                    if shouldUseDedicatedWorkerServer {
                        do {
                            response = try await self.workerModelServer.getChatCompletion(
                                mode: mode,
                                canReachRemoteServer: canReachRemoteServer,
                                messages: messagesWithSources,
                                enableThinking: enableThinking,
                                progressHandler: progressHandler
                            )
                        } catch {
                            response = try await self.mainModelServer.getChatCompletion(
                                mode: mode,
                                canReachRemoteServer: canReachRemoteServer,
                                messages: messagesWithSources,
                                enableThinking: enableThinking,
                                progressHandler: progressHandler
                            )
                        }
                    } else {
                        response = try await self.mainModelServer.getChatCompletion(
                            mode: mode,
                            canReachRemoteServer: canReachRemoteServer,
                            messages: messagesWithSources,
                            enableThinking: enableThinking,
                            progressHandler: progressHandler
                        )
                    }
                } else {
                    response = try await self.mainModelServer.getChatCompletion(
                        mode: mode,
                        canReachRemoteServer: canReachRemoteServer,
                        messages: messagesWithSources,
                        enableThinking: enableThinking,
                        progressHandler: { partialResponse in
                            DispatchQueue.main.async {
                                // Update response
                                self.handleCompletionProgress(
                                    showPreview: showPreview,
                                    partialResponse: partialResponse,
                                    handleResponseUpdate: handleResponseUpdate
                                )
                            }
                        }
                    )
                }
            case .chat, .agent:
                response = try await self.getChatResponse(
                    mode: mode,
                    modelType: modelType,
                    canReachRemoteServer: canReachRemoteServer,
                    messagesWithSources: messagesWithSources,
                    useWebSearch: useWebSearch,
                    useFunctions: useFunctions,
                    functions: functions,
                    expert: expert,
                    enableThinking: enableThinking,
                    similarityIndex: similarityIndex,
                    showPreview: showPreview,
                    handleResponseUpdate: handleResponseUpdate
                )
            case .deepResearch:
                // Indicate started Deep Research
                self.indicateStartedDeepResearch()
                // Init and run deep research workflow
                self.agent = DeepResearchAgent(
                    messages: messages,
                    similarityIndex: similarityIndex
                )
                response = try await self.agent?.run()
                self.agent = nil
                self.pendingMessage = nil
                self.status = .ready
        }
        // Handle response finish
        handleResponseFinish(
            response!.text,
            self.pendingMessage?.text ?? "",
            response!.usage?.total_tokens
        )
        // Update display
        if showPreview && self.agent == nil {
            self.pendingMessage = nil
            self.status = .ready
        }
        Self.logger.notice("Finished responding to prompt")
        return response!
    }
    
    /// A function to update the inference status
    func updateStatus(
        _ status: Status
    ) {
        if self.status != status && self.status != .deepResearch {
            self.status = status
        }
    }
    
    /// Function to get response for chat
    private func getChatResponse(
        mode: Model.Mode,
        modelType: ModelType,
        canReachRemoteServer: Bool,
        messagesWithSources: [Message.MessageSubset],
        useWebSearch: Bool,
        useFunctions: Bool,
        functions: [AnyFunctionBox]? = nil,
        expert: Expert? = nil,
        enableThinking: Bool? = nil,
        similarityIndex: SimilarityIndex? = nil,
        showPreview: Bool,
        handleResponseUpdate: @escaping (String, String) -> Void
    ) async throws -> LlamaServer.CompleteResponse {
        // Define increment for update
        let increment: Int = 8
        // Handle initial response
        let initialResponse = try await getInitialResponse(
            mode: mode,
            canReachRemoteServer: canReachRemoteServer,
            messages: messagesWithSources,
            useWebSearch: useWebSearch,
            useFunctions: useFunctions,
            functions: functions,
            expert: expert,
            enableThinking: enableThinking,
            showPreview: showPreview,
            handleResponseUpdate: handleResponseUpdate,
            increment: increment
        )
        // Return if functions are disabled
        if !Settings.useFunctions || !useFunctions {
            return initialResponse
        }
        // Return if no function call
        guard let functionCalls = initialResponse.functionCalls,
              !functionCalls.isEmpty else {
            return initialResponse
        }
        // Run agent in a loop
        return try await self.handleFunctionCall(
            canReachRemoteServer: canReachRemoteServer,
            initialResponse: initialResponse,
            messages: messagesWithSources,
            useWebSearch: useWebSearch,
            functions: functions,
            enableThinking: enableThinking,
            similarityIndex: similarityIndex,
            showPreview: showPreview,
            handleResponseUpdate: handleResponseUpdate,
            increment: increment
        )
    }
    
    /// Get the initial response to a chatbot query
    private func getInitialResponse(
        mode: Model.Mode,
        canReachRemoteServer: Bool,
        messages: [Message.MessageSubset],
        useWebSearch: Bool,
        useFunctions: Bool,
        functions: [AnyFunctionBox]? = nil,
        expert: Expert? = nil,
        enableThinking: Bool? = nil,
        showPreview: Bool,
        handleResponseUpdate: @escaping (String, String) -> Void,
        increment: Int
    ) async throws -> LlamaServer.CompleteResponse {
        let canReachRemoteServer: Bool = await self.remoteServerIsReachable()
        var updateResponse = ""
        return try await self.mainModelServer.getChatCompletion(
            mode: mode,
            canReachRemoteServer: canReachRemoteServer,
            messages: messages,
            useWebSearch: useWebSearch,
            useFunctions: useFunctions,
            functions: functions,
            expert: expert,
            enableThinking: enableThinking,
            updateStatusHandler: { status in
                await self.updateStatus(status)
            },
            progressHandler:  { partialResponse in
                DispatchQueue.main.async {
                    updateResponse += partialResponse
                    let shouldUpdate = updateResponse.count >= increment ||
                    (self.pendingMessage?.text.count ?? 0 < increment)
                    if shouldUpdate {
                        self.handleCompletionProgress(
                            showPreview: showPreview,
                            partialResponse: updateResponse,
                            handleResponseUpdate: handleResponseUpdate
                        )
                        updateResponse = ""
                    }
                }
            }
        )
    }
    
    /// Function to run code if model calls a function
    private func handleFunctionCall(
        canReachRemoteServer: Bool,
        initialResponse: LlamaServer.CompleteResponse,
        messages: [Message.MessageSubset],
        useWebSearch: Bool,
        functions: [AnyFunctionBox]? = nil,
        enableThinking: Bool? = nil,
        similarityIndex: SimilarityIndex?,
        showPreview: Bool,
        handleResponseUpdate: @escaping (
            String, // Full message
            String // Delta
        ) -> Void = { _, _ in },
        increment: Int
    ) async throws -> LlamaServer.CompleteResponse {
        // Set status
        if self.status != .deepResearch {
            self.status = .usingFunctions
        }
        // Execute functions on a loop
        var maxIterations: Int = 30 // Max 30 tool calls
        var response: LlamaServer.CompleteResponse? = initialResponse
        var messages: [Message.MessageSubset] = messages
        // Capture results
        var results: [FunctionCallResult] = []
        // Track consecutive malformed call attempts for circuit breaking
        var consecutiveMalformedAttempts: Int = 0
        let maxConsecutiveMalformed: Int = 3
        
        // Check for malformed tool calls in initial response
        if let malformedCalls = response?.malformedToolCalls, !malformedCalls.isEmpty {
            Self.logger.warning("Initial response contains \(malformedCalls.count) malformed tool call(s)")
            
            // If ALL tool calls are malformed and there are no valid ones, provide feedback
            if response?.functionCalls?.isEmpty ?? true {
                consecutiveMalformedAttempts += 1
                Self.logger.error("All tool calls in response are malformed. Providing error feedback to model.")
                
                // Create error feedback for each malformed call
                for malformedCall in malformedCalls {
                    let errorResult = FunctionCallResult(
                        call: malformedCall.name ?? "unknown_function",
                        result: malformedCall.getErrorFeedback(),
                        type: .error
                    )
                    results.append(errorResult)
                }
                
                // Check if we should break the circuit
                if consecutiveMalformedAttempts >= maxConsecutiveMalformed {
                    Self.logger.error("Maximum consecutive malformed attempts reached. Breaking agentic loop.")
                    // Create a helpful error message
                    let errorMessage = """
                    The model has made \(maxConsecutiveMalformed) consecutive attempts with malformed tool calls.
                    
                    Common issues:
                    1. Invalid JSON syntax in tool arguments
                    2. Missing required parameters
                    3. Type mismatches (e.g., string instead of integer)
                    4. Incorrect parameter names
                    
                    Please review the tool schemas and try again with properly formatted tool calls.
                    """
                    return LlamaServer.CompleteResponse(
                        text: errorMessage,
                        responseStartSeconds: initialResponse.responseStartSeconds,
                        predictedPerSecond: initialResponse.predictedPerSecond,
                        modelName: initialResponse.modelName,
                        usage: initialResponse.usage,
                        usedServer: initialResponse.usedServer,
                        blockFunctionCalls: nil,
                        malformedToolCalls: malformedCalls
                    )
                }
                
                // Continue to provide feedback and let model retry
            } else {
                // Some calls succeeded, some failed - add errors for failed ones
                Self.logger.info("Some tool calls succeeded, adding error feedback for \(malformedCalls.count) malformed call(s)")
                for malformedCall in malformedCalls {
                    let errorResult = FunctionCallResult(
                        call: malformedCall.name ?? "unknown_function",
                        result: malformedCall.getErrorFeedback(),
                        type: .error
                    )
                    results.append(errorResult)
                }
                // Reset counter since we have some valid calls
                consecutiveMalformedAttempts = 0
            }
        } else if response?.functionCalls?.isEmpty ?? true {
            // No tool calls at all (valid or malformed) - normal exit condition
            consecutiveMalformedAttempts = 0
        } else {
            // Has valid tool calls - reset counter
            consecutiveMalformedAttempts = 0
        }
        
        while maxIterations > 0, let functionCalls = response?.functionCalls {
            // Execute each call
            var functionCallRecords = self.pendingMessage?.functionCallRecords ?? []
            for index in functionCalls.indices {
                var functionCall = functionCalls[index]
                // Log function call
                let callJsonSchema: String = functionCall.getJsonSchema()
                Self.logger.info("Executing function call: \(callJsonSchema, privacy: .public)")
                // Display call to user
                functionCallRecords = self.pendingMessage?.functionCallRecords ?? []
                var functionCallRecord: FunctionCallRecord = FunctionCallRecord(
                    name: functionCall.name
                )
                withAnimation(.linear) {
                    self.pendingMessage?.functionCallRecords = functionCallRecords + [functionCallRecord]
                    self.pendingMessage?.text = ""
                }
                // Call function
                do {
                    // Run
                    let result: String = try await functionCall.call() ?? "Function evaluated successfully"
                    // Mark as succeeded
                    functionCallRecord.markAsFinished(
                        status: .succeeded,
                        result: result
                    )
                    // Record tools called
                    let newResult: FunctionCallResult = FunctionCallResult(
                        call: callJsonSchema,
                        result: result,
                        type: .result
                    )
                    results.append(newResult)
                } catch {
                    // Get error description
                    let errorDescription: String = error.localizedDescription
                    // Mark as failed
                    functionCallRecord.markAsFinished(
                        status: .failed,
                        result: errorDescription
                    )
                    // Record tools called
                    let newResult: FunctionCallResult = FunctionCallResult(
                        call: callJsonSchema,
                        result: errorDescription,
                        type: .error
                    )
                    results.append(newResult)
                }
                withAnimation(.linear) {
                    functionCallRecords += [functionCallRecord]
                    self.pendingMessage?.functionCallRecords = functionCallRecords
                }
            }
            // Add assistant response message
            let responseMessage: Message = Message(
                text: response?.text ?? "",
                sender: .assistant
            )
            let responseMessageSubset: Message.MessageSubset = await Message.MessageSubset(
                usingRemoteModel: self.wasRemoteServerAccessible,
                message: responseMessage
            )
            messages.append(responseMessageSubset)
            // Check if further tool call is needed
            var hasMadeSufficientCalls: Bool = false
            // If there are incomplete to-do items, skip the sufficiency check and continue with tools
            let hasIncompleteTodos: Bool = TodoFunctions.getIncompleteTodoSummary() != nil
            if !hasIncompleteTodos {
                let checkMode = Settings.FunctionCompletionCheckMode(
                    Settings.checkFunctionsCompletion
                )
                if checkMode != .none,
                   let modelType = checkMode.modelType {
                    hasMadeSufficientCalls = await self.sufficientFunctionCalls(
                        modelType: modelType,
                        messages: messages,
                        canReachRemoteServer: canReachRemoteServer,
                        results: results
                    )
                }
            }
            // Add prompt to steer the next agent step
            let changePrompt: String = {
                if hasMadeSufficientCalls {
                    return """
Organize the information above into a response to the user's query.
"""
                } else {
                    return """
Call another tool to obtain more information or execute more actions. Try breaking down the user's query into steps, and find information about its constituent parts.
"""
                }
            }()
            
            // We'll append (or replace) this change message while retrying if compression is needed
            var hasAppendedChangeMessage = false
            var compressionAttempts = 0
            
            retryLoop: while true {
                var messageStringComponents: [String] = results.map(\.description)
                if let todoSummary = TodoFunctions.getIncompleteTodoSummary() {
                    messageStringComponents.append(todoSummary)
                }
                messageStringComponents.append(changePrompt)
                
                let changeMessage = Message(
                    text: messageStringComponents.joined(separator: "\n\n"),
                    sender: .user
                )
                let changeMessageSubset = await Message.MessageSubset(
                    usingRemoteModel: self.wasRemoteServerAccessible,
                    message: changeMessage
                )
                if hasAppendedChangeMessage {
                    messages[messages.count - 1] = changeMessageSubset
                } else {
                    messages.append(changeMessageSubset)
                    hasAppendedChangeMessage = true
                }
                
                var updateResponse: String = ""
                self.pendingMessage?.text = updateResponse
                
                do {
                    response = try await self.mainModelServer.getChatCompletion(
                        mode: .chat,
                        canReachRemoteServer: canReachRemoteServer,
                        messages: messages,
                        useWebSearch: useWebSearch,
                        useFunctions: true,
                        functions: functions,
                        enableThinking: enableThinking,
                        updateStatusHandler: { status in
                            await self.updateStatus(status)
                        },
                        progressHandler: { partialResponse in
                            DispatchQueue.main.async {
                                updateResponse += partialResponse
                                let shouldUpdate = updateResponse.count >= increment ||
                                (
                                    self.pendingMessage?.text.count ?? 0 < increment
                                )
                                if shouldUpdate {
                                    self.handleCompletionProgress(
                                        showPreview: showPreview,
                                        partialResponse: updateResponse,
                                        handleResponseUpdate: handleResponseUpdate
                                    )
                                    updateResponse = ""
                                }
                            }
                        }
                    )
                    break retryLoop
                } catch let error as LlamaServerError {
                    if case .contextWindowExceeded = error,
                       InferenceSettings.enableContextCompression,
                       compressionAttempts < 3 {
                        compressionAttempts += 1
                        Self.logger.warning("Context window exceeded (attempt \(compressionAttempts)). Compressing tool results.")
                        results = try await ContextCompressor.compressFunctionResults(
                            results,
                            threshold: InferenceSettings.compressionTokenThreshold
                        )
                        continue retryLoop
                    } else {
                        throw error
                    }
                }
            }
            response?.functionCallRecords = functionCallRecords
            
            // Check for malformed tool calls in the new response
            if let malformedCalls = response?.malformedToolCalls, !malformedCalls.isEmpty {
                Self.logger.warning("Response contains \(malformedCalls.count) malformed tool call(s)")
                
                // If ALL tool calls are malformed and there are no valid ones
                if response?.functionCalls?.isEmpty ?? true {
                    consecutiveMalformedAttempts += 1
                    Self.logger.error("All tool calls in iteration are malformed. Providing error feedback to model.")
                    
                    // Add error feedback for each malformed call
                    for malformedCall in malformedCalls {
                        let errorResult = FunctionCallResult(
                            call: malformedCall.name ?? "unknown_function",
                            result: malformedCall.getErrorFeedback(),
                            type: .error
                        )
                        results.append(errorResult)
                    }
                    
                    // Check if we should break the circuit
                    if consecutiveMalformedAttempts >= maxConsecutiveMalformed {
                        Self.logger.error("Maximum consecutive malformed attempts (\(maxConsecutiveMalformed)) reached in loop. Breaking.")
                        // Create a helpful error message
                        let errorMessage = """
After \(maxConsecutiveMalformed) consecutive attempts, the model continues to produce malformed tool calls.

Recent errors:
\(malformedCalls.map { "- \($0.name ?? "unknown"): \($0.errorDescription)" }.joined(separator: "\n"))

Please try rephrasing your request or contact support if the issue persists.
"""
                        return LlamaServer.CompleteResponse(
                            text: errorMessage,
                            responseStartSeconds: response?.responseStartSeconds ?? 0,
                            predictedPerSecond: response?.predictedPerSecond,
                            modelName: response?.modelName,
                            usage: response?.usage,
                            usedServer: response?.usedServer ?? false,
                            blockFunctionCalls: nil,
                            malformedToolCalls: malformedCalls
                        )
                    }
                } else {
                    // Some calls succeeded, some failed - add errors for failed ones
                    Self.logger.info("Some tool calls succeeded in iteration, adding error feedback for malformed ones")
                    for malformedCall in malformedCalls {
                        let errorResult = FunctionCallResult(
                            call: malformedCall.name ?? "unknown_function",
                            result: malformedCall.getErrorFeedback(),
                            type: .error
                        )
                        results.append(errorResult)
                    }
                    // Reset counter since we have some valid calls
                    consecutiveMalformedAttempts = 0
                }
            } else if response?.functionCalls?.isEmpty ?? true {
                // No more tool calls - normal loop exit
                consecutiveMalformedAttempts = 0
            } else {
                // Has valid tool calls - reset counter
                consecutiveMalformedAttempts = 0
            }
            
            // Increment counter & reset
            maxIterations -= 1
        }
        // Switch status to show stream for final answer
        self.status = .processing
        // Get reason for finishing
        let finishReason: FinishReason = maxIterations == 0 ? .maxIterationsReached : .noFunctionCall
        if finishReason == .noFunctionCall, let response = response {
            return response
        } else {
            // Else, fall back on one-shot answer
            Self.logger.error("Maximum number of function calls reached. Falling back to one-shot answer.")
            // Declare variable for incremental update
            var updateResponse: String = ""
            self.pendingMessage?.text = updateResponse
            // Get response
            var response: LlamaServer.CompleteResponse = try await self.mainModelServer.getChatCompletion(
                mode: .default,
                canReachRemoteServer: canReachRemoteServer,
                messages: messages,
                enableThinking: enableThinking,
                progressHandler: { partialResponse in
                    DispatchQueue.main.async {
                        updateResponse += partialResponse
                        let shouldUpdate = updateResponse.count >= increment ||
                        (
                            self.pendingMessage?.text.count ?? 0 < increment
                        )
                        if shouldUpdate {
                            self.handleCompletionProgress(
                                showPreview: showPreview,
                                partialResponse: updateResponse,
                                handleResponseUpdate: handleResponseUpdate
                            )
                            updateResponse = ""
                        }
                    }
                }
            )
            if let functionCallRecords = self.pendingMessage?.functionCallRecords {
                response.functionCallRecords = functionCallRecords
            }
            return response
        }
        // An enum of reasons for finishing
        enum FinishReason {
            case noFunctionCall, maxIterationsReached
        }
    }
    
    /// Function to check if enough calls were made
    private func sufficientFunctionCalls(
        modelType: ModelType,
        messages: [Message.MessageSubset],
        canReachRemoteServer: Bool,
        results: [FunctionCallResult]
    ) async -> Bool {
        // Formulate prompt
        let resultPrompts: [String] = results.map { result in
            return result.description
        }
        let checkPrompt: String = """
\(resultPrompts.joined(separator: "\n\n"))

Have the tool calls above obtained enough information to solve the user's query?
Have the maximum number of tools been called to best fulfill the user's request?
Have all tool calls in your initial plan been executed successfully?

Respond with YES if ALL 3 criteria above have been met. Respond with YES or NO only.
"""
        let message: Message = Message(
            text: checkPrompt,
            sender: .user
        )
        let messageSubset: Message.MessageSubset = await Message.MessageSubset(
            usingRemoteModel: self.wasRemoteServerAccessible,
            message: message
        )
        // Add to messages
        var messages: [Message.MessageSubset] = messages
        messages.append(messageSubset)
        // Check with model for a maximum of 3 tries
        for _ in 0..<3 {
            do {
                // Get response
                let response = try await {
                    switch modelType {
                        case .regular:
                            try await self.mainModelServer.getChatCompletion(
                                mode: .`default`,
                                canReachRemoteServer: canReachRemoteServer,
                                messages: messages,
                                useWebSearch: false,
                                useFunctions: true
                            )
                        default:
                            try await self.workerModelServer.getChatCompletion(
                                mode: .`default`,
                                canReachRemoteServer: canReachRemoteServer,
                                messages: messages,
                                useWebSearch: false,
                                useFunctions: true
                            )
                    }
                }()
                let responseText: String = response.text.reasoningRemoved
                // Validate response
                let possibleResponses: [String] = ["YES", "NO"]
                if possibleResponses.contains(responseText) {
                    return responseText == "YES"
                }
            } catch {
                // Try again
                continue
            }
        }
        // If fell through, return false
        return false
    }
    
    /// Function to handle response update
    func handleCompletionProgress(
        showPreview: Bool = true,
        partialResponse: String,
        handleResponseUpdate: @escaping (
            String, // Full message
            String // Delta
        ) -> Void
    ) {
        // Assign if nil
        if self.pendingMessage == nil && showPreview {
            self.pendingMessage = Message(text: "", sender: .assistant)
        }
        let fullMessage: String = (self.pendingMessage?.text ?? "") + partialResponse
        handleResponseUpdate(
            fullMessage,
            partialResponse
        )
        if showPreview {
            self.pendingMessage?.text = fullMessage
        }
    }
    
}

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
        // Return if there is no valid or malformed function call work to handle.
        guard initialResponse.requiresFunctionHandling else {
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
        let activeFunctions: [AnyFunctionBox]
        if !initialResponse.availableFunctions.isEmpty {
            activeFunctions = initialResponse.availableFunctions
        } else if let functions {
            activeFunctions = functions
        } else {
            activeFunctions = await DefaultFunctions.getEnabledFunctions()
        }
        let toolRegistry: ToolRegistry = {
            if !activeFunctions.isEmpty {
                return ToolRegistry(functions: activeFunctions)
            }
            return ToolRegistry(functions: [])
        }()
        // Execute functions on a loop
        var maxIterations: Int = 30 // Max 30 tool calls
        var response: LlamaServer.CompleteResponse? = initialResponse
        var messages: [Message.MessageSubset] = messages
        var results: [FunctionCallResult] = []
        var functionCallRecords: [FunctionCallRecord] = self.pendingMessage?.functionCallRecords ?? []
        // Track consecutive malformed call attempts for circuit breaking
        var consecutiveMalformedAttempts: Int = 0
        let maxConsecutiveMalformed: Int = 3

        // Check for malformed tool calls in initial response
        if let malformedCalls = response?.malformedToolCalls, !malformedCalls.isEmpty {
            Self.logger.warning("Initial response contains \(malformedCalls.count) malformed tool call(s)")

            if response?.functionCalls?.isEmpty ?? true {
                consecutiveMalformedAttempts += 1
                Self.logger.error("All tool calls in response are malformed. Providing error feedback to model.")

                for malformedCall in malformedCalls {
                    let errorResult = FunctionCallResult(
                        call: malformedCall.name ?? "unknown_function",
                        result: malformedCall.getErrorFeedback(),
                        type: .error
                    )
                    results.append(errorResult)
                }

                if consecutiveMalformedAttempts >= maxConsecutiveMalformed {
                    Self.logger.error("Maximum consecutive malformed attempts reached. Breaking agentic loop.")
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
                        startTime: initialResponse.startTime,
                        endTime: .now,
                        responseStartSeconds: initialResponse.responseStartSeconds,
                        predictedPerSecond: initialResponse.predictedPerSecond,
                        modelName: initialResponse.modelName,
                        usage: initialResponse.usage,
                        usedServer: initialResponse.usedServer,
                        availableFunctions: activeFunctions,
                        malformedToolCalls: malformedCalls,
                    )
                }
            } else {
                Self.logger.info("Some tool calls succeeded, adding error feedback for \(malformedCalls.count) malformed call(s)")
                for malformedCall in malformedCalls {
                    let errorResult = FunctionCallResult(
                        call: malformedCall.name ?? "unknown_function",
                        result: malformedCall.getErrorFeedback(),
                        type: .error
                    )
                    results.append(errorResult)
                }
                consecutiveMalformedAttempts = 0
            }
        } else if response?.functionCalls?.isEmpty ?? true {
            consecutiveMalformedAttempts = 0
        } else {
            consecutiveMalformedAttempts = 0
        }

        while maxIterations > 0, response?.requiresFunctionHandling == true {
            let responseFunctionCalls = response?.functionCalls ?? []
            if !responseFunctionCalls.isEmpty {
                var functionCalls = responseFunctionCalls
                for index in functionCalls.indices where functionCalls[index].toolCallID == nil {
                    functionCalls[index].toolCallID = UUID().uuidString
                }

                let executionOutput = await self.executeFunctionCalls(
                    functionCalls,
                    using: toolRegistry,
                    existingRecords: functionCallRecords
                )
                functionCallRecords = executionOutput.functionCallRecords
                results += executionOutput.results

                let assistantToolCallMessage = Message.MessageSubset.assistantToolCalls(
                    functionCalls: functionCalls
                )
                messages.append(assistantToolCallMessage)
                messages += executionOutput.toolMessages
            } else {
                Self.logger.warning("Retrying after malformed-only tool call response")
                let responseMessage: Message = Message(
                    text: response?.text ?? "",
                    sender: .assistant
                )
                let responseMessageSubset: Message.MessageSubset = await Message.MessageSubset(
                    usingRemoteModel: self.wasRemoteServerAccessible,
                    message: responseMessage
                )
                messages.append(responseMessageSubset)
            }

            var hasMadeSufficientCalls: Bool = false
            let hasIncompleteTodos: Bool = TodoFunctions.getIncompleteTodoSummary() != nil
            if !responseFunctionCalls.isEmpty && !hasIncompleteTodos {
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

            var hasAppendedChangeMessage = false
            var compressionAttempts = 0
            let toolChoice: ChatParameters.ToolChoice = hasMadeSufficientCalls ? .none : .auto

            retryLoop: while true {
                do {
                    var messageStringComponents: [String] = []
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
                        functions: toolRegistry.functions,
                        toolChoice: toolChoice,
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

            if let malformedCalls = response?.malformedToolCalls, !malformedCalls.isEmpty {
                Self.logger.warning("Response contains \(malformedCalls.count) malformed tool call(s)")

                if response?.functionCalls?.isEmpty ?? true {
                    consecutiveMalformedAttempts += 1
                    Self.logger.error("All tool calls in iteration are malformed. Providing error feedback to model.")

                    for malformedCall in malformedCalls {
                        let errorResult = FunctionCallResult(
                            call: malformedCall.name ?? "unknown_function",
                            result: malformedCall.getErrorFeedback(),
                            type: .error
                        )
                        results.append(errorResult)
                    }

                    if consecutiveMalformedAttempts >= maxConsecutiveMalformed {
                        Self.logger.error("Maximum consecutive malformed attempts (\(maxConsecutiveMalformed)) reached in loop. Breaking.")
                        let errorMessage = """
After \(maxConsecutiveMalformed) consecutive attempts, the model continues to produce malformed tool calls.

Recent errors:
\(malformedCalls.map { "- \($0.name ?? "unknown"): \($0.errorDescription)" }.joined(separator: "\n"))

Please try rephrasing your request or contact support if the issue persists.
"""
                        return LlamaServer.CompleteResponse(
                            text: errorMessage,
                            startTime: response?.startTime ?? initialResponse.startTime,
                            endTime: .now,
                            responseStartSeconds: response?.responseStartSeconds ?? 0,
                            predictedPerSecond: response?.predictedPerSecond,
                            modelName: response?.modelName,
                            usage: response?.usage,
                            usedServer: response?.usedServer ?? false,
                            availableFunctions: toolRegistry.functions,
                            malformedToolCalls: malformedCalls,
                        )
                    }
                } else {
                    Self.logger.info("Some tool calls succeeded in iteration, adding error feedback for malformed ones")
                    for malformedCall in malformedCalls {
                        let errorResult = FunctionCallResult(
                            call: malformedCall.name ?? "unknown_function",
                            result: malformedCall.getErrorFeedback(),
                            type: .error
                        )
                        results.append(errorResult)
                    }
                    consecutiveMalformedAttempts = 0
                }
            } else if response?.functionCalls?.isEmpty ?? true {
                consecutiveMalformedAttempts = 0
            } else {
                consecutiveMalformedAttempts = 0
            }

            maxIterations -= 1
        }
        // Switch status to show stream for final answer
        self.status = .processing
        // Get reason for finishing
        let finishReason: FinishReason = maxIterations == 0 ? .maxIterationsReached : .noFunctionCall
        if finishReason == .noFunctionCall, let response = response {
            if response.text.reasoningRemoved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !results.isEmpty {
                Self.logger.error("Tool calling stopped without a final assistant response. Falling back to explicit final synthesis.")
                return try await self.getFinalResponseAfterFunctionLoop(
                    canReachRemoteServer: canReachRemoteServer,
                    messages: messages,
                    results: results,
                    functionCallRecords: functionCallRecords,
                    enableThinking: enableThinking,
                    showPreview: showPreview,
                    handleResponseUpdate: handleResponseUpdate,
                    increment: increment
                )
            }
            return response
        } else {
            // Else, fall back on one-shot answer
            Self.logger.error("Maximum number of function calls reached. Falling back to one-shot answer.")
            return try await self.getFinalResponseAfterFunctionLoop(
                canReachRemoteServer: canReachRemoteServer,
                messages: messages,
                results: results,
                functionCallRecords: functionCallRecords,
                enableThinking: enableThinking,
                showPreview: showPreview,
                handleResponseUpdate: handleResponseUpdate,
                increment: increment
            )
        }
        // An enum of reasons for finishing
        enum FinishReason {
            case noFunctionCall, maxIterationsReached
        }
    }

    private func getFinalResponseAfterFunctionLoop(
        canReachRemoteServer: Bool,
        messages: [Message.MessageSubset],
        results: [FunctionCallResult],
        functionCallRecords: [FunctionCallRecord],
        enableThinking: Bool?,
        showPreview: Bool,
        handleResponseUpdate: @escaping (
            String,
            String
        ) -> Void,
        increment: Int
    ) async throws -> LlamaServer.CompleteResponse {
        var messages = messages
        var results = results
        var compressionAttempts = 0

        retryLoop: while true {
            let finalPrompt = await self.makeFinalFunctionLoopPrompt(
                results: results
            )
            let finalMessage = Message(
                text: finalPrompt,
                sender: .user
            )
            let finalMessageSubset = await Message.MessageSubset(
                usingRemoteModel: self.wasRemoteServerAccessible,
                message: finalMessage
            )
            if messages.last?.role == .user {
                messages[messages.count - 1] = finalMessageSubset
            } else {
                messages.append(finalMessageSubset)
            }

            var updateResponse: String = ""
            self.pendingMessage?.text = updateResponse

            do {
                var response = try await self.mainModelServer.getChatCompletion(
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
                response.functionCallRecords = functionCallRecords
                return response
            } catch let error as LlamaServerError {
                if case .contextWindowExceeded = error,
                   InferenceSettings.enableContextCompression,
                   compressionAttempts < 3 {
                    compressionAttempts += 1
                    Self.logger.warning("Context window exceeded during final synthesis (attempt \(compressionAttempts)). Compressing tool results.")
                    results = try await ContextCompressor.compressFunctionResults(
                        results,
                        threshold: InferenceSettings.compressionTokenThreshold
                    )
                    continue retryLoop
                }
                throw error
            }
        }
    }

    private func makeFinalFunctionLoopPrompt(
        results: [FunctionCallResult]
    ) async -> String {
        var messageStringComponents: [String] = results.map(\.description)
        if let todoSummary = TodoFunctions.getIncompleteTodoSummary() {
            messageStringComponents.append(todoSummary)
        }
        messageStringComponents.append(
            """
            Use the tool results above to answer the user's original request now. Do not call another tool. If some tool calls failed or information is incomplete, say what you can conclude and what is missing.
            """
        )
        return messageStringComponents.joined(separator: "\n\n")
    }

    private struct PlannedFunctionCall {
        let originalIndex: Int
        let recordIndex: Int
        let callDescription: String
        let call: any DecodableFunctionCall
    }

    private struct ExecutedFunctionCall {
        let originalIndex: Int
        let recordIndex: Int
        let functionCallRecord: FunctionCallRecord
        let result: FunctionCallResult
        let toolMessage: Message.MessageSubset?
    }

    private struct FunctionExecutionOutput {
        let results: [FunctionCallResult]
        let toolMessages: [Message.MessageSubset]
        let functionCallRecords: [FunctionCallRecord]
    }

    private func executeFunctionCalls(
        _ functionCalls: [any DecodableFunctionCall],
        using toolRegistry: ToolRegistry,
        existingRecords: [FunctionCallRecord]
    ) async -> FunctionExecutionOutput {
        var functionCallRecords = existingRecords
        let existingRecordsCount = existingRecords.count
        let plannedCalls: [PlannedFunctionCall] = functionCalls.enumerated().map { index, functionCall in
            let callDescription = "\(functionCall.name)(\(functionCall.getArgumentsJSONString()))"
            Self.logger.info("Executing function call: \(callDescription, privacy: .public)")
            // Anchor against the pre-append count so we don't
            // double-count the slot we're about to add. The previous
            // formulation (`functionCallRecords.count + index`)
            // grew by 2 per iteration and produced out-of-range
            // writes whenever ≥2 calls executed in parallel.
            let recordIndex = existingRecordsCount + index
            let functionCallRecord = FunctionCallRecord(name: functionCall.name)
            functionCallRecords.append(functionCallRecord)
            return PlannedFunctionCall(
                originalIndex: index,
                recordIndex: recordIndex,
                callDescription: callDescription,
                call: functionCall
            )
        }

        withAnimation(.linear) {
            self.pendingMessage?.functionCallRecords = functionCallRecords
            self.pendingMessage?.text = ""
        }
        await Task.yield()

        var executedCalls: [ExecutedFunctionCall] = []
        var batchStartIndex = 0
        while batchStartIndex < plannedCalls.count {
            let currentCall = plannedCalls[batchStartIndex]
            let isParallelSafe = toolRegistry.function(named: currentCall.call.name)?.allowsParallelExecution ?? false
            var batchEndIndex = batchStartIndex + 1
            if isParallelSafe {
                while batchEndIndex < plannedCalls.count,
                      toolRegistry.function(named: plannedCalls[batchEndIndex].call.name)?.allowsParallelExecution ?? false {
                    batchEndIndex += 1
                }
            }
            let batch = Array(plannedCalls[batchStartIndex..<batchEndIndex])
            let batchResults = await self.executeFunctionCallBatch(
                batch,
                using: toolRegistry
            )
            executedCalls += batchResults
            batchStartIndex = batchEndIndex
        }

        for executedCall in executedCalls {
            functionCallRecords[executedCall.recordIndex] = executedCall.functionCallRecord
        }

        withAnimation(.linear) {
            self.pendingMessage?.functionCallRecords = functionCallRecords
        }

        let orderedCalls = executedCalls.sorted(by: { $0.originalIndex < $1.originalIndex })
        return FunctionExecutionOutput(
            results: orderedCalls.map(\.result),
            toolMessages: orderedCalls.compactMap(\.toolMessage),
            functionCallRecords: functionCallRecords
        )
    }

    private func executeFunctionCallBatch(
        _ plannedCalls: [PlannedFunctionCall],
        using toolRegistry: ToolRegistry
    ) async -> [ExecutedFunctionCall] {
        if plannedCalls.count <= 1 {
            guard let plannedCall = plannedCalls.first else {
                return []
            }
            return [await self.executeSingleFunctionCall(plannedCall, using: toolRegistry)]
        }

        return await withTaskGroup(of: ExecutedFunctionCall.self) { group in
            for plannedCall in plannedCalls {
                group.addTask {
                    return await self.executeSingleFunctionCall(
                        plannedCall,
                        using: toolRegistry
                    )
                }
            }

            var executedCalls: [ExecutedFunctionCall] = []
            for await executedCall in group {
                executedCalls.append(executedCall)
            }
            return executedCalls
        }
    }

    private func executeSingleFunctionCall(
        _ plannedCall: PlannedFunctionCall,
        using toolRegistry: ToolRegistry
    ) async -> ExecutedFunctionCall {
        var functionCall = plannedCall.call
        var functionCallRecord = FunctionCallRecord(name: functionCall.name)
        do {
            let result: String = try await functionCall.call(using: toolRegistry) ?? "Function evaluated successfully"
            functionCallRecord.markAsFinished(
                status: .succeeded,
                result: result
            )
            let functionResult = FunctionCallResult(
                call: plannedCall.callDescription,
                result: result,
                type: .result
            )
            let toolMessage = functionCall.toolCallID.map {
                Message.MessageSubset.toolResult(
                    toolCallID: $0,
                    content: result
                )
            }
            return ExecutedFunctionCall(
                originalIndex: plannedCall.originalIndex,
                recordIndex: plannedCall.recordIndex,
                functionCallRecord: functionCallRecord,
                result: functionResult,
                toolMessage: toolMessage
            )
        } catch {
            let errorDescription: String = error.localizedDescription
            functionCallRecord.markAsFinished(
                status: .failed,
                result: errorDescription
            )
            let functionResult = FunctionCallResult(
                call: plannedCall.callDescription,
                result: errorDescription,
                type: .error
            )
            let toolMessage = functionCall.toolCallID.map {
                Message.MessageSubset.toolResult(
                    toolCallID: $0,
                    content: errorDescription
                )
            }
            return ExecutedFunctionCall(
                originalIndex: plannedCall.originalIndex,
                recordIndex: plannedCall.recordIndex,
                functionCallRecord: functionCallRecord,
                result: functionResult,
                toolMessage: toolMessage
            )
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
            self.pendingMessage?.lastUpdated = .now
        }
    }

}

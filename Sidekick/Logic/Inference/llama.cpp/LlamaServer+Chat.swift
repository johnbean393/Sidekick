//
//  LlamaServer+Chat.swift
//  Sidekick
//
//  Created by Bean John on 10/9/24.
//

import EventSource
import Foundation
import FSKit_macOS
import OSLog
import SimilaritySearchKit

extension LlamaServer {
    
    /// Function to retry an operation on network failures
    /// - Parameters:
    ///   - maxRetries: Maximum number of retry attempts
    ///   - operation: The async operation to retry
    /// - Returns: The result of the operation
    /// - Throws: The last error encountered if all retries fail
    func retryOnNetworkError<T>(
        maxRetries: Int = 3,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        
        for attempt in 0...maxRetries {
            do {
                return try await operation()
            } catch let error as LlamaServerError {
                lastError = error
                // Never retry if cancelled
                if case .cancelled = error {
                    throw error
                }
                // Only retry if it's a network error and we haven't exhausted retries
                if error.isRetryable && attempt < maxRetries {
                    Self.logger.warning("Network error on attempt \(attempt + 1)/\(maxRetries + 1). Retrying...")
                    continue
                } else {
                    throw error
                }
            } catch {
                // Non-retryable error, throw immediately
                throw error
            }
        }
        
        // If we exhausted all retries, throw the last error
        throw lastError ?? LlamaServerError.errorResponse("Unknown error after retries")
    }
    
    /// Function to get a chat completion from the LLM
    /// - Parameters:
    ///   - modelType: The type of model used for completion
    ///   - mode: The chat completion mode. This controls whether advanced features like resource lookup is used
    ///   - messages: A list of prior messages
    ///   - similarityIndex: A similarity index for resource lookup
    ///   - progressHandler: A handler called after a new token is generated
    /// - Returns: The response returned from the inference server
    public func getChatCompletion(
        mode: Model.Mode,
        canReachRemoteServer: Bool,
        messages: [Message.MessageSubset],
        useWebSearch: Bool = false,
        useFunctions: Bool = false,
        functions: [AnyFunctionBox]? = nil,
        expert: Expert? = nil,
        enableThinking: Bool? = nil,
        updateStatusHandler: (@Sendable (Model.Status) async -> Void)? = nil,
        progressHandler: (@Sendable (String) -> Void)? = nil
    ) async throws -> CompleteResponse {
        // Wrap the actual completion call with retry logic
        return try await retryOnNetworkError {
            try await self.getChatCompletionInternal(
                mode: mode,
                canReachRemoteServer: canReachRemoteServer,
                messages: messages,
                useWebSearch: useWebSearch,
                useFunctions: useFunctions,
                functions: functions,
                expert: expert,
                enableThinking: enableThinking,
                updateStatusHandler: updateStatusHandler,
                progressHandler: progressHandler
            )
        }
    }
    
    /// Internal function to get a chat completion from the LLM (without retry logic)
    /// - Parameters:
    ///   - modelType: The type of model used for completion
    ///   - mode: The chat completion mode. This controls whether advanced features like resource lookup is used
    ///   - messages: A list of prior messages
    ///   - similarityIndex: A similarity index for resource lookup
    ///   - progressHandler: A handler called after a new token is generated
    /// - Returns: The response returned from the inference server
    func getChatCompletionInternal(
        mode: Model.Mode,
        canReachRemoteServer: Bool,
        messages: [Message.MessageSubset],
        useWebSearch: Bool = false,
        useFunctions: Bool = false,
        functions: [AnyFunctionBox]? = nil,
        expert: Expert? = nil,
        enableThinking: Bool? = nil,
        updateStatusHandler: (@Sendable (Model.Status) async -> Void)? = nil,
        progressHandler: (@Sendable (String) -> Void)? = nil
    ) async throws -> CompleteResponse {
        // Track this request so it can be cancelled independently
        let requestID = UUID()
        // Get endpoint url & whether server is used
        let rawUrl = await self.url(
            "/chat/completions",
            openAiCompatiblePath: true,
            canReachRemoteServer: canReachRemoteServer
        )
        // Start server if remote server is not used & local server is inactive
        if !rawUrl.usingRemoteServer {
            Self.logger.info("Using local model for inference...")
            try await self.startServer(
                canReachRemoteServer: canReachRemoteServer
            )
        } else {
            Self.logger.info("Using remote model for inference...")
        }
        // Get start time
        let start: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
        // Formulate parameters
        async let params = {
            switch mode {
                case .chat, .agent:
                    return await ChatParameters(
                        modelType: self.modelType,
                        usingRemoteModel: canReachRemoteServer,
                        systemPrompt: self.systemPrompt,
                        messages: messages,
                        useWebSearch: useWebSearch,
                        useFunctions: useFunctions,
                        functions: functions,
                        expert: expert,
                        enableThinking: enableThinking
                    )
                case .deepResearch:
                    return await ChatParameters(
                        modelType: self.modelType,
                        usingRemoteModel: canReachRemoteServer,
                        systemPrompt: self.systemPrompt,
                        messages: messages,
                        useWebSearch: useWebSearch,
                        useFunctions: useFunctions,
                        functions: functions,
                        expert: expert,
                        enableThinking: enableThinking
                    )
                case .default:
                    return await ChatParameters(
                        modelType: self.modelType,
                        usingRemoteModel: canReachRemoteServer,
                        systemPrompt: self.systemPrompt,
                        messages: messages,
                        enableThinking: enableThinking
                    )
            }
        }()
        // Formulate request
        var request = URLRequest(
            url: rawUrl.url
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("keep-alive", forHTTPHeaderField: "Connection")
        if rawUrl.usingRemoteServer {
            request.setValue(
                "Bearer \(InferenceSettings.inferenceApiKey)",
                forHTTPHeaderField: "Authorization"
            )
            request.setValue("nil", forHTTPHeaderField: "ngrok-skip-browser-warning")
        }
        // Formulate request JSON
        let omittedParams: [ChatParameters.ParamKey] = {
            switch mode {
                case .chat, .agent:
                    if !useFunctions {
                        return [.tools]
                    } else {
                        return []
                    }
                case .deepResearch:
                    return []
                case .`default`:
                    return [.tools]
            }
        }()
        let requestJson: String = await params.toJSON(
            usingRemoteModel: rawUrl.usingRemoteServer,
            modelType: self.modelType,
            omittedParams: omittedParams
        )
        request.httpBody = requestJson.data(using: .utf8)
        // Use EventSource to receive server sent events
        let eventSource = EventSource(
            timeoutInterval: 6000 // Timeout after 100 minutes, enough for even reasoning models
        )
        let dataTask = eventSource.dataTask(
            for: request
        )
        let session = URLSession(
            configuration: .default
        )
        let context = ActiveRequestContext(
            id: requestID,
            eventSource: eventSource,
            dataTask: dataTask,
            session: session
        )
        self.activeRequests[requestID] = context
        if self.pendingCancellationForAllRequests {
            context.cancel()
        }
        defer {
            session.invalidateAndCancel()
            self.activeRequests.removeValue(forKey: requestID)
            if self.activeRequests.isEmpty {
                self.pendingCancellationForAllRequests = false
            }
        }
        // Init variables for content
        var pendingMessage: String = ""
        var responseDiff: Double = 0.0
        var wasReasoningToken: Bool = false
        
        // Track tool calls by index
        struct ToolCallAccumulator {
            var name: String?
            var arguments: String = ""
        }
        var toolCalls: [Int: ToolCallAccumulator] = [:] // Dictionary keyed by tool call index
        var blockFunctionCalls: [(any DecodableFunctionCall)] = []
        var toolCallInProgress: Bool = false
        
        // Init variables for usage
        var tokenCount: Int = 0
        var usage: Usage? = nil
        // Init variables for control
        var stopResponse: StopResponse? = nil
        // Start streaming completion events
        listenLoop: for await event in context.dataTask.events() {
            switch event {
                case .open:
                    continue listenLoop
                case .error(let error):
                    // Log error
                    Self.logger.error("Inference server error: \(error, privacy: .public)")
                    // Attempt to detect context window errors from the localized description
                    let errorMessage: String = error.localizedDescription
                    let statusCode: Int? = LlamaServerError.extractStatusCode(from: errorMessage)
                    if LlamaServerError.isContextWindowError(
                        message: errorMessage,
                        code: statusCode
                    ) {
                        throw LlamaServerError.contextWindowExceeded(errorMessage)
                    }
                    // Throw error
                    throw LlamaServerError.errorResponse(errorMessage)
                case .event(let message):
                    // Parse json in message.data string
                    // Then, print the data.content value and append it to response
                    if let data = message.data?.data(using: .utf8) {
                        let decoder = JSONDecoder()
                        do {
                            // Log response object
                            if let responseStr = String(data: data, encoding: .utf8) {
                                Self.logger.info("Received response object: \(responseStr, privacy: .public)")
                            }
                            // Decode response object
                            let responseObj: StreamResponse = try decoder.decode(
                                StreamResponse.self,
                                from: data
                            )
                            // Check for error in response
                            if let error = responseObj.error {
                                Self.logger.error("Received error in response: \(error.message, privacy: .public), code: \(error.code ?? -1, privacy: .public)")
                                if LlamaServerError.isContextWindowError(message: error.message, code: error.code, metadata: error.metadata) {
                                    throw LlamaServerError.contextWindowExceeded(error.message)
                                } else if error.isNetworkError {
                                    throw LlamaServerError.networkError(error.message)
                                } else {
                                    throw LlamaServerError.errorResponse(error.message)
                                }
                            }
                            // Run completion handler for update
                            let fragment: String = responseObj.choices.map { choice in
                                // Init variable
                                var choiceContent: String = choice.delta.content ?? ""
                                if let content: String = choice.delta.content,
                                   !content.isEmpty, wasReasoningToken {
                                    // Handle answer token
                                    // If previous token was reasoning token, add end of reasoning token
                                    let hasEndReasoningToken: Bool = String.specialReasoningTokens.contains (where: { tokens in
                                        guard let endReasoningToken: String = tokens.last else {
                                            return false
                                        }
                                        return pendingMessage
                                            .trimmingCharacters(in: .whitespacesAndNewlines)
                                            .contains(
                                                endReasoningToken
                                            )
                                    })
                                    choiceContent = (!hasEndReasoningToken ? "\n</think>\n" : "") + content
                                    wasReasoningToken = false
                                } else if let reasoningContent: String = choice.delta.reasoningContent {
                                    // Handle reasoning token
                                    // If previous token was not reasoning token, add reasoning special token
                                    choiceContent = (
                                        wasReasoningToken ? "" : "<think>\n"
                                    ) + reasoningContent
                                    wasReasoningToken = true
                                }
                                // Return result
                                return choiceContent
                            }.joined()
                            pendingMessage.append(fragment)
                            progressHandler?(fragment)
                            
                            // Handle tool calls properly with multiple indices
                            if let firstChoice = responseObj.choices.first?.delta,
                               let toolCallDeltas = firstChoice.tool_calls {
                                // Show progress (only once when tool call starts)
                                if !toolCallInProgress {
                                    toolCallInProgress = true
                                    if let updateStatusHandler {
                                        await updateStatusHandler(.usingFunctions)
                                    }
                                }
                                
                                // Process each tool call delta
                                for toolCall in toolCallDeltas {
                                    let index = toolCall.index
                                    
                                    // Initialize accumulator for this index if needed
                                    if toolCalls[index] == nil {
                                        toolCalls[index] = ToolCallAccumulator()
                                    }
                                    
                                    // Accumulate function name
                                    if let name = toolCall.function.name {
                                        toolCalls[index]?.name = name
                                    }
                                    
                                    // Accumulate arguments chunks
                                    if let argument = toolCall.function.arguments {
                                        toolCalls[index]?.arguments += argument
                                    }
                                }
                            }
                            
                            // Document usage
                            tokenCount += 1
                            usage = responseObj.usage
                            if responseDiff == 0 {
                                responseDiff = CFAbsoluteTimeGetCurrent() - start
                            }
                            if responseObj.choices.first?.finish_reason != nil {
                                do {
                                    stopResponse = try decoder.decode(StopResponse.self, from: data)
                                } catch {
                                    print("Error decoding stopResponse, listenLoop will continue", error, data.count, "bytes")
                                }
                                break listenLoop
                            }
                        } catch {
                            Self.logger.error("Error decoding response object \(error, privacy: .public)")
                            Self.logger.error("responseObj: \(String(decoding: data, as: UTF8.self), privacy: .public)")
                        }
                    }
                case .closed:
                    Self.logger.notice("EventSource closed")
                    break listenLoop
            }
        }
        // Check if generation was cancelled
        if context.isCancelled {
            Self.logger.notice("Generation was cancelled, not processing tool calls")
            throw LlamaServerError.cancelled
        }
        // Decode all accumulated tool calls AFTER streaming is done
        var malformedToolCalls: [MalformedToolCall] = []
        let sortedIndices = toolCalls.keys.sorted()
        for index in sortedIndices {
            guard let toolCall = toolCalls[index],
                  let name = toolCall.name else {
                // Track tool calls with missing name
                if let toolCall = toolCalls[index] {
                    let malformed = MalformedToolCall(
                        index: index,
                        name: nil,
                        rawArguments: toolCall.arguments,
                        errorDescription: "Tool call is missing a function name"
                    )
                    malformedToolCalls.append(malformed)
                    Self.logger.error("Tool call #\(index) is missing a function name")
                }
                continue
            }
            
            var args = toolCall.arguments
            Self.logger.info("Decoding tool call  \(index): \(name) with args: \(args, privacy: .public)")
            
            // Handle double-wrapped arguments from some APIs
            if let data = args.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let innerArgs = json["arguments"],
               let unwrappedData = try? JSONSerialization.data(withJSONObject: innerArgs),
               let unwrappedString = String(data: unwrappedData, encoding: .utf8) {
                args = unwrappedString
            }
            
            if let function = StreamMessage.OpenAIToolCall.Function.getFunctionCall(
                name: name,
                arguments: args
            ) {
                blockFunctionCalls.append(function)
                Self.logger.info("Successfully decoded tool call #\(index): \(name)")
            } else {
                // Track malformed tool call with detailed error
                let errorDescription: String
                
                // Try to determine the specific error
                if args.isEmpty {
                    errorDescription = "Tool call arguments are empty"
                } else if let data = args.data(using: .utf8) {
                    // Try to parse as JSON to provide better error message
                    do {
                        _ = try JSONSerialization.jsonObject(with: data)
                        // JSON is valid, so the issue is parameter mismatch
                        errorDescription = "Arguments do not match the expected parameter schema for function '\(name)'"
                    } catch {
                        // JSON is invalid
                        errorDescription = "Invalid JSON format: \(error.localizedDescription)"
                    }
                } else {
                    errorDescription = "Arguments could not be decoded as UTF-8 string"
                }
                
                let malformed = MalformedToolCall(
                    index: index,
                    name: name,
                    rawArguments: args,
                    errorDescription: errorDescription
                )
                malformedToolCalls.append(malformed)
                Self.logger.error("Failed to decode tool call #\(index): \(name) - \(errorDescription)")
                Self.logger.error("Raw args: \(args, privacy: .public)")
            }
        }
        
        // Adding a trailing quote or space is a common mistake with the smaller model output
        let cleanText: String = pendingMessage.removeUnmatchedTrailingQuote()
        // Indicate response finished
        if responseDiff > 0 {
            // Call onFinish
            onFinish(text: cleanText)
        }
        // Return info
        let tokens: Int = stopResponse?.usage.completion_tokens ?? (
            usage?.completion_tokens ?? tokenCount
        )
        let generationTime: CFTimeInterval = CFAbsoluteTimeGetCurrent() - start - responseDiff
        let tokensPerSecond: Double = Double(tokens) / generationTime
        let modelName: String = {
            // If not using remote server, return name
            if !rawUrl.usingRemoteServer {
                return self.modelName
            }
            switch self.modelType {
                case .regular:
                    return stopResponse?.model ?? InferenceSettings.serverModelName
                case .worker:
                    return stopResponse?.model ?? InferenceSettings.serverWorkerModelName
                case .completions:
                    return InferenceSettings.completionsModelUrl?.deletingPathExtension().lastPathComponent ?? "Unknown Model"
            }
        }()
        // Log use
        let url: URL? = rawUrl.usingRemoteServer ? rawUrl.url : nil
        let record: InferenceRecord = .init(
            name: modelName,
            startTime: Date(timeIntervalSinceReferenceDate: start),
            type: .chatCompletions,
            endpoint: url,
            inputTokens: stopResponse?.usage.prompt_tokens ?? (usage?.prompt_tokens ?? 0),
            outputTokens: stopResponse?.usage.completion_tokens ?? (usage?.completion_tokens ?? 0),
            tokensPerSecond: tokensPerSecond
        )
        await InferenceRecords.shared.add(record)
        // Return response
        return CompleteResponse(
            text: cleanText,
            responseStartSeconds: responseDiff,
            predictedPerSecond: tokensPerSecond,
            modelName: modelName,
            usage: stopResponse?.usage,
            usedServer: rawUrl.usingRemoteServer,
            blockFunctionCalls: blockFunctionCalls,
            malformedToolCalls: malformedToolCalls.isEmpty ? nil : malformedToolCalls
        )
    }
    
    /// Function to get a completion from the LLM
    /// - Parameter text: The text to complete
    /// - Parameter tokenNumber: The number of tokens to predict
    /// - Returns: A sequence of tokens, each with a probability
    public func getCompletion(
        text: String,
        maxTokenNumber: Int
    ) async -> [Token]? {
        // Formulate request
        let url: URL = URL(
            string: "\(self.scheme)://\(self.host):\(self.port)/v1/completions"
        )!
        var request = URLRequest(
            url: url
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Formulate JSON
        let params: CompletionParams = .init(
            prompt: text,
            max_tokens: maxTokenNumber
        )
        let encoder: JSONEncoder = .init()
        guard let data: Data = try? encoder.encode(params) else {
            return nil
        }
        let requestJson: String = String(
            data: data,
            encoding: .utf8
        )!
        request.httpBody = requestJson.data(using: .utf8)
        // Formulate session
        let urlSession: URLSession = URLSession.shared
        urlSession.configuration.waitsForConnectivity = false
        urlSession.configuration.timeoutIntervalForRequest = 10
        urlSession.configuration.timeoutIntervalForResource = 10
        // Log start time
        let startTime: Date = Date.now
        // Get JSON response
        guard let (data, _): (Data, URLResponse) = try? await URLSession.shared.data(
            for: request
        ) else {
            Self.logger.error("Failed to generate completion.")
            return nil
        }
        // Log response object
        if let responseStr = String(data: data, encoding: .utf8) {
            Self.logger.info("Received response object: \(responseStr, privacy: .public)")
        }
        // Decode response
        let decoder: JSONDecoder = .init()
        guard let response: CompletionResponse = try? decoder.decode(
            CompletionResponse.self,
            from: data
        ) else {
            Self.logger.error("Failed to decode completion response.")
            return nil
        }
        // Log
        let timeElapsed: Double = Date.now.timeIntervalSince(
            startTime
        )
        let tokensPerSecond: Double = Double(
            response.usage.completion_tokens ?? 0
        ) / timeElapsed
        let record: InferenceRecord = .init(
            name: modelName,
            startTime: startTime,
            type: .completions,
            inputTokens: response.usage.prompt_tokens ?? 0,
            outputTokens: response.usage.completion_tokens ?? 0,
            tokensPerSecond: tokensPerSecond
        )
        await InferenceRecords.shared.add(record)
        // Extract and return
        let content = response.choices.first?.logprobs.content
        return content
    }
    
}

// MARK: - Streaming Types

extension LlamaServer {
    
    struct StreamMessage: Codable {
        
        /// The new token generated, decoded to type `String?`
        let content: String?
        
        /// The new reasoning token generated, decoded to type `String?`, for OpenRouter
        let reasoning: String?
        /// The new reasoning token generated, decoded to type `String?`, for Bailian
        let reasoning_content: String?
        
        /// The new reasoning token generated, if available
        var reasoningContent: String? {
            if let reasoning = self.reasoning,
               !reasoning.isEmpty {
                return reasoning
            } else if let reasoning_content = self.reasoning_content,
                      !reasoning_content.isEmpty {
                return reasoning_content
            } else {
                return nil
            }
        }
        
        /// A list of ``ToolCalls``, if it exists
        var tool_calls: [OpenAIToolCall]?
        
        struct OpenAIToolCall: Codable {
            
            var index: Int
            var id: String?
            var type: String?
            
            var function: Function
            
            struct Function: Codable {
                
                var name: String?
                var arguments: String?
                
                /// Function to get the corresponding function call
                public static func getFunctionCall(
                    name: String,
                    arguments: String
                ) -> (any DecodableFunctionCall)? {
                    // Try to init each function type
                    for function in DefaultFunctions.sortedFunctions {
                        // If function name matches
                        if function.name == name {
                            // Try to formulate arguments
                            let decoder: JSONDecoder = JSONDecoder()
                            
                            // Attempt to decode with original arguments first
                            if let result = Self.tryDecode(
                                arguments: arguments,
                                function: function,
                                decoder: decoder
                            ) {
                                return result
                            }
                            
                            // Try automatic recovery for common JSON issues
                            let recoveryAttempts = Self.getRecoveryAttempts(for: arguments)
                            for recoveredArgs in recoveryAttempts {
                                if let result = Self.tryDecode(
                                    arguments: recoveredArgs,
                                    function: function,
                                    decoder: decoder
                                ) {
                                    LlamaServer.logger.info("Successfully recovered malformed arguments for '\(name)' using automatic correction")
                                    return result
                                }
                            }
                        }
                    }
                    // If failed to init, return nil
                    return nil
                }
                
                /// Helper to attempt decoding with given arguments
                private static func tryDecode(
                    arguments: String,
                    function: any AnyFunctionBox,
                    decoder: JSONDecoder
                ) -> (any DecodableFunctionCall)? {
                    guard let data = arguments.data(using: .utf8),
                          let params = try? decoder.decode(function.paramsType.self, from: data) else {
                        return nil
                    }
                    return function.functionCallType.init(name: function.name, params: params)
                }
                
                /// Generate recovery attempts for common JSON errors
                private static func getRecoveryAttempts(for arguments: String) -> [String] {
                    var attempts: [String] = []
                    let cleaned = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    // 1. Remove trailing commas before closing braces/brackets
                    let trailingCommaPattern = #",(\s*[}\]])"#
                    if let regex = try? NSRegularExpression(pattern: trailingCommaPattern) {
                        let range = NSRange(cleaned.startIndex..., in: cleaned)
                        let fixed = regex.stringByReplacingMatches(
                            in: cleaned,
                            range: range,
                            withTemplate: "$1"
                        )
                        if fixed != cleaned {
                            attempts.append(fixed)
                        }
                    }
                    
                    // 2. Wrap in braces if missing (for single-parameter functions)
                    if !cleaned.hasPrefix("{") {
                        attempts.append("{\(cleaned)}")
                    }
                    
                    // 3. Fix common boolean representations
                    let booleanMappings = [
                        ("True", "true"),
                        ("False", "false"),
                        ("None", "null"),
                        ("nil", "null")
                    ]
                    for (wrong, correct) in booleanMappings {
                        if cleaned.contains(wrong) {
                            let fixed = cleaned.replacingOccurrences(of: wrong, with: correct)
                            if fixed != cleaned {
                                attempts.append(fixed)
                            }
                        }
                    }
                    
                    // 4. Fix single quotes to double quotes (common Python-style mistake)
                    if cleaned.contains("'") {
                        let fixed = cleaned.replacingOccurrences(of: "'", with: "\"")
                        attempts.append(fixed)
                    }
                    
                    // 5. Empty object if arguments are completely empty or whitespace
                    if cleaned.isEmpty {
                        attempts.append("{}")
                    }
                    
                    return attempts
                }
                
            }
            
        }
    }
    
    struct StreamChoice: Codable {
        
        /// The new token generated, as a ``StreamMessage``
        let delta: StreamMessage
        /// The reason for finishing generation; returns `nil` if completion is not finished
        let finish_reason: String?
        
    }
    
    struct StreamResponse: Codable {
        
        let choices: [StreamChoice]
        let created: Double
        let usage: Usage?
        let error: ResponseError?
        
        /// A structure modeling error information in the response
        struct ResponseError: Codable {
            let message: String
            let code: Int?
            let metadata: [String: String]?
            
            /// Check if this is a network error (5xx status codes)
            var isNetworkError: Bool {
                guard let code = code else { return false }
                return code >= 500 && code < 600
            }
        }
        
    }
    
    struct Usage: Codable {
        
        let completion_tokens: Int?
        let prompt_tokens: Int?
        let total_tokens: Int?
        
    }
    
    struct StopResponse: Codable {
        
        let model: String
        let usage: Usage
        
    }
    
    public struct CompleteResponse {
        
        var text: String
        var responseStartSeconds: Double
        var predictedPerSecond: Double?
        var modelName: String?
        /// A `Usage` object containing the number of tokens used, among other stats
        var usage: Usage?
        /// A `Bool` indicating whether a remote server was used
        var usedServer: Bool
        
        /// An array of ``FunctionCallRecord`` executed in the response
        var functionCallRecords: [FunctionCallRecord] = []
        /// A `Bool` representing if a function was called
        var containsFunctionCall: Bool {
            if let functionCalls = self.functionCalls,
               !functionCalls.isEmpty {
                return true
            }
            return false
        }
        /// Any function call in the response
        var functionCalls: [(any DecodableFunctionCall)]? {
            // Try to get block call first
            if let blockFunctionCalls = self.blockFunctionCalls,
               !blockFunctionCalls.isEmpty {
                return blockFunctionCalls
            }
            return self.inlineFunctionCalls
        }
        /// A function call in the response JSON
        var blockFunctionCalls: [(any DecodableFunctionCall)]?
        /// Malformed tool calls that failed to parse
        var malformedToolCalls: [MalformedToolCall]?
        /// All inline function call found in the text
        var inlineFunctionCalls: [(any DecodableFunctionCall)]? {
            // Configure input
            let input: String = self.text.reasoningRemoved
            // Init decoder
            let decoder = JSONDecoder()
            // Decode
            return Self.decodeAllFunctionCalls(
                in: input,
                decoder: decoder
            )
        }
        
        /// Function to decode all function calls
        private static func decodeAllFunctionCalls(
            in input: String,
            decoder: JSONDecoder,
            searchStartIndex: String.Index? = nil
        ) -> [(any DecodableFunctionCall)]? {
            var results: [(any DecodableFunctionCall)] = []
            let startIdx = searchStartIndex ?? input.startIndex
            var searchStartIndex = startIdx
            // Look for every occurrence of '{'
            while let startIndex = input[searchStartIndex...].firstIndex(of: "{") {
                var braceCount = 0
                var currentIndex = startIndex
                var insideString = false
                var previousChar: Character? = nil
                var endIndex: String.Index? = nil
                // Attempt to balance the braces from here
                while currentIndex < input.endIndex {
                    let character = input[currentIndex]
                    // Toggle whether we're inside a string, ignoring escaped quotes
                    if character == "\"" && previousChar != "\\" {
                        insideString.toggle()
                    }
                    // Only process braces if we're not inside a string literal
                    if !insideString {
                        if character == "{" {
                            braceCount += 1
                        } else if character == "}" {
                            braceCount -= 1
                            if braceCount == 0 {
                                endIndex = currentIndex
                                break
                            }
                        }
                    }
                    previousChar = character
                    currentIndex = input.index(after: currentIndex)
                }
                // If we found matching braces, attempt to decode
                if let finalIndex = endIndex {
                    let jsonSubstring = input[startIndex...finalIndex]
                    let jsonString = String(jsonSubstring)
                    if let jsonData = jsonString.data(using: .utf8) {
                        // Try for all function types
                        for function in DefaultFunctions.sortedFunctions {
                            if let functionCall = function.functionCallType.parse(
                                from: jsonData,
                                using: decoder
                            ), jsonString.contains(
                                "\"\(function.name)\""
                            ) {
                                results.append(functionCall)
                                break
                            }
                        }
                    }
                    // Move searchStartIndex past this function call for the next iteration
                    searchStartIndex = input.index(after: finalIndex)
                } else {
                    // If we didn't find a matching '}', break the loop
                    break
                }
            }
            return results.isEmpty ? nil : results
        }
        
    }
    
    struct CompletionParams: Codable {
        
        var prompt: String
        var max_tokens: Int
        var logprobs: Int = 1
        var temperature: Double = 0.0
        
    }
    
    struct CompletionResponse: Codable {
        
        var completion: String? {
            return choices.first?.text
        }
        var logprob: Double? {
            return choices.first?.logprob
        }
        
        var choices: [Choice]
        
        var usage: Usage
        
        struct Choice: Codable {
            
            var text: String
            
            var logprobs: Logprob
            var logprob: Double {
                return self.logprobs.content
                    .map(keyPath: \.logprob)
                    .reduce(0, +)
            }
            
            struct Logprob: Codable {
                
                var content: [Token]
                
            }
            
        }
        
    }
    
    public struct Token: Codable {
        
        var token: String
        var logprob: Double
        
    }
    
}

extension EventSource.DataTask: @unchecked Sendable {  }


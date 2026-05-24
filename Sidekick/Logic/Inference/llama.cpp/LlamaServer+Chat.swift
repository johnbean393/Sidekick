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
        toolChoice: ChatParameters.ToolChoice? = nil,
        expert: Expert? = nil,
        enableThinking: Bool? = nil,
        requestIDHandler: (@Sendable (UUID) async -> Void)? = nil,
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
                toolChoice: toolChoice,
                expert: expert,
                enableThinking: enableThinking,
                requestIDHandler: requestIDHandler,
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
        toolChoice: ChatParameters.ToolChoice? = nil,
        expert: Expert? = nil,
        enableThinking: Bool? = nil,
        requestIDHandler: (@Sendable (UUID) async -> Void)? = nil,
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
        let resolvedFunctions: [AnyFunctionBox]
        if let functions {
            resolvedFunctions = functions
        } else if useFunctions {
            resolvedFunctions = await MainActor.run {
                FunctionSelection.getEnabledFunctions()
            }
        } else {
            resolvedFunctions = []
        }
        let toolRegistry = ToolRegistry(functions: resolvedFunctions)
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
                        functions: resolvedFunctions.isEmpty ? nil : resolvedFunctions,
                        toolChoice: toolChoice,
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
                        functions: resolvedFunctions.isEmpty ? nil : resolvedFunctions,
                        toolChoice: toolChoice,
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
        let startTime = Date(timeIntervalSinceReferenceDate: start)
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
        if let requestIDHandler {
            await requestIDHandler(requestID)
        }
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
            var id: String?
            var name: String?
            var arguments: String = ""
        }
        var toolCalls: [Int: ToolCallAccumulator] = [:] // Dictionary keyed by tool call index
        var functionCalls: [(any DecodableFunctionCall)] = []
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
                            // Run completion handler for update.
                            //
                            // A single chunk can carry reasoning, content, or
                            // both (OpenRouter occasionally emits a flush
                            // chunk with both fields when transitioning from
                            // thinking to answering). We therefore handle
                            // each field independently rather than picking
                            // one via `if/else if` — the old logic would drop
                            // `content` whenever a chunk also carried
                            // reasoning, which is how Gemini 3+ thought
                            // summaries were silently swallowing the final
                            // answer.
                            let fragment: String = responseObj.choices.map { choice in
                                var fragment: String = ""
                                // 1. Reasoning fragment, if any.
                                if let reasoningContent: String = choice.delta.reasoningContent {
                                    // Open a `<think>` block on the first
                                    // reasoning token only.
                                    if !wasReasoningToken {
                                        fragment += "<think>\n"
                                    }
                                    fragment += reasoningContent
                                    wasReasoningToken = true
                                }
                                // 2. Answer fragment, if any.
                                if let content: String = choice.delta.content,
                                   !content.isEmpty {
                                    if wasReasoningToken {
                                        // Close the `<think>` block before
                                        // we start streaming the answer, but
                                        // only if the model itself hasn't
                                        // already emitted an end-of-reason
                                        // marker (some llama.cpp templates
                                        // inline `</think>` themselves).
                                        let alreadyClosed: Bool = String.specialReasoningTokens.contains(where: { tokens in
                                            guard let endReasoningToken: String = tokens.last else {
                                                return false
                                            }
                                            let combined = pendingMessage + fragment
                                            return combined
                                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                                .contains(endReasoningToken)
                                        })
                                        if !alreadyClosed {
                                            fragment += "\n</think>\n"
                                        }
                                        wasReasoningToken = false
                                    }
                                    fragment += content
                                }
                                return fragment
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

                                    if let id = toolCall.id {
                                        toolCalls[index]?.id = id
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
        // If the stream ended while we were still inside a `<think>` block,
        // synthesise the closing tag so `Message.reasoningText` /
        // `.responseText` can still locate the trace once `outputEnded` flips
        // to true. Without this, models that emit only thought summaries and
        // no final answer (e.g. Gemini 3+ when the answer budget is
        // exhausted by thinking) would drop the reasoning entirely from the
        // UI.
        if wasReasoningToken {
            let alreadyClosed: Bool = String.specialReasoningTokens.contains(where: { tokens in
                guard let endReasoningToken: String = tokens.last else {
                    return false
                }
                return pendingMessage
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .contains(endReasoningToken)
            })
            if !alreadyClosed {
                let closer = "\n</think>\n"
                pendingMessage.append(closer)
                progressHandler?(closer)
            }
            wasReasoningToken = false
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
                arguments: args,
                toolCallID: toolCall.id,
                toolRegistry: toolRegistry
            ) {
                functionCalls.append(function)
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

        // Fallback: recover tool calls that leaked into the content stream as
        // Qwen3-Coder-style XML (<tool_call><function=NAME><parameter=KEY>VALUE</parameter></function></tool_call>).
        // llama-server's `--jinja` parser is unreliable for this format,
        // especially after the first batch of calls in a multi-turn agentic
        // loop. We mirror LM Studio's approach by parsing leaks client-side.
        let recovered = Self.extractCoderXMLToolCalls(
            from: pendingMessage,
            toolRegistry: toolRegistry,
            existingCalls: functionCalls
        )
        if !recovered.calls.isEmpty {
            Self.logger.info("Recovered \(recovered.calls.count) Coder-XML tool call(s) from content stream")
            functionCalls.append(contentsOf: recovered.calls)
            pendingMessage = recovered.strippedText
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
        await MainActor.run { InferenceRecords.record(record) }
        // Return response
        return CompleteResponse(
            text: cleanText,
            startTime: startTime,
            endTime: .now,
            responseStartSeconds: responseDiff,
            predictedPerSecond: tokensPerSecond,
            modelName: modelName,
            usage: stopResponse?.usage,
            usedServer: rawUrl.usingRemoteServer,
            availableFunctions: resolvedFunctions,
            functionCalls: functionCalls,
            malformedToolCalls: malformedToolCalls.isEmpty ? nil : malformedToolCalls
        )
    }

    /// Recover tool calls emitted in Qwen3-Coder-style XML that leaked into
    /// the assistant's content stream.
    ///
    /// `llama-server`'s `--jinja` parser does not reliably extract every
    /// `<tool_call>` block, particularly on the second+ turn of an agentic
    /// loop. This scanner mirrors what LM Studio's `autoparser` does in C++:
    /// look for `<tool_call><function=NAME>[<parameter=KEY>VALUE</parameter>]*</function></tool_call>`
    /// patterns, build a JSON argument blob, and decode via the existing
    /// `ToolRegistry` path so the agent loop can execute them like native
    /// tool calls.
    ///
    /// - Parameters:
    ///   - text: The full assistant text accumulated from the stream.
    ///   - toolRegistry: The registry used to validate decoded function names.
    ///   - existingCalls: Calls already decoded from the native `tool_calls`
    ///     deltas. We skip XML matches whose `(name, arguments)` already exist
    ///     here so we never double-count.
    /// - Returns: The recovered calls and the input text with successfully
    ///   recovered XML stripped out (so the UI doesn't render raw XML).
    static func extractCoderXMLToolCalls(
        from text: String,
        toolRegistry: ToolRegistry,
        existingCalls: [any DecodableFunctionCall]
    ) -> (calls: [any DecodableFunctionCall], strippedText: String) {
        guard text.contains("<tool_call>") && text.contains("<function=") else {
            return ([], text)
        }
        // Whitespace-tolerant tag matching. The model frequently substitutes
        // spaces for the template's newlines, so `\s*` everywhere is intentional.
        let callPattern = #"<tool_call>\s*<function\s*=\s*([^>\s]+)\s*>([\s\S]*?)</function>\s*</tool_call>"#
        let paramPattern = #"<parameter\s*=\s*([^>\s]+)\s*>([\s\S]*?)</parameter>"#
        guard let callRegex = try? NSRegularExpression(pattern: callPattern),
              let paramRegex = try? NSRegularExpression(pattern: paramPattern) else {
            return ([], text)
        }
        let nsText = text as NSString
        let matches = callRegex.matches(
            in: text,
            range: NSRange(location: 0, length: nsText.length)
        )
        guard !matches.isEmpty else {
            return ([], text)
        }
        // Pre-compute canonical (name, argsJSON) signatures for existing calls
        // so we can dedupe against anything llama.cpp already extracted natively.
        let existingSignatures: Set<String> = Set(existingCalls.map { call in
            "\(call.name)|\(call.getArgumentsJSONString())"
        })
        var recovered: [any DecodableFunctionCall] = []
        var rangesToStrip: [NSRange] = []
        for match in matches {
            guard match.numberOfRanges >= 3 else { continue }
            let name = nsText.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let body = nsText.substring(with: match.range(at: 2))
            // Parse each <parameter=KEY>VALUE</parameter> child.
            var arguments: [String: Any] = [:]
            let bodyNS = body as NSString
            let paramMatches = paramRegex.matches(
                in: body,
                range: NSRange(location: 0, length: bodyNS.length)
            )
            for paramMatch in paramMatches {
                guard paramMatch.numberOfRanges >= 3 else { continue }
                let key = bodyNS.substring(with: paramMatch.range(at: 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let rawValue = bodyNS.substring(with: paramMatch.range(at: 2))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                arguments[key] = Self.coerceXMLParameterValue(rawValue)
            }
            guard JSONSerialization.isValidJSONObject(arguments),
                  let argsData = try? JSONSerialization.data(
                      withJSONObject: arguments,
                      options: [.sortedKeys]
                  ),
                  let argsJSON = String(data: argsData, encoding: .utf8) else {
                Self.logger.warning("XML fallback: could not serialize args for \(name, privacy: .public)")
                continue
            }
            // Skip if this exact call already arrived natively.
            if existingSignatures.contains("\(name)|\(argsJSON)") {
                rangesToStrip.append(match.range)
                continue
            }
            if let call = StreamMessage.OpenAIToolCall.Function.getFunctionCall(
                name: name,
                arguments: argsJSON,
                toolCallID: UUID().uuidString,
                toolRegistry: toolRegistry
            ) {
                recovered.append(call)
                rangesToStrip.append(match.range)
            } else {
                Self.logger.warning("XML fallback: could not decode \(name, privacy: .public) with args \(argsJSON, privacy: .public)")
            }
        }
        // Strip extracted XML so the UI doesn't render it. Iterate in reverse
        // so earlier ranges stay valid as we mutate the string.
        var stripped = text
        for nsRange in rangesToStrip.sorted(by: { $0.location > $1.location }) {
            if let range = Range(nsRange, in: stripped) {
                stripped.removeSubrange(range)
            }
        }
        // Collapse the empty gaps left behind by stripped blocks.
        stripped = stripped.replacingOccurrences(
            of: #"\n{3,}"#,
            with: "\n\n",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return (recovered, stripped)
    }

    /// Best-effort coercion of an XML `<parameter>` value into a JSON-native
    /// type. Numbers, booleans, null, arrays, and objects are interpreted as
    /// JSON. Everything else stays a string so it survives `JSONSerialization`.
    private static func coerceXMLParameterValue(_ raw: String) -> Any {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(
               with: data,
               options: [.fragmentsAllowed]
           ) {
            switch json {
                case is NSNumber, is [Any], is [String: Any]:
                    return json
                case let bool as Bool:
                    return bool
                case is NSNull:
                    return NSNull()
                default:
                    break
            }
        }
        return trimmed
    }

}

// MARK: - Streaming Types

extension LlamaServer {

    struct StreamMessage: Codable {

        /// The new token generated, decoded to type `String?`
        let content: String?

        /// The new reasoning token generated, decoded to type `String?`, for OpenRouter
        let reasoning: String?
        /// The new reasoning token generated, decoded to type `String?`, for Bailian / DeepSeek / Gemini OpenAI compat
        let reasoning_content: String?
        /// Structured reasoning chunks emitted by OpenRouter's new
        /// `reasoning_details` API. Gemini 3+ surfaces its thought summaries
        /// here (as `type: "reasoning.summary"`) rather than in the legacy
        /// `reasoning` string field, which is why thought summaries were
        /// previously leaking through as if they were the final answer.
        let reasoning_details: [ReasoningDetail]?

        /// The new reasoning token generated, if available. Aggregates every
        /// shape we've seen in the wild: the legacy `reasoning` string field
        /// (older OpenRouter / Anthropic), `reasoning_content` (DeepSeek /
        /// Bailian / Gemini OpenAI compat), and `reasoning_details` (current
        /// OpenRouter shape, used by Gemini 3+).
        var reasoningContent: String? {
            // Prefer the structured `reasoning_details` array when present —
            // for Gemini 3+ thought summaries this is the *only* place the
            // text appears, so falling back to `reasoning` first would miss
            // it entirely.
            if let details = self.reasoning_details,
               !details.isEmpty {
                let combined = details
                    .compactMap { $0.visibleText }
                    .joined()
                if !combined.isEmpty {
                    return combined
                }
            }
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

        /// A single entry in OpenRouter's `reasoning_details` stream. The
        /// payload key holding the human-readable text differs by `type`:
        ///   - `reasoning.summary`  → `summary` (Gemini 3 thought summaries)
        ///   - `reasoning.text`     → `text`    (Claude raw thinking)
        ///   - `reasoning.encrypted`→ `data`    (skipped — opaque blob)
        ///
        /// See https://openrouter.ai/docs/guides/best-practices/reasoning-tokens
        struct ReasoningDetail: Codable {
            let type: String?
            let summary: String?
            let text: String?
            let data: String?

            /// The text we want to surface to the user, if any. Encrypted
            /// blobs are intentionally dropped so they don't render as
            /// random base64 inside the reasoning panel.
            var visibleText: String? {
                if let summary = self.summary, !summary.isEmpty {
                    return summary
                }
                if let text = self.text, !text.isEmpty {
                    return text
                }
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

                enum CodingKeys: String, CodingKey {
                    case name
                    case arguments
                }

                init(
                    name: String? = nil,
                    arguments: String? = nil
                ) {
                    self.name = name
                    self.arguments = arguments
                }

                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    self.name = try container.decodeIfPresent(String.self, forKey: .name)
                    if let arguments = try? container.decodeIfPresent(String.self, forKey: .arguments) {
                        self.arguments = arguments
                    } else if let jsonValue = try? container.decodeIfPresent(JSONValue.self, forKey: .arguments) {
                        self.arguments = jsonValue.jsonString
                    } else {
                        self.arguments = nil
                    }
                }

                func encode(to encoder: Encoder) throws {
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    try container.encodeIfPresent(name, forKey: .name)
                    try container.encodeIfPresent(arguments, forKey: .arguments)
                }

                /// Function to get the corresponding function call
                public static func getFunctionCall(
                    name: String,
                    arguments: String,
                    toolCallID: String?,
                    toolRegistry: ToolRegistry
                ) -> (any DecodableFunctionCall)? {
                    // Try to init each function type
                    for function in toolRegistry.sortedFunctions {
                        // If function name matches
                        if function.name == name {
                            // Try to formulate arguments
                            let decoder: JSONDecoder = JSONDecoder()

                            let candidates = Self.normalizedArgumentCandidates(for: arguments)
                            for recoveredArgs in candidates {
                                if let result = Self.tryDecode(
                                    arguments: recoveredArgs,
                                    function: function,
                                    decoder: decoder,
                                    toolCallID: toolCallID
                                ) {
                                    if recoveredArgs != arguments {
                                        LlamaServer.logger.info("Successfully recovered malformed arguments for '\(name)' using automatic correction")
                                    }
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
                    decoder: JSONDecoder,
                    toolCallID: String?
                ) -> (any DecodableFunctionCall)? {
                    guard let data = arguments.data(using: .utf8),
                          let params = try? decoder.decode(function.paramsType.self, from: data) else {
                        return nil
                    }
                    return function.functionCallType.init(
                        name: function.name,
                        params: params,
                        toolCallID: toolCallID
                    )
                }

                /// Generate normalized and recovered argument candidates for common provider and JSON variants.
                private static func normalizedArgumentCandidates(for arguments: String) -> [String] {
                    var candidates = [arguments]
                    let cleaned = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
                    if cleaned != arguments {
                        candidates.append(cleaned)
                    }

                    for candidate in candidates {
                        guard let data = candidate.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) else {
                            continue
                        }
                        if let object = json as? [String: Any],
                           let innerArguments = object["arguments"] {
                            if let innerString = innerArguments as? String {
                                candidates.append(innerString)
                            } else if JSONSerialization.isValidJSONObject(innerArguments),
                                      let innerData = try? JSONSerialization.data(withJSONObject: innerArguments),
                                      let innerString = String(data: innerData, encoding: .utf8) {
                                candidates.append(innerString)
                            }
                        } else if let string = json as? String {
                            candidates.append(string)
                        }
                    }

                    candidates += Self.getRecoveryAttempts(for: cleaned)
                    return Self.uniqued(candidates)
                }

                /// Generate recovery attempts for common JSON errors.
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

                private static func uniqued(_ values: [String]) -> [String] {
                    var seen = Set<String>()
                    var result: [String] = []
                    for value in values where seen.insert(value).inserted {
                        result.append(value)
                    }
                    return result
                }

            }

        }
    }

    enum JSONValue: Codable {
        case string(String)
        case number(Double)
        case bool(Bool)
        case object([String: JSONValue])
        case array([JSONValue])
        case null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else if let value = try? container.decode(Double.self) {
                self = .number(value)
            } else if let value = try? container.decode([String: JSONValue].self) {
                self = .object(value)
            } else if let value = try? container.decode([JSONValue].self) {
                self = .array(value)
            } else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unsupported JSON value"
                )
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
                case .string(let value):
                    try container.encode(value)
                case .number(let value):
                    try container.encode(value)
                case .bool(let value):
                    try container.encode(value)
                case .object(let value):
                    try container.encode(value)
                case .array(let value):
                    try container.encode(value)
                case .null:
                    try container.encodeNil()
            }
        }

        var jsonString: String? {
            guard let data = try? JSONEncoder().encode(self) else {
                return nil
            }
            return String(data: data, encoding: .utf8)
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
        var startTime: Date = .now
        var endTime: Date = .now
        var responseStartSeconds: Double
        var predictedPerSecond: Double?
        var modelName: String?
        /// A `Usage` object containing the number of tokens used, among other stats
        var usage: Usage?
        /// A `Bool` indicating whether a remote server was used
        var usedServer: Bool
        /// The tools available while this response was generated
        var availableFunctions: [AnyFunctionBox] = []

        /// An array of ``FunctionCallRecord`` executed in the response
        var functionCallRecords: [FunctionCallRecord] = []
        /// A `Bool` representing if a function was called
        var containsFunctionCall: Bool {
            return !(self.functionCalls?.isEmpty ?? true)
        }
        /// A `Bool` indicating whether this response needs the function handling loop.
        var requiresFunctionHandling: Bool {
            return self.containsFunctionCall || !(self.malformedToolCalls?.isEmpty ?? true)
        }
        /// Function calls emitted by the assistant via native tool calling
        var functionCalls: [(any DecodableFunctionCall)]?
        /// Malformed tool calls that failed to parse
        var malformedToolCalls: [MalformedToolCall]?

        /// Per-iteration agent loop history captured on the live
        /// pending message during streaming. Snapshotted onto the
        /// response in ``Model/listenThinkRespond`` so callers can
        /// recover it after the pending message is cleared.
        var steps: [MessageStep] = []
        /// Moment the final iteration's reasoning phase ended, copied
        /// from the live pending message for the same reason as
        /// ``steps``. Used by the persisted message's "Thought for …"
        /// pill so the duration freezes the instant the model stops
        /// thinking.
        var reasoningEndTime: Date?

    }

}

extension EventSource.DataTask: @unchecked Sendable {  }

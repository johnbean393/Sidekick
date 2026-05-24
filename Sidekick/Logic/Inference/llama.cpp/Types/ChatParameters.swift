//
//  ChatParameters.swift
//  Sidekick
//
//  Created by Bean John on 10/9/24.
//

import Foundation
import OSLog
import SimilaritySearchKit

public struct ChatParameters: Codable {
    
    /// A `Logger` object for the ``ChatParameters`` object
    private static let logger: Logger = .init(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: ChatParameters.self)
    )
    
    /// Init for non-chat
    init(
        modelType: ModelType,
        usingRemoteModel: Bool,
        systemPrompt: String,
        messages: [Message.MessageSubset],
        enableThinking: Bool? = nil
    ) async {
        // Add system prompt if needed
        if !messages.contains(where: { $0.role == .system }) {
            let systemPromptMsg: Message = Message(
                text: systemPrompt,
                sender: .system
            )
            let systemPromptMsgSubset: Message.MessageSubset = await Message.MessageSubset(
                usingRemoteModel: usingRemoteModel,
                message: systemPromptMsg
            )
            self.messages = [systemPromptMsgSubset] + messages
        } else {
            self.messages = messages
        }
        self.model = Self.getModelName(modelType: modelType) ?? ""
        self.chat_template_kwargs = Self.getChatTemplateKwargs(
            modelType: modelType,
            usingRemoteModel: usingRemoteModel,
            enableThinking: enableThinking
        )
        
        // Add reasoning parameter for Claude 4+ on OpenRouter
        self.reasoning = Self.getReasoningOptions(modelType: modelType, usingRemoteModel: usingRemoteModel)
        
        // Resolve sampler defaults for the local model architecture,
        // deferring to any active Advanced Parameters flags.
        await self.applySamplingDefaults(
            modelType: modelType,
            usingRemoteModel: usingRemoteModel,
            enableThinking: enableThinking
        )
    }
    
    /// Init for chat & context aware agent
    init(
        modelType: ModelType,
        usingRemoteModel: Bool,
        systemPrompt: String,
        messages: [Message.MessageSubset],
        useWebSearch: Bool = false,
        useFunctions: Bool = false,
        functions: [AnyFunctionBox]? = nil,
        toolChoice: ToolChoice? = nil,
        expert: Expert? = nil,
        enableThinking: Bool? = nil
    ) async {
        // Formulate messages
        // Formulate system prompt
        var fullSystemPromptComponents: [String] = []
        fullSystemPromptComponents.append(systemPrompt)
        // Get metadata about the user and the date
        fullSystemPromptComponents.append(InferenceSettings.metadataPrompt)
        // Get information about the user
        var prompt: String? = nil
        if let content = messages.last?.content {
            switch content {
                case .textOnly(let string):
                    prompt = string
                case .multimodal(let contents):
                    for content in contents {
                        switch content {
                            case .text(let string):
                                prompt = string
                            default:
                                continue
                        }
                    }
            }
        }
        if let prompt,
           let memorizedInfo = await InferenceSettings.getMemoryPrompt(
            prompt: prompt
           ) {
            fullSystemPromptComponents.append(memorizedInfo)
        }
        // Tell the LLM to use sources
        fullSystemPromptComponents.append(InferenceSettings.useSourcesPrompt)
        // Use enabled functions from FunctionSelectionManager if no custom functions provided
        let enabledFunctions: [any AnyFunctionBox]
        if let customFunctions = functions {
            enabledFunctions = customFunctions
        } else {
            enabledFunctions = await MainActor.run { FunctionSelection.getEnabledFunctions() }
        }
        // Check if we should encourage using query_database function
        let isDefaultExpert: Bool
        if let resolvedExpert = expert {
            isDefaultExpert = await MainActor.run { resolvedExpert.isDefault }
        } else {
            isDefaultExpert = false
        }
        if let expert = expert,
           !isDefaultExpert,
           expert.resources.resources.count > 0,
           Settings.useFunctions && useFunctions {
            // Check if query_database function is enabled
            let hasQueryDatabaseFunction = enabledFunctions.contains { function in
                return function.name == "query_database"
            }
            if hasQueryDatabaseFunction {
                let expertDatabasePrompt: String = """
The `\(expert.name)` is currently active. Use `query_database` to query the `\(expert.name)` database whenever it might help inform your response.
"""
                fullSystemPromptComponents.append(expertDatabasePrompt)
            }
        }
        if Settings.useFunctions && useFunctions {
            fullSystemPromptComponents.append(
                InferenceSettings.useFunctionsPrompt
            )
        }
        // Join all components
        let fullSystemPrompt: String = fullSystemPromptComponents.joined(separator: "\n\n")
        // Formulate system prompt message
        let systemPromptMsg: Message = Message(
            text: fullSystemPrompt,
            sender: .system
        )
        let systemPromptMsgSubset: Message.MessageSubset = await Message.MessageSubset(
            usingRemoteModel: usingRemoteModel,
            message: systemPromptMsg,
            temporaryResources: [],
            shouldAddSources: false,
            useWebSearch: false
        )
        let messagesWithSystemPrompt: [Message.MessageSubset] = [systemPromptMsgSubset] + messages
        self.messages = messagesWithSystemPrompt
        self.model = Self.getModelName(modelType: modelType) ?? ""
        self.tools = !useFunctions ? [] : enabledFunctions.map(keyPath: \.openAiFunctionCall)
        if useFunctions {
            self.tool_choice = toolChoice ?? .auto
            // Force llama.cpp's lazy grammar to keep constraining structure across
            // every consecutive `<tool_call>` in a single turn. Without this, only the
            // first call is grammar-enforced and later ones can be emitted as
            // malformed XML in the content stream. OpenAI defaults this to true.
            self.parallel_tool_calls = true
        }
        self.chat_template_kwargs = Self.getChatTemplateKwargs(
            modelType: modelType,
            usingRemoteModel: usingRemoteModel,
            enableThinking: enableThinking
        )
        
        // Add reasoning parameter for Claude 4+ on OpenRouter
        self.reasoning = Self.getReasoningOptions(modelType: modelType, usingRemoteModel: usingRemoteModel)
        
        // Resolve sampler defaults for the local model architecture,
        // deferring to any active Advanced Parameters flags.
        await self.applySamplingDefaults(
            modelType: modelType,
            usingRemoteModel: usingRemoteModel,
            enableThinking: enableThinking
        )
    }
    
    var model: String
    var messages: [Message.MessageSubset]
    
    var tools: [OpenAIFunction] = []
    var tool_choice: ToolChoice?
    var parallel_tool_calls: Bool?
    
    /// Sampler parameters. ``applySamplingDefaults(...)`` populates these
    /// from ``ModelArchitecture`` (for local models) and from
    /// ``InferenceSettings.temperature`` (as a fallback). Any field the user
    /// has actively configured under "Advanced Parameters" is left `nil`
    /// here so the server-side CLI flag remains authoritative.
    var temperature: Double? = InferenceSettings.temperature
    var top_p: Double?
    var top_k: Int?
    var min_p: Double?
    var presence_penalty: Double?
    var frequency_penalty: Double?
    var repetition_penalty: Double?
    
    var stream: Bool = true
    var stream_options: StreamOptions = .init()
    
    var chat_template_kwargs: ChatTemplateKwargs?
    
    var reasoning: ReasoningOptions?
    
    /// Function to convert chat parameters to JSON
    public func toJSON(
        usingRemoteModel: Bool,
        modelType: ModelType,
        omittedParams: [ParamKey] = []
    ) -> String {
        // Tool calls only make sense for the regular chat model
        var omittedParams = omittedParams
        if modelType != .regular {
            omittedParams += [.tools, .tool_choice, .parallel_tool_calls]
        }
        // If is remote model, omit all local sampler parameters so the
        // provider's own recommended defaults are used.
        if usingRemoteModel {
            omittedParams += [
                .temperature,
                .top_p,
                .top_k,
                .min_p,
                .presence_penalty,
                .frequency_penalty,
                .repetition_penalty,
            ]
        }
        // Keep unique omits only
        omittedParams = Array(Set(omittedParams))
        // Use JSONEncoder and a wrapper struct for omitted keys
        struct OmitWrapper: Encodable {
            
            let model: String?
            let messages: [Message.MessageSubset]?
            let temperature: Double?
            let top_p: Double?
            let top_k: Int?
            let min_p: Double?
            let presence_penalty: Double?
            let frequency_penalty: Double?
            let repetition_penalty: Double?
            let stream: Bool?
            let stream_options: StreamOptions?
            let tools: [OpenAIFunction]?
            let tool_choice: ToolChoice?
            let parallel_tool_calls: Bool?
            let chat_template_kwargs: ChatTemplateKwargs?
            let reasoning: ReasoningOptions?
            
            init(
                from parent: ChatParameters,
                omitted: [ParamKey]
            ) {
                self.model = omitted.contains(.model) ? nil : parent.model
                self.messages = omitted.contains(.messages) ? nil : parent.messages
                self.temperature = omitted.contains(.temperature) ? nil : parent.temperature
                self.top_p = omitted.contains(.top_p) ? nil : parent.top_p
                self.top_k = omitted.contains(.top_k) ? nil : parent.top_k
                self.min_p = omitted.contains(.min_p) ? nil : parent.min_p
                self.presence_penalty = omitted.contains(.presence_penalty) ? nil : parent.presence_penalty
                self.frequency_penalty = omitted.contains(.frequency_penalty) ? nil : parent.frequency_penalty
                self.repetition_penalty = omitted.contains(.repetition_penalty) ? nil : parent.repetition_penalty
                self.stream = omitted.contains(.stream) ? nil : parent.stream
                self.stream_options = omitted.contains(.stream_options) ? nil : parent.stream_options
                self.tools = omitted.contains(.tools) ? nil : parent.tools
                self.tool_choice = omitted.contains(.tool_choice) ? nil : parent.tool_choice
                self.parallel_tool_calls = omitted.contains(.parallel_tool_calls) ? nil : parent.parallel_tool_calls
                self.chat_template_kwargs = omitted.contains(.chat_template_kwargs) ? nil : parent.chat_template_kwargs
                self.reasoning = omitted.contains(.reasoning) ? nil : parent.reasoning
            }
            
            // Remove nils from JSON
            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: ParamKey.self)
                if let model = model        { try container.encode(model, forKey: .model) }
                if let messages = messages  { try container.encode(messages, forKey: .messages) }
                if let temperature = temperature { try container.encode(temperature, forKey: .temperature) }
                if let top_p = top_p        { try container.encode(top_p, forKey: .top_p) }
                if let top_k = top_k        { try container.encode(top_k, forKey: .top_k) }
                if let min_p = min_p        { try container.encode(min_p, forKey: .min_p) }
                if let presence_penalty = presence_penalty {
                    try container.encode(presence_penalty, forKey: .presence_penalty)
                }
                if let frequency_penalty = frequency_penalty {
                    try container.encode(frequency_penalty, forKey: .frequency_penalty)
                }
                if let repetition_penalty = repetition_penalty {
                    try container.encode(repetition_penalty, forKey: .repetition_penalty)
                }
                if let stream = stream      { try container.encode(stream, forKey: .stream) }
                if let stream_options = stream_options { try container.encode(stream_options, forKey: .stream_options) }
                if let tools = tools        { try container.encode(tools, forKey: .tools) }
                if let tool_choice = tool_choice { try container.encode(tool_choice, forKey: .tool_choice) }
                if let parallel_tool_calls = parallel_tool_calls { try container.encode(parallel_tool_calls, forKey: .parallel_tool_calls) }
                if let chat_template_kwargs = chat_template_kwargs {
                    try container.encode(chat_template_kwargs, forKey: .chat_template_kwargs)
                }
                if let reasoning = reasoning {
                    try container.encode(reasoning, forKey: .reasoning)
                }
            }
            
        }
        let wrapper = OmitWrapper(from: self, omitted: omittedParams)
        // Encode and return
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let jsonData = try? encoder.encode(wrapper),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return "{}"
        }
        // Log call
        Self.logger.info("Made API call with parameters: \(jsonString, privacy: .public)")
        // Return JSON
        return jsonString
    }
    
    /// Enum representing all possible chat parameter keys
    public enum ParamKey: String, CaseIterable, CodingKey {
        case model
        case messages
        case temperature
        case top_p
        case top_k
        case min_p
        case presence_penalty
        case frequency_penalty
        case repetition_penalty
        case stream
        case stream_options
        case tools
        case tool_choice
        case parallel_tool_calls
        case chat_template_kwargs
        case provider
        case reasoning
    }
    
    public enum ToolChoice: String, Codable {
        case auto
        case none
    }
    
    /// Function to get the name of the model that will be used
    public static func getModelName(
        modelType: ModelType
    ) -> String? {
        // Return nil if server is unused
        if !InferenceSettings.useServer {
            return nil
        }
        // Else, get name
        switch modelType {
            case .regular:
                return InferenceSettings.serverModelName
            case .worker:
                let workerModelName: String = InferenceSettings.serverWorkerModelName
                if workerModelName.isEmpty {
                    return InferenceSettings.serverModelName
                }
                return workerModelName
        }
    }
    
    /// Function to determine if reasoning options should be added
    static func getReasoningOptions(
        modelType: ModelType,
        usingRemoteModel: Bool
    ) -> ReasoningOptions? {
        // Only apply for remote models
        guard usingRemoteModel else { return nil }
        // Check if using OpenRouter
        let endpoint = InferenceSettings.endpoint
        let isOpenRouter = endpoint.contains("openrouter")
        guard isOpenRouter else { return nil }
        // Get the model name
        guard let modelName = getModelName(modelType: modelType) else { return nil }
        guard let knownModel = KnownModel(identifier: modelName) else {
            return nil
        }
        // Gemini 3+ thinking models silently leak their thought summaries
        // into `delta.content` unless we explicitly opt-in to reasoning,
        // which moves the summaries into the structured `reasoning_details`
        // array where our parser can lift them into the reasoning panel.
        // `enabled: true` is the lightest-touch way to flip that switch
        // without forcing a specific thinkingLevel.
        if knownModel.requiresExplicitReasoningOptIn {
            return ReasoningOptions(enabled: true)
        }
        // Claude 4+ / GLM 4.5+ refuse to emit reasoning at all without a
        // budget, so we keep the legacy max_tokens hint for them.
        if knownModel.requiresExplicitReasoning {
            return ReasoningOptions(max_tokens: 8_000)
        }
        return nil
    }

    /// Mapping from llama-server CLI flags (used by the Advanced Parameters
    /// settings UI) to the JSON sampler keys we'd otherwise send per-request.
    /// Keeping this in one place avoids drift between the two layers.
    private static let advancedParameterFlagToParamKey: [String: ParamKey] = [
        "--temp": .temperature,
        "--temperature": .temperature,
        "--top-p": .top_p,
        "--top-k": .top_k,
        "--min-p": .min_p,
        "--presence-penalty": .presence_penalty,
        "--frequency-penalty": .frequency_penalty,
        "--repeat-penalty": .repetition_penalty,
        "--repetition-penalty": .repetition_penalty,
    ]
    
    /// Resolves architecture-recommended sampler defaults for the current
    /// local model and writes them into `self`, while *deferring to*
    /// any Advanced Parameters flags the user has marked active.
    ///
    /// Resolution order, per field:
    ///   1. If the user has activated a matching CLI flag under Advanced
    ///      Parameters (e.g. `--top-k`), the field is left `nil` here so
    ///      the server-side default (set at process launch) remains
    ///      authoritative.
    ///   2. Otherwise, if the user has set a per-model override via the
    ///      load-config sheet (``LocalModelFileEntity``), that wins.
    ///   3. Otherwise, if the model's GGUF filename matches a known
    ///      ``ModelArchitecture``, that family's publisher-recommended
    ///      value is used.
    ///   4. For `temperature`, an unknown architecture falls back to the
    ///      user's global ``InferenceSettings.temperature`` slider.
    ///
    /// Skipped entirely for remote models so the upstream provider's own
    /// recommended defaults are preserved.
    private mutating func applySamplingDefaults(
        modelType: ModelType,
        usingRemoteModel: Bool,
        enableThinking: Bool?
    ) async {
        guard !usingRemoteModel else {
            // Remote provider chooses sampling. Strip everything we
            // populated by default so the request body stays clean.
            self.temperature = nil
            self.top_p = nil
            self.top_k = nil
            self.min_p = nil
            self.presence_penalty = nil
            self.frequency_penalty = nil
            self.repetition_penalty = nil
            return
        }
        // Snapshot which advanced flags the user has marked active.
        let activeFlags: Set<String> = await MainActor.run {
            Set(ServerArgumentsStore.activeArguments().map(\.flag))
        }
        let suppressedKeys: Set<ParamKey> = Set(
            activeFlags.compactMap { Self.advancedParameterFlagToParamKey[$0] }
        )
        // Pick the architecture-recommended preset (if any).
        let modelUrl = InferenceSettings.localModelUrl(modelType: modelType)
        let arch = ModelArchitecture.detect(modelUrl: modelUrl)
        let useReasoning = Self.resolveUseReasoningForSampling(
            modelType: modelType,
            enableThinking: enableThinking
        )
        let recommended: SamplingParameters = arch?.recommendedSampling(
            useReasoning: useReasoning
        ) ?? SamplingParameters(
            // No known architecture: keep the existing user-visible
            // temperature behaviour and leave everything else to llama.cpp.
            temperature: InferenceSettings.temperature
        )
        // Layer per-model overrides (from the load-config sheet) over the
        // architecture defaults. Each field with a non-nil per-model
        // value wins; anything left nil falls through to the architecture
        // preset above. `recommended.merging(overrides)` only overrides
        // where overrides has a value.
        let perModelOverrides: SamplingParameters
        if let modelUrl, let config = ModelManager.loadConfig(for: modelUrl) {
            perModelOverrides = SamplingParameters(
                temperature: config.temperature,
                topP: config.topP,
                topK: config.topK,
                minP: config.minP,
                presencePenalty: config.presencePenalty,
                frequencyPenalty: config.frequencyPenalty,
                repetitionPenalty: config.repetitionPenalty
            )
        } else {
            perModelOverrides = SamplingParameters()
        }
        let resolved = recommended.merging(perModelOverrides)
        // Write fields that the user has *not* taken over via Advanced
        // Parameters. Otherwise leave them `nil` so the JSON request body
        // omits them, and the server-side CLI flag wins.
        self.temperature       = suppressedKeys.contains(.temperature)       ? nil : resolved.temperature
        self.top_p             = suppressedKeys.contains(.top_p)             ? nil : resolved.topP
        self.top_k             = suppressedKeys.contains(.top_k)             ? nil : resolved.topK
        self.min_p             = suppressedKeys.contains(.min_p)             ? nil : resolved.minP
        self.presence_penalty  = suppressedKeys.contains(.presence_penalty)  ? nil : resolved.presencePenalty
        self.frequency_penalty = suppressedKeys.contains(.frequency_penalty) ? nil : resolved.frequencyPenalty
        self.repetition_penalty = suppressedKeys.contains(.repetition_penalty) ? nil : resolved.repetitionPenalty
    }
    
    /// Picks the right "thinking vs non-thinking" sampling preset.
    ///
    /// The existing reasoning-toggle helper only marks a handful of model
    /// families as having a toggle (Qwen3.5+, Gemma 4). For everything else
    /// — including original Qwen3 and gpt-oss, which default to thinking
    /// mode — we treat reasoning as on so the right preset is selected.
    private static func resolveUseReasoningForSampling(
        modelType: ModelType,
        enableThinking: Bool?
    ) -> Bool {
        if let enableThinking {
            return enableThinking
        }
        if InferenceSettings.localModelSupportsLiveReasoningToggle(
            modelType: modelType
        ) {
            return InferenceSettings.localModelLiveReasoningEnabledByDefault(
                modelType: modelType
            )
        }
        return true
    }
    
    static func getChatTemplateKwargs(
        modelType: ModelType,
        usingRemoteModel: Bool,
        enableThinking: Bool?
    ) -> ChatTemplateKwargs? {
        guard !usingRemoteModel else { return nil }
        guard InferenceSettings.localModelSupportsLiveReasoningToggle(
            modelType: modelType
        ) else {
            return nil
        }
        let resolvedEnableThinking: Bool = enableThinking ?? InferenceSettings.localModelLiveReasoningEnabledByDefault(
            modelType: modelType
        )
        return .init(enable_thinking: resolvedEnableThinking)
    }
    
    struct SystemPrompt: Codable {
        
        var prompt: String
        var anti_prompt : String = "user:"
        var assistant_name: String = "assistant:"
        
        var wrapper: SystemPromptWrapper {
            .init(system_prompt: self)
        }
        
        public struct SystemPromptWrapper: Codable {
            
            var system_prompt: SystemPrompt
            
            /// Function to convert chat parameters to JSON
            public func toJSON() -> String {
                let encoder = JSONEncoder()
                encoder.outputFormatting = .prettyPrinted
                let jsonData = try? encoder.encode(self)
                return String(data: jsonData!, encoding: .utf8)!
            }
            
        }
    }
    
    struct StreamOptions: Codable {
        var include_usage: Bool = true
    }

    struct ChatTemplateKwargs: Codable {
        var enable_thinking: Bool
    }
    
    struct ReasoningOptions: Codable {
        var max_tokens: Int?
        var enabled: Bool?

        init(max_tokens: Int? = nil, enabled: Bool? = nil) {
            self.max_tokens = max_tokens
            self.enabled = enabled
        }

        enum CodingKeys: String, CodingKey {
            case max_tokens
            case enabled
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            if let max_tokens {
                try container.encode(max_tokens, forKey: .max_tokens)
            }
            if let enabled {
                try container.encode(enabled, forKey: .enabled)
            }
        }
    }
    
}

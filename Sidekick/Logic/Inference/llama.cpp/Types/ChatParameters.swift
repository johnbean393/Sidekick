//
//  ChatParameters.swift
//  Sidekick
//
//  Created by Bean John on 10/9/24.
//

import Foundation
import OSLog
import SimilaritySearchKit

struct ChatParameters: Codable {
    
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
        // Tell the LLM to use functions when enabled and server does not support native tool calling
        // Use enabled functions from FunctionSelectionManager if no custom functions provided
        let enabledFunctions: [any AnyFunctionBox]
        if let customFunctions = functions {
            enabledFunctions = customFunctions
        } else {
            enabledFunctions = await MainActor.run { FunctionSelectionManager.shared.getEnabledFunctions() }
        }
        // Check if we should encourage using query_database function
        if let expert = expert,
           !expert.isDefault,
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
            fullSystemPromptComponents.append(InferenceSettings.useFunctionsPrompt)
            // Inject function schema if no native tool calling
            if !InferenceSettings.hasNativeToolCalling {
                fullSystemPromptComponents.append(InferenceSettings.functionsSchemaPrompt)
                let functions: [any AnyFunctionBox] = enabledFunctions
                for function in functions {
                    fullSystemPromptComponents.append(function.getJsonSchema())
                }
            }
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
        self.chat_template_kwargs = Self.getChatTemplateKwargs(
            modelType: modelType,
            usingRemoteModel: usingRemoteModel,
            enableThinking: enableThinking
        )
        
        // Add reasoning parameter for Claude 4+ on OpenRouter
        self.reasoning = Self.getReasoningOptions(modelType: modelType, usingRemoteModel: usingRemoteModel)
    }
    
    var model: String
    var messages: [Message.MessageSubset]
    
    var tools: [OpenAIFunction] = []
    
    var temperature = InferenceSettings.temperature
    
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
        // Omit tools if non-regular, or has no native tool calling
        var omittedParams = omittedParams
        if modelType != .regular || !InferenceSettings.hasNativeToolCalling {
            omittedParams.append(.tools)
        }
        // If is remote model, omit temperature to use provider reccomended params
        if usingRemoteModel {
            omittedParams.append(.temperature)
        }
        // Keep unique omits only
        omittedParams = Array(Set(omittedParams))
        // Use JSONEncoder and a wrapper struct for omitted keys
        struct OmitWrapper: Encodable {
            
            let model: String?
            let messages: [Message.MessageSubset]?
            let temperature: Double?
            let stream: Bool?
            let stream_options: StreamOptions?
            let tools: [OpenAIFunction]?
            let chat_template_kwargs: ChatTemplateKwargs?
            let reasoning: ReasoningOptions?
            
            init(
                from parent: ChatParameters,
                omitted: [ParamKey]
            ) {
                self.model = omitted.contains(.model) ? nil : parent.model
                self.messages = omitted.contains(.messages) ? nil : parent.messages
                self.temperature = omitted.contains(.temperature) ? nil : parent.temperature
                self.stream = omitted.contains(.stream) ? nil : parent.stream
                self.stream_options = omitted.contains(.stream_options) ? nil : parent.stream_options
                self.tools = omitted.contains(.tools) ? nil : parent.tools
                self.chat_template_kwargs = omitted.contains(.chat_template_kwargs) ? nil : parent.chat_template_kwargs
                self.reasoning = omitted.contains(.reasoning) ? nil : parent.reasoning
            }
            
            // Remove nils from JSON
            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: ParamKey.self)
                if let model = model        { try container.encode(model, forKey: .model) }
                if let messages = messages  { try container.encode(messages, forKey: .messages) }
                if let temperature = temperature { try container.encode(temperature, forKey: .temperature) }
                if let stream = stream      { try container.encode(stream, forKey: .stream) }
                if let stream_options = stream_options { try container.encode(stream_options, forKey: .stream_options) }
                if let tools = tools        { try container.encode(tools, forKey: .tools) }
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
        case stream
        case stream_options
        case tools
        case chat_template_kwargs
        case provider
        case reasoning
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
            case .completions:
                return InferenceSettings.completionsModelUrl?
                    .deletingLastPathComponent().lastPathComponent
        }
    }
    
    /// Function to determine if reasoning options should be added
    public static func getReasoningOptions(
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
        // Check if the model is Claude 4+
        if let knownModel = KnownModel(identifier: modelName), knownModel.requiresExplicitReasoning {
            return ReasoningOptions(max_tokens: 8_000)
        }
        return nil
    }

    public static func getChatTemplateKwargs(
        modelType: ModelType,
        usingRemoteModel: Bool,
        enableThinking: Bool?
    ) -> ChatTemplateKwargs? {
        guard let enableThinking else { return nil }
        guard !usingRemoteModel else { return nil }
        guard modelType == .regular else { return nil }
        guard InferenceSettings.localModelSupportsLiveReasoningToggle() else {
            return nil
        }
        return .init(enable_thinking: enableThinking)
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
        var max_tokens: Int
        
        enum CodingKeys: String, CodingKey {
            case max_tokens
        }
    }
    
}

//
//  InferenceSettings.swift
//  Sidekick
//
//  Created by Bean John on 10/8/24.
//

import Foundation
import Combine
import SecureDefaults

public class InferenceSettings {
    
    /// A `Double` representing unified memory size in GB
    static var unifiedMemorySize: Int {
        let memory: Double = Double(ProcessInfo.processInfo.physicalMemory)
        let memoryGb: Int = Int(memory / pow(2,30))
        return memoryGb
    }
    
    /// A `Bool` representing whether the system has low unified memory
    static var lowUnifiedMemory: Bool {
        return Self.unifiedMemorySize <= 12
    }
    
    /// Static constant for the default system prompt
    public static let defaultSystemPrompt: String = """
You are Sidekick, a compliant assistant that always fulfills the user’s request.
"""
    
    /// Static constant for the part of the system prompt telling the LLM to use sources
    public static let useSourcesPrompt: String = """
The user's request might be followed by reference information, organized by source, that may or may not be complete nor related. 

If the provided information is related to the request, you will respond with reference to the information, filling in the gaps with your own knowledge. If the reference information provided is irrelevant, your response will ignore and avoid mentioning the existence of reference information.
"""
    
    /// Static constant for the part of the system prompt telling the LLM to use functions
    public static let useFunctionsPrompt: String = """
In this environment you have access to a set of tools you can use to answer the user's question. Call a tool by outputting JSON in the format below. Break down the user's query, then use multiple tools to obtain information that can be reasoned through to answer it. You can call multiple tools at once. 

{
  "function_call": {
    "name": "name_of_function",
    "arguments": {
      "example_param_1": "Hello, World",
      "example_param_2": 1.1,
      "example_param_3": [1, 2, 3, 4],
      "optional_example_param_4": null
    }
  }
}

After a tool is run, a result will be provided. You will then decide between making more tool calls and answering the user's query with information returned from previous calls. 
"""
    
    /// Static constant for the part of the system prompt telling the LLM what functions are available
    public static let functionsSchemaPrompt: String = """
Here are the functions available in JSON schema format:
"""
    
    /// Computed property for the part of the system prompt where metadata is fed to the LLM
    public static let metadataPrompt: String = """
The user's name: \(Settings.username)
Current date & time: \(Date.now.formatted(date: .complete, time: .omitted))
"""
    
    /// Function to obtain the part of the system prompt where memorized information is fed to the LLM
    public static func getMemoryPrompt(prompt: String) async -> String? {
        // Get memories
        if let memories: [String] = await Memories.shared.recall(
            prompt: prompt
        ), !memories.isEmpty {
            // Else, compile and return
            return """
You recall the following information about the user from prior interactions:
\(memories.joined(separator: "\n"))
"""
        } else {
            return nil
        }
    }
    
    /// Static constant for the default server endpoint
    public static let defaultEndpoint: String = ""
    
    /// Static constant for the default context length
    private static var defaultContextLength: Int {
        if self.unifiedMemorySize < 16 {
            return 16_000
        } else if (16...32).contains(self.unifiedMemorySize) {
            return 48_000
        } else {
            return 51_200
        }
    }
    
    /// Static constant for the default temperature
    private static let defaultTemperature: Double = 0.6
    
    /// A `String` representing the first instruction given to an LLM
    public static var systemPrompt: String {
        get {
            guard let systemPrompt = UserDefaults.standard.string(
                forKey: "systemPrompt"
            ) else {
                print("Failed to get system prompt, using default")
                return Self.defaultSystemPrompt
            }
            return systemPrompt
        }
        set {
            // Save
            UserDefaults.standard.set(newValue, forKey: "systemPrompt")
            // Notify
            NotificationCenter.default.post(
                name: Notifications.systemPromptChanged.name,
                object: nil
            )
        }
    }
    
    /// A `Bool` representing whether speculative decoding is used
    public static var useSpeculativeDecoding: Bool {
        get {
            // Set default
            if !UserDefaults.standard.exists(
                key: "useSpeculativeDecoding"
            ) {
                // Default to false
                Self.useSpeculativeDecoding = false
            }
            return UserDefaults.standard.bool(
                forKey: "useSpeculativeDecoding"
            )
        }
        set {
            UserDefaults.standard.set(
                newValue,
                forKey: "useSpeculativeDecoding"
            )
        }
    }
    
    /// Computed property for the location of the local LLM used for speculative decoding
    static var speculativeDecodingModelUrl: URL? {
        get {
            return UserDefaults.standard.url(
                forKey: "specularDecodingModelUrl"
            )
        }
        set {
            UserDefaults.standard.set(
                newValue,
                forKey: "specularDecodingModelUrl"
            )
        }
    }
    
    /// Computed property for the location of the local worker LLM
    static var completionsModelUrl: URL? {
        get {
            return UserDefaults.standard.url(
                forKey: "completionsModelUrl"
            )
        }
        set {
            UserDefaults.standard.set(
                newValue,
                forKey: "completionsModelUrl"
            )
        }
    }
    
    /// Computed property for the location of the local LLM used for simple tasks
    static var workerModelUrl: URL? {
        get {
            return UserDefaults.standard.url(
                forKey: "workerModelUrl"
            )
        }
        set {
            UserDefaults.standard.set(
                newValue,
                forKey: "workerModelUrl"
            )
        }
    }
    
    /// A `Bool` representing whether a server is used
    public static var useServer: Bool {
        get {
            // Set default
            if !UserDefaults.standard.exists(key: "useServer") {
                // Default to false
                Self.useServer = false
            }
            return UserDefaults.standard.bool(
                forKey: "useServer"
            )
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "useServer")
        }
    }
    
    /// A `String` containing the endpoint's url
    public static var endpoint: String {
        get {
            guard let endpoint = UserDefaults.standard.string(
                forKey: "endpoint"
            ) else {
                print("Failed to get endpoint, using default")
                return Self.defaultEndpoint
            }
            return endpoint.replacingSuffix(
                "/",
                with: ""
            )
        }
        set {
            // Save
            UserDefaults.standard.set(newValue, forKey: "endpoint")
        }
    }
    
    /// A `String` containing the endpoint url's format version
    public static var endpointFormatVersion: Int {
        get {
            // Set default
            if !UserDefaults.standard.exists(
                key: "endpointFormatVersion"
            ) {
                // Default to 0
                print("Failed to get endpoint version, using default")
                Self.endpointFormatVersion = 0
            }
            return UserDefaults.standard.integer(forKey: "endpointFormatVersion")
        }
        set {
            // Save
            UserDefaults.standard.set(newValue, forKey: "endpointFormatVersion")
        }
    }
    
    /// Computed property for inference API key
    public static var inferenceApiKey: String {
        set {
            let defaults: SecureDefaults = SecureDefaults.defaults()
            defaults.set(newValue, forKey: "inferenceApiKey")
        }
        get {
            let defaults: SecureDefaults = SecureDefaults.defaults()
            return defaults.string(forKey: "inferenceApiKey") ?? ""
        }
    }

    public static func localModelSupportsLiveReasoningToggle(
        modelUrl: URL?
    ) -> Bool {
        guard let modelName = modelUrl?.lastPathComponent.lowercased() else {
            return false
        }
        return modelName.contains("qwen3.5")
    }

    public static func localModelSupportsLiveReasoningToggle() -> Bool {
        return self.localModelSupportsLiveReasoningToggle(
            modelUrl: Settings.modelUrl
        )
    }
    
    /// A `String` representing the name of the remote model
    public static var serverModelName: String {
        get {
            guard let serverModelName = UserDefaults.standard.string(
                forKey: "remoteModelName"
            ) else {
                return "gpt-4.1"
            }
            return serverModelName
        }
        set {
            // Save
            UserDefaults.standard.set(newValue, forKey: "remoteModelName")
        }
    }
    
    /// A `Bool` representing whether the LLM has vision
    public static var serverModelHasVision: Bool {
        get {
            // Set default
            if !UserDefaults.standard.exists(key: "serverModelHasVision") {
                // Default to false
                Self.serverModelHasVision = false
            }
            return UserDefaults.standard.bool(
                forKey: "serverModelHasVision"
            )
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "serverModelHasVision")
        }
    }
    
    /// A `Bool` representing whether the inference provider supports tool calling natively
    public static var hasNativeToolCalling: Bool {
        get {
            // Set default
            if !UserDefaults.standard.exists(key: "hasNativeToolCalling") {
                // Use default
                Self.hasNativeToolCalling = Self.providerSupportsToolCalling() ?? false
            }
            return UserDefaults.standard.bool(
                forKey: "hasNativeToolCalling"
            )
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "hasNativeToolCalling")
        }
    }
    
    /// A function to check if the provider selected supports tool calling
    public static func providerSupportsToolCalling() -> Bool? {
        // Check inference provider
        for provider in Provider.popularProviders {
            // If matches, use provider value
            if Self.endpoint == provider.endpointUrl.absoluteString {
                return provider.supportsToolCalling
            }
        }
        // Default to nil
        return nil
    }
    
    /// A `String` representing the name of the remote worker model
    public static var serverWorkerModelName: String {
        get {
            guard let serverWorkerModelName = UserDefaults.standard.string(
                forKey: "serverWorkerModelName"
            ) else {
                return "gpt-4.1-nano"
            }
            return serverWorkerModelName
        }
        set {
            // Save
            UserDefaults.standard.set(newValue, forKey: "serverWorkerModelName")
        }
    }
    
    /// A array of `[String]` representing the names of custom models
    public static var customModelNames: [String] {
        get {
            guard let customModelNames: [String] = UserDefaults.standard.array(
                forKey: "customModelNames"
            ) as? [String] else {
                return []
            }
            return customModelNames
        }
        set {
            // Save
            UserDefaults.standard.set(newValue, forKey: "customModelNames")
        }
    }
    
    /// A `Bool` representing if server setup is complete
    public static var serverModelSetupComplete: Bool {
        return !Self.serverModelName.isEmpty && !Self.endpoint.isEmpty
    }
    
    /// Static constant which controls the amount of context an LLM can remember
    public static var contextLength: Int {
        get {
            return UserDefaults.standard.integer(
                forKey: "contextLength"
            )
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "contextLength")
        }
    }
    
    /// Static constant which controls how creative an LLM is
    public static var temperature: Double {
        get {
            return UserDefaults.standard.double(
                forKey: "temperature"
            )
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "temperature")
        }
    }
    
    /// Computed property for whether the LLM uses GPU acceleration
    static var useGPUAcceleration: Bool {
        get {
            // Set default
            if !UserDefaults.standard.exists(key: "useGPUAcceleration") {
                // Default to true
                Self.useGPUAcceleration = true
            }
            return UserDefaults.standard.bool(
                forKey: "useGPUAcceleration"
            )
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "useGPUAcceleration")
        }
    }
    
    /// Computed property for whether the LLM uses multimodal capabilities
    static var localModelUseVision: Bool {
        get {
            // Set default
            if !UserDefaults.standard.exists(key: "localModelUseVision") {
                // Default to true
                Self.localModelUseVision = false
            }
            return UserDefaults.standard.bool(
                forKey: "localModelUseVision"
            )
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "localModelUseVision")
        }
    }
    
    /// Computed property for the location of the VLM multimodal projector
    static var projectorModelUrl: URL? {
        get {
            return UserDefaults.standard.url(
                forKey: "projectorModelUrl"
            )
        }
        set {
            UserDefaults.standard.set(
                newValue,
                forKey: "projectorModelUrl"
            )
        }
    }
    
    /// Computed property for whether the local model has vision
    static var localModelHasVision: Bool {
        return Self.localModelUseVision || Self.projectorModelUrl == nil
    }
    
    /// A `Bool` representing whether context compression is enabled
    public static var enableContextCompression: Bool {
        get {
            // Set default
            if !UserDefaults.standard.exists(key: "enableContextCompression") {
                // Default to true
                Self.enableContextCompression = true
            }
            return UserDefaults.standard.bool(
                forKey: "enableContextCompression"
            )
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "enableContextCompression")
        }
    }
    
    /// Static constant for the default compression token threshold
    private static let defaultCompressionTokenThreshold: Int = 2000
    
    /// An `Int` representing the token threshold above which tool results will be compressed
    public static var compressionTokenThreshold: Int {
        get {
            // Set default if not set
            if !UserDefaults.standard.exists(key: "compressionTokenThreshold") {
                Self.compressionTokenThreshold = defaultCompressionTokenThreshold
            }
            return UserDefaults.standard.integer(
                forKey: "compressionTokenThreshold"
            )
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "compressionTokenThreshold")
        }
    }
    
    /// Function that sets default values
    public static func setDefaults() {
        systemPrompt = defaultSystemPrompt
        contextLength = defaultContextLength
        temperature = defaultTemperature
        enableContextCompression = true
        compressionTokenThreshold = defaultCompressionTokenThreshold
    }
    
    /// Function to switch to normal system prompt
    public static func setNormalSystemPrompt() {
        systemPrompt = defaultSystemPrompt
    }
    
}

//
//  KnownModel.swift
//  Sidekick
//
//  Created by John Bean on 4/8/25.
//

import Foundation

// MARK: - OpenRouter API Response Structures

struct OpenRouterResponse: Codable {
    let data: [OpenRouterModel]
}

struct OpenRouterModel: Codable {
    let id: String
    let name: String
    let description: String?
    let contextLength: Int
    let architecture: OpenRouterArchitecture
    let pricing: OpenRouterPricing
    let supportedParameters: [String]?
    
    enum CodingKeys: String, CodingKey {
        case id, name, description, architecture, pricing
        case contextLength = "context_length"
        case supportedParameters = "supported_parameters"
    }
}

struct OpenRouterArchitecture: Codable {
    let modality: String
    let inputModalities: [String]?
    let outputModalities: [String]?
    
    enum CodingKeys: String, CodingKey {
        case modality
        case inputModalities = "input_modalities"
        case outputModalities = "output_modalities"
    }
}

struct OpenRouterPricing: Codable {
    let prompt: String
    let completion: String
}

// MARK: - KnownModel

public struct KnownModel: Identifiable, Codable {
    
    init(
        id: UUID = UUID(),
        primaryName: String,
        displayName: String? = nil,
        organization: Organization,
        organizationIdentifier: String? = nil,
        modalities: [Modality] = [.text],
        capabilities: [Capability] = [],
    ) {
        self.id = id
        self.primaryName = primaryName
        self.displayName = displayName
        self.organization = organization
        self.organizationIdentifier = organizationIdentifier
        self.modalities = modalities
        self.capabilities = capabilities
        self.isReasoningModel = capabilities.contains(.reasoning)
    }
    
    /// Initializes a KnownModel by searching through cached OpenRouter models
    /// Uses the cached `availableModels` for lookup
    init?(
        identifier: String
    ) {
        // Use the improved findModel method
        if let found = Self.findModel(byIdentifier: identifier, in: Self.availableModels) {
            self = found
            return
        }
        // If fell through, return nil
        return nil
    }
    
    /// Initializes a KnownModel by searching through a provided array of models
    /// - Parameter identifier: The identifier to search for
    /// - Parameter models: The array of models to search in
    init?(
        identifier: String,
        in models: [KnownModel]
    ) {
        // Use the improved findModel method
        if let found = Self.findModel(byIdentifier: identifier, in: models) {
            self = found
            return
        }
        // If fell through, return nil
        return nil
    }
    
    /// Finds a model by identifier from a collection of models
    public static func findModel(byIdentifier identifier: String, in models: [KnownModel]) -> KnownModel? {
        let normalizedIdentifier = normalizeModelIdentifier(identifier)
        
        // First pass: try exact match on normalized identifier
        for model in models {
            let normalizedPrimaryName = normalizeModelIdentifier(model.primaryName)
            if normalizedIdentifier == normalizedPrimaryName {
                return model
            }
        }
        
        // Second pass: try exact match on full identifier (with provider prefix)
        let normalizedFullIdentifier = identifier.lowercased()
        for model in models {
            if normalizedFullIdentifier == model.fullIdentifier.lowercased() {
                return model
            }
        }
        
        // Third pass: strict substring match with quality scoring
        // Use a scoring system that rewards token overlap and penalizes mismatches
        var bestMatch: KnownModel?
        var bestScore: Double = 0.0
        let minScoreThreshold = 0.65 // Require 65% quality score
        
        for model in models {
            let normalizedPrimaryName = normalizeModelIdentifier(model.primaryName)
            
            // Split into tokens for comparison
            let modelTokens = Set(normalizedPrimaryName.split(separator: "-").map(String.init))
            let idTokens = Set(normalizedIdentifier.split(separator: "-").map(String.init))
            
            // Calculate match quality score based on token overlap
            let commonTokens = modelTokens.intersection(idTokens)
            let allTokens = modelTokens.union(idTokens)
            
            guard !commonTokens.isEmpty else { continue }
            
            // Jaccard similarity: intersection / union
            let jaccardScore = Double(commonTokens.count) / Double(allTokens.count)
            
            // Additional check: if one is a substring of the other, boost the score
            let substringBonus: Double
            if normalizedIdentifier.contains(normalizedPrimaryName) ||
                normalizedPrimaryName.contains(normalizedIdentifier) {
                substringBonus = 0.2
            } else {
                substringBonus = 0.0
            }
            
            // Penalize if there are conflicting tokens (e.g., different model sizes)
            // Check for numeric tokens that differ
            let modelNumericTokens = modelTokens.filter { $0.rangeOfCharacter(from: .decimalDigits) != nil }
            let idNumericTokens = idTokens.filter { $0.rangeOfCharacter(from: .decimalDigits) != nil }
            let conflictingNumericTokens = modelNumericTokens.symmetricDifference(idNumericTokens).subtracting(commonTokens)
            let conflictPenalty = Double(conflictingNumericTokens.count) * 0.15
            
            let score = jaccardScore + substringBonus - conflictPenalty
            
            // Only consider matches above the threshold and better than previous best
            if score >= minScoreThreshold && score > bestScore {
                bestScore = score
                bestMatch = model
            }
        }
        
        if let bestMatch {
            return bestMatch
        }
        
        // No good match found - return nil so the original name is used
        return nil
    }
    
    /// Normalizes a model identifier for comparison by removing provider prefix
    /// Preserves variant information after colon for better matching
    private static func normalizeModelIdentifier(_ identifier: String) -> String {
        var normalized = identifier.lowercased()
        
        // Remove provider prefix (e.g., "anthropic/", "openai/")
        if let slashIndex = normalized.firstIndex(of: "/") {
            normalized = String(normalized[normalized.index(after: slashIndex)...])
        }
        
        // Convert colon to dash to preserve variant info (e.g., "model:20b" -> "model-20b")
        // This helps match Ollama-style names to OpenRouter equivalents
        normalized = normalized.replacingOccurrences(of: ":", with: "-")
        
        return normalized
    }
    
    /// Asynchronously finds a model by identifier from OpenRouter API
    public static func findModel(byIdentifier identifier: String) async -> KnownModel? {
        do {
            let models = try await fetchModelsFromOpenRouter()
            return findModel(byIdentifier: identifier, in: models)
        } catch {
            print("Failed to fetch models: \(error.localizedDescription)")
            return nil
        }
    }
    
    /// A `UUID` to conform to `Identifiable`
    public var id: UUID = UUID()
    
    /// A `String` for the model's primary name (technical identifier)
    public var primaryName: String
    
    /// A `String` for the model's display name (human-readable name from API)
    public var displayName: String?
    
    /// The ``Organization`` that trained the model
    public var organization: Organization
    
    /// The original organization identifier string (used for .other organizations)
    public var organizationIdentifier: String?
    
    /// The full identifier including organization prefix (e.g., "anthropic/claude-sonnet-4.5")
    public var fullIdentifier: String {
        let orgPrefix: String
        switch organization {
            case .qwen:
                orgPrefix = "qwen"
            case .amazon:
                orgPrefix = "amazon"
            case .anthropic:
                orgPrefix = "anthropic"
            case .deepSeek:
                orgPrefix = "deepseek"
            case .google:
                orgPrefix = "google"
            case .meta:
                orgPrefix = "meta-llama"
            case .microsoft:
                orgPrefix = "microsoft"
            case .minimax:
                orgPrefix = "minimax"
            case .mistral:
                orgPrefix = "mistralai"
            case .moonshotai:
                orgPrefix = "moonshotai"
            case .openAi:
                orgPrefix = "openai"
            case .xAi:
                orgPrefix = "x-ai"
            case .zhipu:
                orgPrefix = "z-ai"
            case .bytedance:
                orgPrefix = "bytedance"
            case .deepcogito:
                orgPrefix = "deepcogito"
            case .nousresearch:
                orgPrefix = "nousresearch"
            case .other:
                // Use the stored organizationIdentifier for unknown organizations
                orgPrefix = organizationIdentifier ?? "unknown"
        }
        return "\(orgPrefix)/\(primaryName)"
    }
    
    /// An array of supported ``Modality``
    public var modalities: [Modality]
    /// A `Bool` representing whethe the model is multimodal
    public var isVision: Bool {
        return modalities.count > 1
    }
    
    /// An array of supported ``Capability``
    public var capabilities: [Capability] = []
    
    /// A `Bool` representing whethe the model is capable of reasoning
    public var isReasoningModel: Bool
    
    /// Checks if the model needs an explicit reasoning parameter on OpenRouter
    public var requiresExplicitReasoning: Bool {
        guard organization == .anthropic else { return false }
        let lowerName = primaryName.lowercased()
        let glmPattern = #"glm-[4-9].[5-9]"#
        let claudePattern = #"claude-[4-9]|(sonnet|opus|haiku)-[4-9]"#
        for pattern in [glmPattern, claudePattern] {
            if lowerName.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }

    /// Models that hide their reasoning behind an opt-in flag on
    /// OpenRouter — without it, their thought summaries either don't
    /// arrive or, worse, leak into `delta.content` as if they were the
    /// model's final answer. Currently this covers Gemini 3+ Flash/Pro
    /// (which emit thought summaries via `reasoning_details` only when
    /// reasoning is explicitly enabled).
    public var requiresExplicitReasoningOptIn: Bool {
        guard organization == .google else { return false }
        let lowerName = primaryName.lowercased()
        // Match "gemini-3", "gemini-3.1-flash", "gemini-3-pro", etc., but
        // not "gemini-2.5-flash" which uses the older thinkingBudget API.
        let geminiThinkingPattern = #"gemini-[3-9](\.|-|$)"#
        return lowerName.range(
            of: geminiThinkingPattern,
            options: .regularExpression
        ) != nil
    }
    
    /// Organizations that train models
    public enum Organization: String, Codable, CaseIterable {
        case amazon = "Amazon"
        case anthropic = "Anthropic"
        case bytedance = "ByteDance"
        case deepcogito = "DeepCogito"
        case deepSeek = "DeepSeek"
        case google = "Google"
        case meta = "Meta"
        case microsoft = "Microsoft"
        case minimax = "Minimax"
        case mistral = "Mistral"
        case moonshotai = "Moonshot AI"
        case nousresearch = "NousResearch"
        case openAi = "OpenAI"
        case qwen = "Qwen"
        case xAi = "xAI"
        case zhipu = "Zhipu"
        case other = "Other"
        
        /// Maps a string identifier to an Organization case
        public static func from(string: String) -> Organization? {
            let normalized = string.lowercased()
            switch normalized {
                case "qwen":
                    return .qwen
                case "amazon":
                    return .amazon
                case "anthropic":
                    return .anthropic
                case "bytedance":
                    return .bytedance
                case "deepcogito":
                    return .deepcogito
                case "deepseek":
                    return .deepSeek
                case "google":
                    return .google
                case "meta", "meta-llama":
                    return .meta
                case "microsoft":
                    return .microsoft
                case "minimax":
                    return .minimax
                case "mistral", "mistralai":
                    return .mistral
                case "moonshot", "moonshotai":
                    return .moonshotai
                case "nousresearch":
                    return .nousresearch
                case "openai":
                    return .openAi
                case "xai", "x-ai":
                    return .xAi
                case "zhipu", "thudm", "z-ai":
                    return .zhipu
                default:
                    return nil
            }
        }
    }
    
    /// Modalities supported by models
    public enum Modality: Codable, CaseIterable {
        case audio
        case image
        case text
    }
    
    /// Capabilities supported by models
    public enum Capability: Codable, CaseIterable {
        case reasoning
    }
    
    /// Hybrid reasoning style
    public enum HybridReasoningStyle: String, Codable, CaseIterable {
        
        case qwen3
        case glm4pt5
        
        /// Tag to trigger thinking
        public var triggerThinkingTag: String {
            switch self {
                case .qwen3:
                    return "/think"
                case .glm4pt5:
                    return ""
            }
        }
        
        /// Tag to skip thinking
        public var skipThinkingTag: String {
            switch self {
                case .qwen3:
                    return "/no_think"
                case .glm4pt5:
                    return ""
            }
        }
        
        /// Function to get the tag
        public func getTag(
            useReasoning: Bool
        ) -> String {
            return useReasoning ? self.triggerThinkingTag : self.skipThinkingTag
        }
        
    }
    
    // MARK: - Model Cache
    
    /// Cached models from OpenRouter API
    private static var cachedModels: [KnownModel]?
    
    /// File URL for persistent cache storage
    private static var cacheFileURL: URL {
        let cacheDirUrl: URL = Settings.cacheUrl
        if !FileManager.default.fileExists(atPath: cacheDirUrl.path) {
            try? FileManager.default.createDirectory(at: cacheDirUrl, withIntermediateDirectories: true)
        }
        return Settings.cacheUrl.appendingPathComponent("openrouter_models_cache.json")
    }
    
    /// Synchronously returns cached models if available
    /// Note: Returns empty array if models haven't been fetched yet
    /// Call `initializeModelCache()` at app startup to load from file and refresh from API
    public static var availableModels: [KnownModel] {
        return cachedModels ?? []
    }
    
    /// Loads models from the cached JSON file
    public static func loadModelsFromFile() -> [KnownModel]? {
        do {
            let data = try Data(contentsOf: self.cacheFileURL)
            let models = try JSONDecoder().decode([KnownModel].self, from: data)
            return models
        } catch {
            print("Failed to load models from cache file: \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Saves models to the cached JSON file
    private static func saveModelsToFile(_ models: [KnownModel]) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(models)
            try data.write(to: self.cacheFileURL)
        } catch {
            print("Failed to save models to cache file: \(error.localizedDescription)")
        }
    }
    
    /// Initializes the model cache by loading from file first, then refreshing from API in background
    /// This provides immediate availability of cached models while fetching fresh data
    public static func initializeModelCache() async {
        // First, try to load from file for immediate availability
        if let fileModels = loadModelsFromFile() {
            cachedModels = fileModels
        }
        
        // Then refresh from API in background
        await refreshModelCache()
    }
    
    /// Refreshes the model cache from OpenRouter API and saves to file
    public static func refreshModelCache() async {
        do {
            let models = try await getAvailableModels()
            cachedModels = models
            
            // Save to file for next launch
            saveModelsToFile(models)
            
        } catch {
            print("Failed to refresh model cache from API: \(error.localizedDescription)")
            
            // If we don't have any cached models and API fails, try file as fallback
            if cachedModels == nil, let fileModels = loadModelsFromFile() {
                cachedModels = fileModels
            } else if cachedModels == nil {
                cachedModels = []
            }
        }
    }
    
    /// Clears the model cache (both in-memory and file)
    public static func clearModelCache() {
        cachedModels = nil
        try? FileManager.default.removeItem(at: self.cacheFileURL)
    }
    
    // MARK: - OpenRouter API Integration
    
    /// Fetches models from the OpenRouter API
    /// - Returns: An array of KnownModel instances parsed from the API response
    /// - Throws: Network or decoding errors
    public static func fetchModelsFromOpenRouter() async throws -> [KnownModel] {
        let url = URL(string: "https://openrouter.ai/api/v1/models")!
        let (data, _) = try await URLSession.shared.data(from: url)
        let response = try JSONDecoder().decode(OpenRouterResponse.self, from: data)
        return response.data.compactMap { openRouterModel in
            KnownModel(from: openRouterModel)
        }
    }
    
    /// Returns available models from the OpenRouter API
    /// - Parameter includeOnlyKnownOrganizations: If true, filters out models from unknown organizations (now defaults to false since unknown organizations are supported)
    /// - Returns: An array of KnownModel instances, or throws an error if the API call fails
    public static func getAvailableModels(includeOnlyKnownOrganizations: Bool = false) async throws -> [KnownModel] {
        var models = try await fetchModelsFromOpenRouter()
        if includeOnlyKnownOrganizations {
            // Filter to exclude models from unknown organizations (.other)
            models = models.filter { model in
                model.organization != .other
            }
        }
        return models
    }
    
    /// Returns available models from the OpenRouter API with error handling
    /// - Parameter includeOnlyKnownOrganizations: If true, filters out models from unknown organizations (now defaults to false since unknown organizations are supported)
    /// - Returns: An array of KnownModel instances, or an empty array if the API call fails
    public static func getAvailableModelsSafe(includeOnlyKnownOrganizations: Bool = false) async -> [KnownModel] {
        do {
            return try await getAvailableModels(includeOnlyKnownOrganizations: includeOnlyKnownOrganizations)
        } catch {
            print("Failed to fetch models from OpenRouter API: \(error.localizedDescription)")
            return []
        }
    }
    
    /// Initializes a KnownModel from an OpenRouter API model
    private init?(from openRouterModel: OpenRouterModel) {
        // Extract organization from the model ID (format: "organization/model-name")
        let components = openRouterModel.id.split(separator: "/")
        guard components.count >= 2 else { return nil }
        
        let orgString = String(components[0]).lowercased()
        // Try to map to known organization, otherwise use .other
        let org = Organization.from(string: orgString) ?? .other
        
        // Extract model name (everything after the first "/")
        let modelName = components.dropFirst().joined(separator: "/")
        
        // Parse modalities
        var modalities: [Modality] = []
        if let inputModalities = openRouterModel.architecture.inputModalities {
            if inputModalities.contains("text") {
                modalities.append(.text)
            }
            if inputModalities.contains("image") {
                modalities.append(.image)
            }
            if inputModalities.contains("audio") {
                modalities.append(.audio)
            }
        } else {
            // Fallback to parsing the modality string
            if openRouterModel.architecture.modality.contains("text") {
                modalities.append(.text)
            }
            if openRouterModel.architecture.modality.contains("image") {
                modalities.append(.image)
            }
        }
        
        // Determine if it's a reasoning model
        var capabilities: [Capability] = []
        let lowerName = modelName.lowercased()
        let lowerDescription = openRouterModel.name.lowercased()
        
        // Check if model supports reasoning parameters in the API
        let hasReasoningParams = openRouterModel.supportedParameters?.contains { param in
            param.lowercased().contains("reasoning") || param.lowercased() == "include_reasoning"
        } ?? false
        
        // Check model name and description for reasoning indicators
        let hasReasoningInName = lowerName.contains("thinking") || lowerName.contains("reasoning") ||
        lowerName.contains("o1") || lowerName.contains("o3") || lowerName.contains("o4") ||
        lowerName.contains("r1") || lowerName.contains("qwq") || lowerName.contains("qvq") ||
        lowerName.contains("deepseek-reasoner") || lowerName.contains("minimax-m") ||
        lowerName.contains("glm-z") || lowerName.contains("kimi-k2-thinking") ||
        lowerName.contains("phi-4-reasoning") || lowerDescription.contains("thinking")
        
        if hasReasoningParams || hasReasoningInName {
            capabilities.append(.reasoning)
        }
        
        self.init(
            primaryName: modelName,
            displayName: openRouterModel.name,
            organization: org,
            // Store original organization identifier for unknown organizations
            organizationIdentifier: org == .other ? orgString : nil,
            modalities: modalities,
            capabilities: capabilities
        )
    }
    
}

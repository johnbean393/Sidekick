//
//  ModelArchitecture.swift
//  Sidekick
//
//  Curated table of known local-model architectures and their
//  publisher-recommended sampling defaults. The intent is to give every
//  newly loaded GGUF a sensible starting point — matching what the model
//  author published on their HF card / docs — rather than relying on
//  llama.cpp's generic built-ins (which can make some families, notably
//  Qwen3.x, fall into output loops at long context).
//
//  Source citations live as comments next to each preset so we can re-verify
//  whenever the publisher updates them.
//

import Foundation

/// A locally-runnable model family that Sidekick recognises and ships
/// recommended sampling defaults for.
public enum ModelArchitecture: String, Codable, CaseIterable {

    case qwen3
    case qwen3pt5  // Covers Qwen3.5 (and Qwen3.6, which inherits the 3.5 sampling)
    case gemma3
    case gemma4
    case gptOss

    // MARK: - Detection

    /// Detect the architecture from a GGUF file's URL.
    ///
    /// Filename-only — matches the heuristic already used by
    /// ``InferenceSettings/localModelSupportsLiveReasoningToggle(modelUrl:)``.
    /// A future improvement is to also consult the GGUF's
    /// `general.architecture` metadata key via ``GGUFMetadataReader``.
    public static func detect(modelUrl: URL?) -> ModelArchitecture? {
        guard let raw = modelUrl?.lastPathComponent.lowercased() else {
            return nil
        }
        let collapsed = raw
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
        // Order matters: more specific names first, otherwise "qwen3.5"
        // would be swallowed by "qwen3".
        if raw.contains("qwen3.6")
            || collapsed.contains("qwen3.6")
            || collapsed.contains("qwen36") {
            // Qwen3.6 reuses Qwen3.5's published sampling recommendations
            // until the Qwen team ships a divergent generation_config.
            return .qwen3pt5
        }
        if raw.contains("qwen3.5")
            || collapsed.contains("qwen3.5")
            || collapsed.contains("qwen35") {
            return .qwen3pt5
        }
        if collapsed.contains("qwen3") {
            return .qwen3
        }
        if collapsed.contains("gemma4") {
            return .gemma4
        }
        if collapsed.contains("gemma3") {
            return .gemma3
        }
        if raw.contains("gpt-oss") || collapsed.contains("gptoss") {
            return .gptOss
        }
        return nil
    }

    // MARK: - Reasoning mode awareness

    /// Whether the architecture exposes a thinking / non-thinking toggle
    /// whose sampling presets differ. For families that publish a single
    /// preset "across all use cases" (Gemma 4, gpt-oss) this is `false`.
    public var hasReasoningModeSpecificSampling: Bool {
        switch self {
            case .qwen3, .qwen3pt5:
                return true
            case .gemma3, .gemma4, .gptOss:
                return false
        }
    }

    // MARK: - Recommended sampling

    /// The publisher-recommended sampler defaults for this architecture.
    ///
    /// - Parameter useReasoning: Whether the model is being asked to run in
    ///   its "thinking" mode. Ignored for architectures whose publisher ships
    ///   a single set of defaults for both modes.
    public func recommendedSampling(
        useReasoning: Bool
    ) -> SamplingParameters {
        switch self {
            case .qwen3:
                // Source: QwenLM/Qwen3 quickstart docs + Qwen/Qwen3-*-GGUF
                // HF cards. Quantized variants explicitly recommend
                // presence_penalty=1.5 to suppress repetition.
                // https://github.com/QwenLM/Qwen3/blob/bac19d60/docs/source/getting_started/quickstart.md
                if useReasoning {
                    return SamplingParameters(
                        temperature: 0.6,
                        topP: 0.95,
                        topK: 20,
                        minP: 0.0,
                        presencePenalty: 1.5
                    )
                } else {
                    return SamplingParameters(
                        temperature: 0.7,
                        topP: 0.8,
                        topK: 20,
                        minP: 0.0,
                        presencePenalty: 1.5
                    )
                }
            case .qwen3pt5:
                // Source: Qwen/Qwen3.5-397B-A17B HF model card.
                // Notable: thinking mode drops presence_penalty back to 0,
                // and both modes pin repetition_penalty=1.0 explicitly.
                // https://huggingface.co/Qwen/Qwen3.5-397B-A17B
                if useReasoning {
                    return SamplingParameters(
                        temperature: 0.6,
                        topP: 0.95,
                        topK: 20,
                        minP: 0.0,
                        presencePenalty: 0.0,
                        repetitionPenalty: 1.0
                    )
                } else {
                    return SamplingParameters(
                        temperature: 0.7,
                        topP: 0.8,
                        topK: 20,
                        minP: 0.0,
                        presencePenalty: 1.5,
                        repetitionPenalty: 1.0
                    )
                }
            case .gemma3:
                // Source: Gemma 3 Hugging Face model cards (Google).
                // No published mode-specific overrides.
                return SamplingParameters(
                    temperature: 1.0,
                    topP: 0.95,
                    topK: 64,
                    minP: 0.0
                )
            case .gemma4:
                // Source: Google AI for Developers — Gemma 4 model card.
                // Google states the same numbers "across all use cases",
                // including thinking mode (enabled via the `<|think|>`
                // system-prompt token, not via sampler changes).
                // https://ai.google.dev/gemma/docs/core/model_card_4
                return SamplingParameters(
                    temperature: 1.0,
                    topP: 0.95,
                    topK: 64,
                    minP: 0.0
                )
            case .gptOss:
                // Source: openai/gpt-oss README. Reasoning effort is set
                // through the harmony system prompt ("Reasoning: low|medium|high"),
                // not via sampler changes.
                // https://github.com/openai/gpt-oss
                return SamplingParameters(
                    temperature: 1.0,
                    topP: 1.0
                )
        }
    }

    // MARK: - Display

    /// Human-readable label, useful for settings UI and logs.
    public var displayName: String {
        switch self {
            case .qwen3:    return "Qwen3"
            case .qwen3pt5: return "Qwen3.5"
            case .gemma3:   return "Gemma 3"
            case .gemma4:   return "Gemma 4"
            case .gptOss:   return "gpt-oss"
        }
    }
}

// MARK: - SamplingParameters

/// Sampler parameters that can be sent to a llama.cpp-backed
/// OpenAI-compatible chat endpoint.
///
/// All fields are optional so callers encode only the values the model
/// publisher actually specifies, leaving anything unset to fall back to
/// llama.cpp's defaults. JSON keys follow llama-server's snake_case
/// convention so the struct can be sent at the top level of a
/// `/v1/chat/completions` request body.
public struct SamplingParameters: Codable, Equatable {

    public var temperature: Double?
    public var topP: Double?
    public var topK: Int?
    public var minP: Double?
    public var presencePenalty: Double?
    public var frequencyPenalty: Double?
    public var repetitionPenalty: Double?

    public init(
        temperature: Double? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        minP: Double? = nil,
        presencePenalty: Double? = nil,
        frequencyPenalty: Double? = nil,
        repetitionPenalty: Double? = nil
    ) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.minP = minP
        self.presencePenalty = presencePenalty
        self.frequencyPenalty = frequencyPenalty
        self.repetitionPenalty = repetitionPenalty
    }

    enum CodingKeys: String, CodingKey {
        case temperature
        case topP             = "top_p"
        case topK             = "top_k"
        case minP             = "min_p"
        case presencePenalty  = "presence_penalty"
        case frequencyPenalty = "frequency_penalty"
        case repetitionPenalty = "repetition_penalty"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let temperature {
            try container.encode(temperature, forKey: .temperature)
        }
        if let topP {
            try container.encode(topP, forKey: .topP)
        }
        if let topK {
            try container.encode(topK, forKey: .topK)
        }
        if let minP {
            try container.encode(minP, forKey: .minP)
        }
        if let presencePenalty {
            try container.encode(presencePenalty, forKey: .presencePenalty)
        }
        if let frequencyPenalty {
            try container.encode(frequencyPenalty, forKey: .frequencyPenalty)
        }
        if let repetitionPenalty {
            try container.encode(repetitionPenalty, forKey: .repetitionPenalty)
        }
    }

    /// `true` when every field is `nil` — useful for callers that want to
    /// skip emitting the block entirely.
    public var isEmpty: Bool {
        return temperature == nil
            && topP == nil
            && topK == nil
            && minP == nil
            && presencePenalty == nil
            && frequencyPenalty == nil
            && repetitionPenalty == nil
    }

    /// Returns a copy with any field set in `override` taking precedence
    /// over `self`. Lets callers compose architecture defaults with a
    /// user-supplied override (e.g. a global temperature setting).
    public func merging(
        _ override: SamplingParameters
    ) -> SamplingParameters {
        return SamplingParameters(
            temperature:       override.temperature       ?? self.temperature,
            topP:              override.topP              ?? self.topP,
            topK:              override.topK              ?? self.topK,
            minP:              override.minP              ?? self.minP,
            presencePenalty:   override.presencePenalty   ?? self.presencePenalty,
            frequencyPenalty:  override.frequencyPenalty  ?? self.frequencyPenalty,
            repetitionPenalty: override.repetitionPenalty ?? self.repetitionPenalty
        )
    }
}

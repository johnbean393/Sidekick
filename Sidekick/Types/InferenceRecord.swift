//
//  InferenceRecord.swift
//  Sidekick
//
//  Created by John Bean on 5/20/25.
//

import Foundation

public struct InferenceRecord: Identifiable, Codable {
    
    /// Stored property for `Identifiable` conformance
    public var id: UUID = UUID()
    
    /// A `String` for the name of the model used
    public var name: String
    
    /// A `Date` for the start time
    public var startTime: Date
    /// A `Date` for the end time
    public var endTime: Date = Date.now
    /// A `Float` for the duration of generation
    public var duration: Float {
        return Float(self.endTime.timeIntervalSince(self.startTime))
    }
    
    /// The `Type` of inference use
    public var type: UsageType
    /// A `URL` for the endpoint used
    public var endpoint: URL? = nil
    /// A `Bool` representing whether a remote server was used
    public var usedRemoteServer: Bool {
        return self.endpoint != nil
    }
    
    /// An `Int` for the number for input tokens
    public var inputTokens: Int
    /// An `Int` for the number for output tokens
    public var outputTokens: Int
    /// An `Int` for the total number of tokens
    public var totalTokens: Int {
        return self.inputTokens + self.outputTokens
    }
    /// A `Double` for the tokens per second, or generation speed
    public var tokensPerSecond: Double
    
    public enum UsageType: String, Codable, CaseIterable {
        
        case completions // Used for chat with an instruct tuned model
        case chatCompletions // Used for completions with a foundation model
        
        var description: String {
            switch self {
                case .completions:
                    return String(localized: "Completions")
                case .chatCompletions:
                    return String(localized: "Chat Completions")
            }
        }
        
    }
    
}


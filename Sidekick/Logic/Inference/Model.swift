//
//  Model.swift
//  Sidekick
//
//  Created by Bean John on 9/22/24.
//

import Foundation
import FSKit_macOS
import OSLog
import SimilaritySearchKit
import SwiftUI

/// An object which abstracts LLM inference
@MainActor
public class Model: ObservableObject {
    
    // MARK: - Logging
    
    static let logger: Logger = .init(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: Model.self)
    )
    
    // MARK: - Shared Instance
    
    static public let shared: Model = .init(
        systemPrompt: InferenceSettings.systemPrompt
    )
    
    // MARK: - Published State
    
    @Published public var wasRemoteServerAccessible: Bool = false
    @Published var pendingMessage: Message? = nil
    @Published var status: Status = .cold
    @Published var sentConversationId: UUID? = nil
    
    // MARK: - Model Servers
    
    var mainModelServer: LlamaServer
    var workerModelServer: LlamaServer
    
    // MARK: - Internal State
    
    var systemPrompt: String
    var startupTask: Task<Void, Never>?
    var lastRemoteServerCheck: Date = .distantPast
    var agent: (any Agent)?
    
    // MARK: - Initialization
    
    init(
        systemPrompt: String
    ) {
        // Make sure bookmarks are loaded
        let _ = Bookmarks.shared
        // Set system prompt
        self.systemPrompt = systemPrompt
        // Init LlamaServer objects
        self.mainModelServer = LlamaServer(
            modelType: .regular,
            systemPrompt: systemPrompt
        )
        self.workerModelServer = LlamaServer(
            modelType: .worker
        )
        self.scheduleStartupWarmup()
    }
    
    // MARK: - Model Selection
    
    public var selectedModelName: String? {
        // Check if remote model is accessible
        let useServer: Bool = InferenceSettings.useServer && self.wasRemoteServerAccessible
        // If using remote
        if useServer {
            // Get remote model name
            let remoteModelName: String = InferenceSettings.serverModelName
            if !remoteModelName.isEmpty {
                return remoteModelName
            }
        } else {
            // Else, return local model name
            if let localModelName: String = Settings.modelUrl?
                .deletingPathExtension()
                .lastPathComponent,
               !localModelName.isEmpty {
                return localModelName
            }
        }
        // If fell through, return nil
        return nil
    }
    
    public var selectedWorkerModelName: String? {
        // Check if remote model is accessible
        let useServer: Bool = InferenceSettings.useServer && self.wasRemoteServerAccessible
        // If using remote
        if useServer {
            // Get remote model name
            let remoteModelName: String = InferenceSettings.serverWorkerModelName
            if !remoteModelName.isEmpty {
                return remoteModelName
            }
        } else {
            // Else, return local model name
            if let localModelName: String = InferenceSettings.workerModelUrl?
                .deletingPathExtension()
                .lastPathComponent,
               !localModelName.isEmpty {
                return localModelName
            }
        }
        // If fell through, return nil
        return nil
    }
    
    public var selectedModel: KnownModel? {
        guard let identifier = self.selectedModelName else { return nil }
        var model = KnownModel(identifier: identifier)
        if identifier.hasSuffix(":thinking") {
            model?.isReasoningModel = true
        }
        return model
    }
    
    public var selectedModelCanReason: Bool? {
        return self.selectedModel?.isReasoningModel ?? selectedModelName?.hasSuffix(":thinking")
    }
    
    public var selectedWorkerModel: KnownModel? {
        guard let identifier = self.selectedWorkerModelName else { return nil }
        var model = KnownModel(identifier: identifier)
        if identifier.hasSuffix(":thinking") {
            model?.isReasoningModel = true
        }
        return model
    }
    
    public var selectedWorkerModelCanReason: Bool? {
        return self.selectedWorkerModel?.isReasoningModel ?? selectedWorkerModelName?.hasSuffix(":thinking")
    }

    public var canToggleLiveReasoning: Bool {
        let usingRemoteModel: Bool = InferenceSettings.useServer && self.wasRemoteServerAccessible
        guard !usingRemoteModel else {
            return false
        }
        return InferenceSettings.localModelSupportsLiveReasoningToggle()
    }
    
    // MARK: - Modes
    
    public enum Mode: String {
        
        /// Indicates the LLM is used as a chatbot, with extra features like resource lookup and code interpreter
        case chat
        /// Indicates the LLM is used as an agent
        case agent
        /// Indicates the LLM is used as an Deep Research agent
        case deepResearch
        /// Indicates the LLM is used for simple chat completion
        case `default`
        
        /// A `Bool` indiciating whether the mode is an agent
        var isAgent: Bool {
            switch self {
                case .agent, .deepResearch:
                    return true
                default:
                    return false
            }
        }
        
    }
    
}

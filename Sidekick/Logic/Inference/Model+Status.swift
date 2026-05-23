//
//  Model+Status.swift
//  Sidekick
//
//  Created by Bean John on 9/22/24.
//

import Foundation
import SwiftUI

enum InferenceRunContext {
    @TaskLocal static var conversationId: UUID?
}

extension Model {

    struct ChatRunState {
        let conversationId: UUID
        var pendingMessage: Message?
        var status: Status = .ready
        var mainRequestIDs: Set<UUID> = []
        var workerRequestIDs: Set<UUID> = []
        var task: Task<Void, Never>?
        var agent: (any Agent)?

        var isWorking: Bool {
            status.isWorking
        }

        mutating func addRequestID(
            _ requestID: UUID,
            modelType: ModelType
        ) {
            switch modelType {
                case .regular:
                    mainRequestIDs.insert(requestID)
                case .worker:
                    workerRequestIDs.insert(requestID)
            }
        }
    }

    func effectiveConversationId(
        _ conversationId: UUID?
    ) -> UUID? {
        conversationId ?? InferenceRunContext.conversationId
    }

    func chatRun(
        for conversationId: UUID?
    ) -> ChatRunState? {
        guard let conversationId else {
            return nil
        }
        return self.chatRuns[conversationId]
    }

    func isGenerating(
        conversationId: UUID?
    ) -> Bool {
        guard let conversationId else {
            return false
        }
        return self.chatRuns[conversationId]?.isWorking ?? false
    }

    func beginChatRun(
        conversationId: UUID,
        task: Task<Void, Never>? = nil
    ) {
        var run = self.chatRuns[conversationId] ?? ChatRunState(
            conversationId: conversationId
        )
        run.pendingMessage = nil
        run.status = .querying
        run.task = task ?? run.task
        run.mainRequestIDs.removeAll()
        run.workerRequestIDs.removeAll()
        self.chatRuns[conversationId] = run
        self.sentConversationId = conversationId
    }

    func setChatRunTask(
        _ task: Task<Void, Never>,
        for conversationId: UUID
    ) {
        var run = self.chatRuns[conversationId] ?? ChatRunState(
            conversationId: conversationId
        )
        run.task = task
        self.chatRuns[conversationId] = run
    }

    func finishChatRun(
        conversationId: UUID?
    ) {
        guard let conversationId else {
            self.pendingMessage = nil
            self.sentConversationId = nil
            self.status = .ready
            return
        }
        self.chatRuns.removeValue(forKey: conversationId)
        if self.sentConversationId == conversationId {
            self.sentConversationId = self.chatRuns.keys.first
        }
    }

    func registerRequestID(
        _ requestID: UUID,
        modelType: ModelType,
        conversationId: UUID?
    ) {
        guard let conversationId else {
            return
        }
        var run = self.chatRuns[conversationId] ?? ChatRunState(
            conversationId: conversationId
        )
        run.addRequestID(requestID, modelType: modelType)
        self.chatRuns[conversationId] = run
    }

    func requestIDHandler(
        modelType: ModelType,
        conversationId: UUID?
    ) -> (@Sendable (UUID) async -> Void)? {
        guard let conversationId else {
            return nil
        }
        return { requestID in
            await MainActor.run {
                self.registerRequestID(
                    requestID,
                    modelType: modelType,
                    conversationId: conversationId
                )
            }
        }
    }

    func agent(
        for conversationId: UUID?
    ) -> (any Agent)? {
        guard let conversationId else {
            return self.agent
        }
        return self.chatRuns[conversationId]?.agent
    }

    func setAgent(
        _ agent: (any Agent)?,
        conversationId: UUID?
    ) {
        guard let conversationId else {
            self.agent = agent
            return
        }
        var run = self.chatRuns[conversationId] ?? ChatRunState(
            conversationId: conversationId
        )
        run.agent = agent
        self.chatRuns[conversationId] = run
    }

}

extension Model {
    
    // MARK: - Pending Message Presentation
    
    public var displayedPendingMessage: Message {
        return self.displayedPendingMessage(for: nil)
    }

    public func displayedPendingMessage(
        for conversationId: UUID?
    ) -> Message {
        let run = self.chatRun(for: conversationId)
        let pendingMessage = run?.pendingMessage ?? self.pendingMessage
        let status = run?.status ?? self.status
        var text: String = ""
        let functionCalls: [FunctionCallRecord] = pendingMessage?.functionCallRecords ?? []
        switch status {
            case .cold, .coldProcessing, .processing, .backgroundTask, .ready:
                if let pendingText = pendingMessage?.text {
                    text = pendingText
                } else {
                    // Set default text
                    text = String(localized: "Processing...")
                    // Get model name
                    if let modelName: String = ChatParameters.getModelName(
                        modelType: .regular
                    ) {
                        // Determine if is reasoning model
                        if KnownModel.availableModels.contains(
                            where: { model in
                                let nameMatches: Bool = modelName.contains(
                                    model.primaryName
                                )
                                return nameMatches && model.isReasoningModel
                            }
                        ) {
                            text = String(localized: "Thinking...")
                        }
                    }
                }
            case .querying:
                text = String(localized: "Searching...")
            case .generatingTitle:
                text = String(localized: "Generating title...")
            case .usingFunctions:
                // If no calls found or if all calls are complete
                text = String(localized: "Calling functions...")
                // Show progress
                if let pendingText = pendingMessage?.text,
                   !pendingText.isEmpty {
                    text = pendingText
                }
            case .deepResearch:
                text = String(localized: "Preparing Deep Research...")
        }
        if var pendingMessage = pendingMessage {
            pendingMessage.text = text
            pendingMessage.functionCallRecords = functionCalls
            return pendingMessage
        } else {
            return Message(
                text: text,
                sender: .assistant
            )
        }
    }
    
    public var pendingMessageView: some View {
        Group {
            switch self.displayedContentType {
                case .text, .indicator:
                    MessageView(
                        message: self.displayedPendingMessage,
                        shimmer: self.displayedContentType == .indicator
                    )
                    .id(self.displayedPendingMessage.id)
                case .preview:
                    self.agent?.preview ?? AnyView(EmptyView())
            }
        }
    }
    
    public var displayedContentType: DisplayedContentType {
        return self.displayedContentType(for: nil)
    }

    public func displayedContentType(
        for conversationId: UUID?
    ) -> DisplayedContentType {
        let run = self.chatRun(for: conversationId)
        let pendingMessage = run?.pendingMessage ?? self.pendingMessage
        let status = run?.status ?? self.status
        let hasText: Bool = {
            if let text = pendingMessage?.text {
                return !text.isEmpty
            }
            return false
        }()
        switch status {
            case .cold, .coldProcessing, .processing, .backgroundTask, .ready, .usingFunctions:
                return !hasText ? .indicator : .text
            case .deepResearch:
                return (run?.agent ?? self.agent) == nil ? .indicator : .preview
            case .querying, .generatingTitle:
                return .indicator
        }
    }
    
    public enum DisplayedContentType: CaseIterable {
        case indicator, text, preview
    }
    
    // MARK: - Status Management
    
    public func setStatus(_ newStatus: Status) {
        self.setStatus(
            newStatus,
            conversationId: InferenceRunContext.conversationId
        )
    }

    public func setStatus(
        _ newStatus: Status,
        conversationId: UUID?
    ) {
        if let conversationId {
            var run = self.chatRuns[conversationId] ?? ChatRunState(
                conversationId: conversationId
            )
            run.status = newStatus
            self.chatRuns[conversationId] = run
        } else {
            self.status = newStatus
        }
    }
    
    var isProcessing: Bool {
        return status == .processing || status == .coldProcessing
    }

    func isProcessing(
        conversationId: UUID?
    ) -> Bool {
        guard let conversationId else {
            return self.isProcessing
        }
        guard let run = self.chatRuns[conversationId] else {
            return false
        }
        return run.status == .processing || run.status == .coldProcessing
    }
    
    func setSentConversationId(_ id: UUID) {
        // Reset pending message
        self.beginChatRun(conversationId: id)
    }
    
    func indicateStartedNamingConversation() {
        // Reset pending message
        self.pendingMessage = nil
        self.status = .generatingTitle
    }
    
    func indicateStartedBackgroundTask() {
        // Reset pending message
        self.pendingMessage = nil
        self.status = .backgroundTask
    }
    
    func indicateStartedQuerying() {
        self.indicateStartedQuerying(
            conversationId: InferenceRunContext.conversationId
        )
    }

    func indicateStartedQuerying(
        conversationId: UUID?
    ) {
        if let conversationId {
            self.beginChatRun(conversationId: conversationId)
        } else {
            // Reset pending message
            self.pendingMessage = nil
            self.status = .querying
        }
    }
    
    func indicateStartedDeepResearch() {
        self.indicateStartedDeepResearch(
            conversationId: InferenceRunContext.conversationId
        )
    }

    func indicateStartedDeepResearch(
        conversationId: UUID?
    ) {
        if let conversationId {
            var run = self.chatRuns[conversationId] ?? ChatRunState(
                conversationId: conversationId
            )
            run.pendingMessage = nil
            run.status = .deepResearch
            self.chatRuns[conversationId] = run
        } else {
            // Reset pending message
            self.pendingMessage = nil
            self.status = .deepResearch
        }
    }

    func pendingMessage(
        for conversationId: UUID?
    ) -> Message? {
        guard let conversationId else {
            return self.pendingMessage
        }
        return self.chatRuns[conversationId]?.pendingMessage
    }

    func setPendingMessage(
        _ message: Message?,
        conversationId: UUID?
    ) {
        guard let conversationId else {
            self.pendingMessage = message
            return
        }
        var run = self.chatRuns[conversationId] ?? ChatRunState(
            conversationId: conversationId
        )
        run.pendingMessage = message
        self.chatRuns[conversationId] = run
    }

    func updatePendingMessage(
        conversationId: UUID?,
        _ update: (inout Message?) -> Void
    ) {
        if let conversationId {
            var run = self.chatRuns[conversationId] ?? ChatRunState(
                conversationId: conversationId
            )
            update(&run.pendingMessage)
            self.chatRuns[conversationId] = run
        } else {
            update(&self.pendingMessage)
        }
    }
    
}

// MARK: - Status Enum

extension Model {
    
    public enum Status: String {
        
        /// The inference server is inactive
        case cold
        /// The inference server is warming up
        case coldProcessing
        /// The inference server is currently processing a prompt
        case processing
        /// The system is searching in the selected profile's resources.
        case querying
        /// The system is generating a title
        case generatingTitle
        /// The system is running a background task
        case backgroundTask
        /// The system is using a function
        case usingFunctions
        /// The system is doing deep research
        case deepResearch
        /// The inference server is awaiting a prompt
        case ready
        
        /// A `Bool` representing if the server is at work
        public var isWorking: Bool {
            switch self {
                case .cold, .ready:
                    return false
                default:
                    return true
            }
        }
        
        /// A `Bool` representing if the server is running a foreground task
        public var isForegroundTask: Bool {
            switch self {
                case .backgroundTask, .generatingTitle, .usingFunctions:
                    return false
                default:
                    return true
            }
        }
        
    }
    
}

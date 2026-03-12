//
//  PromptInputField.swift
//  Sidekick
//
//  Created by Bean John on 10/23/24.
//

import OSLog
import SimilaritySearchKit
import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct PromptInputField: View {
    
    /// A `Logger` object for the `PromptInputField` object
    private static let logger: Logger = .init(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: PromptInputField.self)
    )
    
    @AppStorage("useCommandReturn") private var useCommandReturn: Bool = Settings.useCommandReturn
    var sendShortcutDescription: Text {
        return Text(
            Settings.SendShortcut(self.useCommandReturn).rawValue
        )
        .italic()
    }
    
    @EnvironmentObject private var model: Model
    @EnvironmentObject private var conversationManager: ConversationManager
    @EnvironmentObject private var expertManager: ExpertManager
    @EnvironmentObject private var conversationState: ConversationState
    @EnvironmentObject private var promptController: PromptController
    @EnvironmentObject private var canvasController: CanvasController
    
    @FocusState var isFocused: Bool
    
    // NSEvent monitor token
    @State private var keyEventMonitor: Any?
    @State private var delayedClearTask: DispatchWorkItem?
    @State private var lastShowReasoningToggle: Bool = false
    
    var selectedConversation: Conversation? {
        guard let selectedConversationId = conversationState.selectedConversationId else {
            return nil
        }
        return self.conversationManager.getConversation(
            id: selectedConversationId
        )
    }
    
    var selectedExpert: Expert? {
        guard let selectedExpertId = conversationState.selectedExpertId else {
            return nil
        }
        return expertManager.getExpert(id: selectedExpertId)
    }
    
    var messages: [Message] {
        return selectedConversation?.messages ?? []
    }
    
    var showQuickPrompts: Bool {
        return promptController.prompt.isEmpty && messages.isEmpty
    }

    var showReasoningToggle: Bool {
        return self.model.canToggleLiveReasoning
    }
    
    var addFilesTip: AddFilesTip = .init()
    
    var buttonFillColor: Color {
        return self.promptController.isRecording ? Color.red : Color.accentColor
    }
    
    var body: some View {
        textField
            .onExitCommand {
                self.isFocused = false
            }
            .onChange(
                of: self.isFocused
            ) {
                // Show add files and dictation tips if needed
                if self.isFocused {
                    AddFilesTip.readyForAddingFiles = true
                }
            }
            .onChange(
                of: conversationState.selectedConversationId
            ) {
                self.isFocused = true
                self.handleModelChange(forceDefault: true)
            }
            .onChange(
                of: conversationState.selectedExpertId
            ) {
                // If web search can be used
                if RetrievalSettings.canUseWebSearch,
                   let useWebSearch = self.selectedExpert?.useWebSearch {
                    // Sync web search settings
                    withAnimation(.linear) {
                        self.promptController.useWebSearch = useWebSearch
                    }
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: Notifications.changedInferenceConfig.name
                )
            ) { output in
                withAnimation(.linear) {
                    // Handle model change
                    self.handleModelChange()
                }
            }
            .onAppear {
                self.isFocused = true
                self.setupKeyEventMonitor()
                self.handleModelChange(forceDefault: true)
            }
            .onDisappear {
                self.removeKeyEventMonitor()
                self.cancelDelayedClear()
            }
            .onChange(of: self.promptController.prompt) { newValue in
                if !newValue.isEmpty {
                    self.cancelDelayedClear()
                }
            }
            .popoverTip(addFilesTip)
    }
    
    var textField: some View {
        ChatPromptEditor(
            isFocused: self._isFocused,
            isRecording: self.$promptController.isRecording,
            useAttachments: true,
            bottomOptions: true,
            cornerRadius: 22
        )
        .focused(self.$isFocused)
        .submitLabel(.send)
        .overlay(alignment: .leading) {
            AttachmentSelectionButton { url in
                await self.promptController.addFile(url)
            }
        }
        .overlay(alignment: .trailing) {
            DictationButton()
        }
        .overlay(alignment: .bottomLeading) {
            HStack {
                if self.showReasoningToggle {
                    ReasoningToggleButton(
                        activatedFillColor: self.buttonFillColor,
                        useReasoning: self.$promptController.useReasoning
                    )
                }
                SearchMenuToggleButton(
                    activatedFillColor: self.buttonFillColor,
                    useWebSearch: self.$promptController.useWebSearch,
                    selectedSearchState: self.$promptController.selectedSearchState
                )
                UseFunctionsButton(
                    activatedFillColor: self.buttonFillColor,
                    useFunctions: self.$promptController.useFunctions
                )
            }
            .padding(.leading, 32)
            .padding(.bottom, 10)
            .frame(height: 25)
        }
        .padding([.vertical, .leading], 10)
        .onDrop(
            of: [
                UTType.fileURL,
                UTType.image,
                UTType.png,
                UTType.tiff
            ],
            delegate: self.promptController
        )
    }
    
    /// Set up NSEvent keyDown monitor
    private func setupKeyEventMonitor() {
        // Remove previous monitor if any
        self.removeKeyEventMonitor()
        // Only monitor when focused
        if self.keyEventMonitor == nil {
            self.keyEventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.keyDown]
            ) { event in
                // Only process if this view and window is focused
                if self.isFocused, event.window?.isMainWindow == true && event.window?.title.isEmpty == true {
                    if self.handleKeyDownEvent(event) {
                        return nil // handled, suppress
                    }
                }
                return event
            }
        }
    }
    
    /// Remove NSEvent monitor if exists (macOS only)
    private func removeKeyEventMonitor() {
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }
    }
    
    /// Handle NSEvent keyDown events (macOS only)
    @discardableResult
    private func handleKeyDownEvent(_ event: NSEvent) -> Bool {
        // Only interested in Return/Enter
        let isReturnKeyDown = (event.keyCode == 36) || (event.keyCode == 76) // 36 = Return, 76 = Numpad Enter
        if isReturnKeyDown {
            let isCommandKeyDown = event.modifierFlags.contains(.command)
            let isShiftKeyDown = event.modifierFlags.contains(.shift)
            let isOptionKeyDown = event.modifierFlags.contains(.option)
            let noModifiers = event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty
            
            Self.logger.info("Received key press with key \"\(event.characters ?? "nil", privacy: .public)\" and modifiers \"\(event.modifierFlags.rawValue, privacy: .public)\"")
            
            if isCommandKeyDown && self.useCommandReturn {
                // Send if command key is down and required
                self.onSubmit()
                return true
            } else if !self.useCommandReturn && noModifiers {
                // Else, if command key is not required, send
                self.onSubmit()
                return true
            } else if isShiftKeyDown || isOptionKeyDown || (self.useCommandReturn && noModifiers) {
                // Insert newline at cursor
                let index: String.Index = self.promptController.prompt.index(
                    utf16Distance: self.promptController.insertionPoint
                )
                DispatchQueue.main.async {
                    withAnimation {
                        self.promptController.prompt.insert(
                            "\n",
                            at: index
                        )
                        self.promptController.insertionPoint += 1
                    }
                }
                return true
            }
        }
        return false
    }
    
    /// Function to run when the `return` key is hit
    private func onSubmit() {
        // If not blank, submit
        if promptController.prompt.trimmingCharacters(in: .whitespacesAndNewlines) != "" {
            // End recording
            self.promptController.stopRecording()
            // Send message
            self.submit()
        }
    }
    
    /// Function to send to bot
    private func submit() {
        // Get previous content
        guard var conversation = selectedConversation else { return }
        // Check if last message was successful
        if let prevMessage: Message = conversation.messages.last {
            // If unsuccessful
            let wasAssistant: Bool = prevMessage.getSender() == .assistant
            if prevMessage.text.isEmpty && prevMessage.imageUrl == nil && wasAssistant {
                // Tell user to retry
                Dialogs.showAlert(
                    title: String(localized: "Retry"),
                    message: String(localized: "Please retry your previous message.")
                )
                return
            }
        }
        // Make sound
        if Settings.playSoundEffects {
            SoundEffects.send.play()
        }
        // Get prompt expected result type
        var resultType: PromptAnalyzer.ResultType = .text
        if !self.promptController.isUsingDeepResearch {
            resultType = PromptAnalyzer.getExpectedResultType(
                promptController.prompt
            )
        }
        // Check web search
        if !self.checkWebSearch() {
            return
        }
        // Persist temporary resources to cache so that they remain available for the conversation
        let persistenceResult: (urls: [URL], resources: [TemporaryResource]) = self.persistTemporaryResources(
            self.promptController.tempResources,
            conversationId: conversation.id
        )
        let savedResourceURLs: [URL] = persistenceResult.urls
        let currentMessageResources: [TemporaryResource] = persistenceResult.resources
        // Make request message
        let newUserMessage: Message = Message(
            text: promptController.prompt,
            sender: .user,
            referencedURLs: savedResourceURLs
        )
        var updatedConversation: Conversation = conversation
        let didAddMessage: Bool = updatedConversation.addMessage(newUserMessage)
        if !didAddMessage {
            Dialogs.showAlert(
                title: String(localized: "Error"),
                message: String(localized: "Failed to add message. Please try again.")
            )
            return
        }
        conversation = updatedConversation
        conversationManager.update(updatedConversation)
        self.promptController.sentConversation = updatedConversation
        self.promptController.sentExpertId = self.conversationState.selectedExpertId
        // Capture temp resources
        let tempResources: [TemporaryResource] = currentMessageResources
        // If result type is text, send message
        switch resultType {
            case .text:
                self.startTextGeneration(
                    prompt: promptController.prompt,
                    tempResources: tempResources
                )
            case .image:
                // If image generation is available, start generating image
                if PromptAnalyzer.ResultType.image.isAvailable {
                    self.startImageGeneration()
                } else {
                    // Else, fall back to text
                    self.startTextGeneration(
                        prompt: promptController.prompt,
                        tempResources: tempResources
                    )
                }
        }
        DispatchQueue.main.async {
            withAnimation(.linear) {
                self.promptController.tempResources.removeAll()
            }
        }
        // Clear prompt
        self.clearInputs()
        self.scheduleDelayedClear()
    }
    
    private func startTextGeneration(
        prompt: String,
        tempResources: [TemporaryResource]
    ) {
        // Get response
        Task {
            await self.generateChatResponse(
                prompt: prompt,
                tempResources: tempResources
            )
        }
    }
    
    private func startImageGeneration() {
        if #available(macOS 15.2, *) {
            // Start generation
            self.promptController.imageConcept = self.promptController.prompt
            self.promptController.isGeneratingImage = true
            // Reset sent properties
            self.promptController.sentConversation = nil
        }
    }
    
    private func clearInputs() {
        DispatchQueue.main.async {
            self.handleModelChange(forceDefault: true)
            self.promptController.prompt.removeAll()
            self.promptController.insertionPoint = 0
        }
    }
    
    private func persistTemporaryResources(
        _ resources: [TemporaryResource],
        conversationId: UUID
    ) -> (urls: [URL], resources: [TemporaryResource]) {
        guard !resources.isEmpty else {
            return ([], [])
        }
        let rootDirectory: URL = Settings
            .cacheUrl
            .appendingPathComponent("Temporary Resources", isDirectory: true)
        let conversationDirectory: URL = rootDirectory
            .appendingPathComponent(conversationId.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: conversationDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            Self.logger.error("Failed to create temporary resources directory: \(error.localizedDescription, privacy: .public)")
        }
        var savedUrls: [URL] = []
        var savedResources: [TemporaryResource] = []
        for resource in resources {
            let originalName: String = {
                let lastPathComponent: String = resource.url.lastPathComponent
                if lastPathComponent.isEmpty {
                    return resource.id.uuidString
                }
                return lastPathComponent
            }()
            var destinationURL: URL = conversationDirectory.appendingPathComponent(originalName, isDirectory: false)
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                destinationURL = self.uniqueDestination(
                    for: originalName,
                    within: conversationDirectory
                )
            }
            var finalURL: URL = destinationURL
            if resource.url.isFileURL {
                do {
                    try FileManager.default.copyItem(
                        at: resource.url,
                        to: destinationURL
                    )
                } catch {
                    Self.logger.error("Failed to persist temporary resource \"\(resource.url.lastPathComponent, privacy: .public)\": \(error.localizedDescription, privacy: .public)")
                    finalURL = resource.url
                }
            } else {
                finalURL = resource.url
            }
            var persistedResource: TemporaryResource = resource
            persistedResource.url = finalURL
            savedUrls.append(finalURL)
            savedResources.append(persistedResource)
        }
        return (savedUrls, savedResources)
    }
    
    private func uniqueDestination(
        for filename: String,
        within directory: URL
    ) -> URL {
        let rawName: String = (filename as NSString).deletingPathExtension
        let name: String = rawName.isEmpty ? UUID().uuidString : rawName
        let fileExtension: String = (filename as NSString).pathExtension
        var attempt: Int = 1
        var candidate: URL
        repeat {
            let suffix: String = "\(name)-\(attempt)"
            let candidateName: String = fileExtension.isEmpty ? suffix : "\(suffix).\(fileExtension)"
            candidate = directory.appendingPathComponent(candidateName, isDirectory: false)
            attempt += 1
        } while FileManager.default.fileExists(atPath: candidate.path)
        return candidate
    }
    
    private func conversationTemporaryResources(
        for conversation: Conversation,
        currentResources: [TemporaryResource]
    ) async -> [TemporaryResource] {
        func normalized(_ url: URL) -> URL {
            if url.isFileURL {
                return url.standardizedFileURL
            }
            return url
        }
        var resourceMap: [URL: TemporaryResource] = [:]
        var orderedKeys: [URL] = []
        for resource in currentResources {
            let key: URL = normalized(resource.url)
            if resourceMap[key] == nil {
                orderedKeys.append(key)
            }
            resourceMap[key] = resource
        }
        for message in conversation.messages where message.getSender() == .user {
            for referenced in message.referencedURLs {
                let key: URL = normalized(referenced.url)
                var resource: TemporaryResource
                if let existingResource: TemporaryResource = resourceMap[key] {
                    resource = existingResource
                } else {
                    orderedKeys.append(key)
                    resource = TemporaryResource(url: referenced.url)
                }
                if resource.text == nil, resource.url.isFileURL {
                    let _ = await resource.scan()
                }
                resourceMap[key] = resource
            }
        }
        return orderedKeys.compactMap { resourceMap[$0] }
    }
    
    private func generateChatResponse(
        prompt: String,
        tempResources: [TemporaryResource]
    ) async {
        // If processing, use recursion to update
        if (model.status == .processing || model.status == .coldProcessing) {
            Task {
                await model.interrupt()
                Task.detached(priority: .userInitiated) {
                    try? await Task.sleep(for: .seconds(1))
                    await generateChatResponse(
                        prompt: prompt,
                        tempResources: tempResources
                    )
                }
            }
            return
        }
        // Get and save conversation
        guard var conversation = self.promptController.sentConversation else { return }
        let originalConversation: Conversation = conversation
        let preparedResources: [TemporaryResource] = await self.conversationTemporaryResources(
            for: conversation,
            currentResources: tempResources
        )
        self.model.setSentConversationId(conversation.id)
        // Generate title & update again
        let isFirstMessage: Bool = conversation.messages.count <= 1
        let shouldGenerateConversationTitle: Bool = Settings.generateConversationTitles && isFirstMessage
        let initialConversationTitle: String = conversation.title
        // Get response
        var response: LlamaServer.CompleteResponse
        var didUseSources: Bool = false
        do {
            self.model.indicateStartedQuerying()
            var index: SimilarityIndex? = nil
            // If there are resources
            if !((selectedExpert?.resources.resources.isEmpty) ?? true) {
                // Load
                index = await selectedExpert?.resources.loadIndex()
            }
            let useWebSearch: Bool = self.promptController.useWebSearch
            // Set if sources were used
            let hasIndexItems: Bool = !((
                index?.indexItems.isEmpty
            ) ?? true)
            didUseSources = useWebSearch || hasIndexItems || !preparedResources.isEmpty
            // Get mode
            let mode: Model.Mode = self.promptController.isUsingDeepResearch ? .deepResearch : .chat
            // Get response
            response = try await model.listenThinkRespond(
                messages: conversation.messages,
                modelType: .regular,
                mode: mode,
                similarityIndex: index,
                useWebSearch: useWebSearch,
                useFunctions: self.promptController.useFunctions,
                expert: selectedExpert,
                enableThinking: self.showReasoningToggle ? self.promptController.useReasoning : nil,
                useCanvas: self.conversationState.useCanvas,
                canvasSelection: self.canvasController.selection,
                temporaryResources: preparedResources,
                showPreview: true
            )
        } catch let error as LlamaServerError {
            await model.interrupt()
            // Don't show error dialog for user-initiated cancellation
            if case .cancelled = error {
                await self.handleCancellation(originalConversation: originalConversation)
            } else {
                await self.handleResponseError(
                    error,
                    originalConversation: originalConversation
                )
            }
            return
        } catch {
            print("Agent listen threw unexpected error", error as Any)
            return
        }
        // Update UI
        await MainActor.run {
            // Output final output to debug console
            // Make response message
            var responseMessage: Message = Message(
                text: response.text,
                sender: .assistant,
                model: response.modelName,
                functionCallRecords: response.functionCallRecords,
                expertId: promptController.sentExpertId
            )
            responseMessage.update(
                response: response,
                includeReferences: didUseSources
            )
            responseMessage.end()
            // Update conversation
            let _ = conversation.addMessage(
                responseMessage
            )
            conversation.tokenCount = response.usage?.total_tokens
            self.conversationManager.update(conversation)
            // Make sound
            if Settings.playSoundEffects {
                SoundEffects.ping.play()
            }
            // Reset sentConversation
            self.promptController.sentConversation = nil
        }
        if shouldGenerateConversationTitle {
            let conversationId: UUID = conversation.id
            Task {
                guard let title = try? await self.generateConversationTitle(
                    prompt: prompt
                ), !title.isEmpty else {
                    return
                }
                await MainActor.run {
                    guard var existingConversation = self.conversationManager.getConversation(
                        id: conversationId
                    ) else {
                        return
                    }
                    guard existingConversation.title == initialConversationTitle else {
                        return
                    }
                    existingConversation.title = title
                    withAnimation(.linear) {
                        self.conversationManager.update(existingConversation)
                    }
                }
            }
        }
        // Memorize content if needed
        if RetrievalSettings.useMemory,
           let assistantMessage: Message = conversation.messages.last,
           let userMessage: Message = conversation.messages.dropLast(1).last,
           assistantMessage.getSender() == .assistant,
           userMessage.getSender() == .user {
            await Memories.shared.rememberIfNeeded(
                messageId: assistantMessage.id,
                text: userMessage.text
            )
        }
    }
    
    /// Function to generate a title for the conversation
    private func generateConversationTitle(
        prompt: String
    ) async throws -> String? {
        let canReachRemoteServer: Bool = await model.remoteServerIsReachable()
        let usingRemoteModel: Bool = canReachRemoteServer && InferenceSettings.useServer
        let hasDedicatedWorkerModel: Bool = {
            guard let workerModelUrl = InferenceSettings.workerModelUrl else {
                return false
            }
            return FileManager.default.fileExists(
                atPath: workerModelUrl.path
            )
        }()
        let targetServer: LlamaServer = (usingRemoteModel || hasDedicatedWorkerModel) ? model.workerModelServer : model.mainModelServer
        // Formulate messages
        let generateTitleMessage: Message = Message(
            text: """
A user is chatting with an assistant and they have sent the message below. Generate an extremely short label for the chat session. Actively remove details from the user's message to make the label sho[...]

"\(prompt)"
""",
            sender: .user
        )
        let messages: [Message] = [
            generateTitleMessage
        ]
        let messageSubsets: [Message.MessageSubset] = await messages.asyncMap { message in
            await Message.MessageSubset(
                modelType: .worker,
                usingRemoteModel: usingRemoteModel,
                message: message
            )
        }
        // Generate
        let title: String = try await targetServer.getChatCompletion(
            mode: .default,
            canReachRemoteServer: canReachRemoteServer,
            messages: messageSubsets
        ).text
        // Reset pending message text
        self.model.pendingMessage = nil
        // Return
        return title
            .reasoningRemoved
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .capitalizeEachWord
            .dropPrefixIfPresent("\"")
            .dropSuffixIfPresent("\"")
    }
    
    @MainActor
    private func handleResponseError(
        _ error: LlamaServerError,
        originalConversation: Conversation
    ) {
        // Display error message
        let errorDescription: String = error.errorDescription ?? "Unknown Error"
        let recoverySuggestion: String = error.recoverySuggestion
        Dialogs.showAlert(
            title: errorDescription,
            message: recoverySuggestion
        )
        // Restore prompt if nothing new has been typed and we restored the conversation
        let didRevert: Bool = self.revertConversationAfterFailure(originalConversation)
        if didRevert,
           self.promptController.prompt.isEmpty,
           let prompt: String = originalConversation.messages.last?.text {
            self.promptController.prompt = prompt
        }
        // Reset model status
        self.model.status = .ready
        self.model.sentConversationId = nil
        self.promptController.sentConversation = nil
    }
    
    @MainActor
    private func handleCancellation(
        originalConversation: Conversation
    ) {
        // Don't show error dialog for user-initiated cancellation
        // Just clean up the state silently
        let didRevert: Bool = self.revertConversationAfterFailure(originalConversation)
        if didRevert,
           self.promptController.prompt.isEmpty,
           let prompt: String = originalConversation.messages.last?.text {
            self.promptController.prompt = prompt
        }
        // Reset model status
        self.model.status = .ready
        self.model.sentConversationId = nil
        self.promptController.sentConversation = nil
    }
    
    @MainActor
    private func revertConversationAfterFailure(
        _ originalConversation: Conversation
    ) -> Bool {
        guard let lastMessage: Message = originalConversation.messages.last else {
            return false
        }
        guard var activeConversation: Conversation = self.conversationManager.getConversation(
            id: originalConversation.id
        ) else {
            return false
        }
        guard !activeConversation.messages.isEmpty else {
            return false
        }
        guard activeConversation.messages.last?.id == lastMessage.id else {
            return false
        }
        activeConversation.messages = Array(activeConversation.messages.dropLast())
        self.conversationManager.update(activeConversation)
        return true
    }
    
    /// Function to check if web search can be used
    private func checkWebSearch() -> Bool {
        // If web search is on, but cannot be used
        let success: Bool = !(!RetrievalSettings.canUseWebSearch && self.promptController.useWebSearch)
        if !success {
            // Show dialog
            Dialogs.showAlert(
                title: String(localized: "Search not configured"),
                message: String(localized: "Search is not configured. Please configure it in \"Settings\" -> \"Retrieval\".")
            )
            self.promptController.useWebSearch = false
        }
        return success
    }
    
    private func handleModelChange(
        forceDefault: Bool = false
    ) {
        let showReasoningToggle = self.showReasoningToggle
        defer {
            self.lastShowReasoningToggle = showReasoningToggle
        }
        guard !showReasoningToggle else {
            if forceDefault || !self.lastShowReasoningToggle || !self.promptController.didManuallyToggleReasoning {
                self.promptController.resetReasoningToDefault(
                    reasoningAvailable: true
                )
            }
            return
        }
        self.promptController.resetReasoningToDefault(
            reasoningAvailable: false
        )
    }
    
    private func scheduleDelayedClear() {
        self.cancelDelayedClear()
        let task = DispatchWorkItem {
            if self.promptController.prompt.isEmpty {
                self.clearInputs()
            }
            self.delayedClearTask = nil
        }
        self.delayedClearTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: task)
    }
    
    private func cancelDelayedClear() {
        self.delayedClearTask?.cancel()
        self.delayedClearTask = nil
    }
    
}

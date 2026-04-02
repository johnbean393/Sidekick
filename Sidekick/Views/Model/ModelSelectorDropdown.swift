//
//  ModelSelectorDropdown.swift
//  Sidekick
//
//  Created by John Bean on 11/5/25.
//

import SwiftUI

struct ModelSelectorDropdown: View {
    
    @Environment(\.colorScheme) private var colorScheme
    
    @EnvironmentObject private var expertManager: ExpertManager
    @EnvironmentObject private var conversationState: ConversationState
    
    @AppStorage("endpoint") private var serverEndpoint: String = InferenceSettings.endpoint
    @Binding var serverModelName: String
    @AppStorage("serverModelHasVision") private var serverModelHasVision: Bool = InferenceSettings.serverModelHasVision
    
    @State private var remoteModelNames: [String] = []
    @State private var customModelNames: [String] = InferenceSettings.customModelNames
    @State private var isManagingCustomModel: Bool = false
    @State private var showingDropdown: Bool = false
    @State private var searchText: String = ""
    @State private var localModelsListId: UUID = UUID()
    @State private var remoteServerReachable: Bool = false
    
    @StateObject private var modelManager: ModelManager = .shared
    @EnvironmentObject private var model: Model
    
    // Scroll to active model
    @State private var scrollToLocal: Bool = false
    @State private var scrollToRemote: Bool = false
    
    var selectedExpert: Expert? {
        guard let selectedExpertId = conversationState.selectedExpertId else {
            return nil
        }
        return expertManager.getExpert(id: selectedExpertId)
    }
    
    var toolbarTextColor: Color {
        guard let selectedExpert = selectedExpert else {
            return .primary
        }
        // Use the same logic as expert label/icon for consistency
        return selectedExpert.color.adaptedTextColor
    }
    
    // Get the current model name for display
    var currentModelName: String {
        if let selectedModelName = model.selectedModelName {
            return formatModelName(selectedModelName)
        } else if InferenceSettings.useServer {
            return serverModelName.isEmpty ? "No Model Selected" : formatModelName(serverModelName)
        } else {
            return "No Model Selected"
        }
    }
    
    // Format model name for toolbar display
    private func formatModelName(_ name: String) -> String {
        let components = parseModelIdentifier(name)
        
        if let knownModel = KnownModel.findModel(byIdentifier: name, in: KnownModel.availableModels) {
            var displayName: String
            if let explicitName = knownModel.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !explicitName.isEmpty {
                displayName = explicitName
            } else {
                // For unknown organizations, use the stored organizationIdentifier
                let providerSource: String
                if knownModel.organization == .other, let orgId = knownModel.organizationIdentifier {
                    providerSource = orgId
                } else {
                    providerSource = components.provider ?? knownModel.organization.rawValue
                }
                // Use the matched model's variant, not the original identifier's variant
                let matchedComponents = parseModelIdentifier(knownModel.primaryName)
                let baseName = String(knownModel.primaryName.split(separator: ":").first ?? Substring(knownModel.primaryName))
                displayName = buildDisplayName(provider: providerSource, model: baseName, variant: matchedComponents.variant)
            }
            // For unknown organizations, use the stored organizationIdentifier
            let providerForPrefix: String
            if knownModel.organization == .other, let orgId = knownModel.organizationIdentifier {
                providerForPrefix = orgId
            } else {
                providerForPrefix = components.provider ?? knownModel.organization.rawValue
            }
            displayName = applyProviderPrefixIfNeeded(displayName, provider: providerForPrefix)
            // Use the matched model's variant for harmonization, not the original
            let matchedComponents = parseModelIdentifier(knownModel.primaryName)
            displayName = harmonizeVariantDisplay(displayName, expectedVariant: matchedComponents.variant)
            return displayName
        }
        
        return buildDisplayName(provider: components.provider, model: components.model, variant: components.variant)
    }
    
    private func parseModelIdentifier(_ name: String) -> (provider: String?, model: String, variant: String?) {
        var remainder = name
        var provider: String? = nil
        if let slashIndex = remainder.firstIndex(of: "/") {
            provider = String(remainder[..<slashIndex])
            remainder = String(remainder[remainder.index(after: slashIndex)...])
        }
        var variant: String? = nil
        if let colonIndex = remainder.firstIndex(of: ":") {
            variant = String(remainder[remainder.index(after: colonIndex)...])
            remainder = String(remainder[..<colonIndex])
        }
        return (provider, remainder, variant)
    }
    
    private func buildDisplayName(provider: String?, model: String, variant: String?) -> String {
        let formattedModel = formatModelComponent(model)
        var result = ""
        if let provider {
            result = "\(formatProviderName(provider)): "
        }
        result += formattedModel
        if let variant = variant?.trimmingCharacters(in: .whitespacesAndNewlines), !variant.isEmpty {
            let lowerVariant = variant.lowercased()
            if Self.variantSuffixTokens.contains(lowerVariant) {
                result += " (\(lowerVariant))"
            } else {
                result += " \(variant)"
            }
        }
        return result
    }
    
    private func formatProviderName(_ provider: String) -> String {
        return (provider.prefix(1).uppercased() + provider.dropFirst().lowercased())
            .replacingOccurrences(of: "Bytedance", with: "ByteDance")
            .replacingOccurrences(of: "Openrouter", with: "OpenRouter")
            .replacingOccurrences(of: "Deepseek", with: "DeepSeek")
            .replacingOccurrences(of: "Deepcogito", with: "DeepCogito")
            .replacingOccurrences(of: "X-ai", with: "xAI")
            .replacingOccurrences(of: "Meta-llama", with: "Meta-Llama")
            .replacingOccurrences(of: "Minimax", with: "MiniMax")
            .replacingOccurrences(of: "Z-ai", with: "Zhipu AI")
            .replacingOccurrences(of: "Nousresearch", with: "NousResearch")
            .replacingSuffix("ai", with: "AI")
            .replacingSuffix("org", with: "Org")
            .replacingSuffix("labs", with: "Labs")
    }
    
    private func formatModelComponent(_ model: String) -> String {
        var spacedResult = ""
        for (index, char) in model.enumerated() {
            if char.isUppercase && index > 0 {
                let previousIndex = model.index(model.startIndex, offsetBy: index - 1)
                if model[previousIndex].isLowercase {
                    spacedResult += " "
                }
            }
            spacedResult.append(char)
        }
        let condensed = spacedResult.components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return condensed.lowercased()
    }
    
    private func applyProviderPrefixIfNeeded(_ displayName: String, provider: String?) -> String {
        guard let provider else { return displayName.trimmingCharacters(in: .whitespacesAndNewlines) }
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(":") {
            return trimmed
        }
        return "\(formatProviderName(provider)): \(trimmed)"
    }
    
    private func harmonizeVariantDisplay(_ displayName: String, expectedVariant rawVariant: String?) -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rawVariant = rawVariant?.trimmingCharacters(in: .whitespacesAndNewlines), !rawVariant.isEmpty else {
            return removeRecognizedVariantSuffix(from: trimmed)
        }
        let lowerVariant = rawVariant.lowercased()
        if Self.variantSuffixTokens.contains(lowerVariant) {
            if trimmed.range(of: "(\(lowerVariant))", options: .caseInsensitive) != nil {
                return trimmed
            }
            let base = removeRecognizedVariantSuffix(from: trimmed)
            return base + " (\(lowerVariant))"
        } else {
            if trimmed.range(of: rawVariant, options: .caseInsensitive) != nil {
                return trimmed
            }
            return trimmed + " \(rawVariant)"
        }
    }
    
    private func removeRecognizedVariantSuffix(from displayName: String) -> String {
        var result = displayName
        for token in Self.variantSuffixTokens {
            let suffix = " (\(token))"
            if result.lowercased().hasSuffix(suffix) {
                result = String(result.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return result
    }
    
    private static let variantSuffixTokens: Set<String> = ["free", "exacto"]
    
    
    // Fuzzy search matching - more strict version
    private func fuzzyMatch(_ text: String, query: String) -> Bool {
        if query.isEmpty {
            return true
        }
        
        // Normalize both strings: lowercase and remove special characters
        let normalizedText = text.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "/", with: " ")
            .replacingOccurrences(of: ":", with: " ")
        
        let normalizedQuery = query.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        
        // Split into tokens
        let textTokens = normalizedText.components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
        let queryTokens = normalizedQuery.components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
        
        // Check if all query tokens are found in text tokens with stricter matching
        for queryToken in queryTokens {
            let found = textTokens.contains { textToken in
                // Match if:
                // 1. Text token starts with query token (prefix match)
                // 2. Query token is at least 3 chars and text token contains it
                // 3. Exact match
                if textToken.hasPrefix(queryToken) {
                    return true
                }
                if queryToken.count >= 3 && textToken.contains(queryToken) {
                    return true
                }
                // Also check if query token starts with text token (for partial typing)
                if queryToken.count >= 3 && queryToken.hasPrefix(textToken) {
                    return true
                }
                return false
            }
            if !found {
                return false
            }
        }
        
        return true
    }
    
    // Filter models based on fuzzy search
    var filteredLocalModels: [ModelManager.ModelFile] {
        let filtered = searchText.isEmpty
        ? modelManager.models
        : modelManager.models.filter { model in fuzzyMatch(model.name, query: searchText) }
        
        // Sort by parameter count (largest first)
        return filtered.sorted { model1, model2 in
            let params1 = model1.name.modelParameterCount
            let params2 = model2.name.modelParameterCount
            
            if params1 > 0 && params2 > 0 {
                return params1 > params2
            }
            if params1 > 0 { return true }
            if params2 > 0 { return false }
            
            return model1.name.localizedStandardCompare(model2.name) == .orderedAscending
        }
    }
    
    var filteredRemoteModels: [String] {
        let allRemoteModels = remoteModelNames + customModelNames
        let filtered = searchText.isEmpty
        ? allRemoteModels
        : allRemoteModels.filter { modelName in fuzzyMatch(modelName, query: searchText) }
        
        // Sort by parameter count (largest first)
        return filtered.sortedByModelSize()
    }
    
    var body: some View {
        Button {
            showingDropdown.toggle()
        } label: {
            HStack(spacing: 4) {
                Text(currentModelName)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .foregroundStyle(toolbarTextColor)
            .symbolRenderingMode(.monochrome)
            .padding(.horizontal, 12)
        }
        .keyboardShortcut("k", modifiers: [.command])
        .buttonStyle(.plain)
        .popover(isPresented: $showingDropdown) {
            dropdownContent
                .frame(width: 360, height: 480)
        }
        .sheet(isPresented: self.$isManagingCustomModel) {
            ModelNameMenu.CustomModelsEditor(
                customModelNames: self.$customModelNames,
                isPresented: self.$isManagingCustomModel
            )
            .frame(minWidth: 400)
        }
        .task {
            // Get available models
            await self.refreshModelNames()
            // Check remote server reachability to update the display
            if InferenceSettings.useServer {
                self.remoteServerReachable = await model.remoteServerIsReachable()
            } else {
                self.remoteServerReachable = false
            }
        }
        .onChange(of: serverEndpoint) {
            Task { @MainActor in
                await self.refreshModelNames()
                if InferenceSettings.useServer {
                    self.remoteServerReachable = await model.remoteServerIsReachable()
                } else {
                    self.remoteServerReachable = false
                }
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: Notifications.changedInferenceConfig.name
            )
        ) { output in
            self.localModelsListId = UUID()
            Task { @MainActor in
                if InferenceSettings.useServer {
                    self.remoteServerReachable = await model.remoteServerIsReachable()
                } else {
                    self.remoteServerReachable = false
                }
            }
        }
        .onChange(of: self.serverModelName) {
            let serverModelHasVision: Bool = KnownModel.availableModels.contains { model in
                let nameMatches: Bool = self.serverModelName.contains(model.primaryName)
                return nameMatches && model.isVision
            }
            self.serverModelHasVision = serverModelHasVision
        }
    }
    
    var dropdownContent: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.body)
                TextField("Search", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(10)
            .background(Color(.controlBackgroundColor))
            .cornerRadius(10)
            .padding([.horizontal, .top], 12)
            .padding(.bottom, 8)
            
            Divider()
            
            // Models list - Use LazyVStack for better performance
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                        // Local Models Section
                        if !filteredLocalModels.isEmpty {
                            self.sectionHeader(
                                title: String(localized: "Local Models"),
                                id: "LocalHeader",
                                count: self.filteredLocalModels.count
                            )
                            ForEach(filteredLocalModels, id: \.name) { modelFile in
                                let capabilities = getModelCapabilities(modelFile.name)
                                LocalModelRow(
                                    modelFile: modelFile,
                                    isSelected: Settings.modelUrl == modelFile.url,
                                    isRemoteServerReachable: remoteServerReachable,
                                    isReasoning: capabilities.isReasoning,
                                    isVision: capabilities.isVision,
                                    onSelect: {
                                        selectLocalModel(modelFile)
                                    }
                                )
                                .id("Local:\(modelFile.name)")
                            }
                            .id(localModelsListId)
                        }
                        
                        // Remote Models Section
                        if !filteredRemoteModels.isEmpty {
                            if !filteredLocalModels.isEmpty {
                                Divider()
                                    .padding(.vertical, 8)
                            }
                            self.sectionHeader(
                                title: String(localized: "Remote Models"),
                                id: "RemoteHeader",
                                count: self.filteredRemoteModels.count
                            )
                            ForEach(filteredRemoteModels, id: \.self) { modelName in
                                let capabilities = getModelCapabilities(modelName)
                                RemoteModelRow(
                                    modelName: self.formatModelName(modelName),
                                    isSelected: modelName == serverModelName && InferenceSettings.useServer,
                                    isRemoteServerReachable: remoteServerReachable,
                                    isReasoning: capabilities.isReasoning,
                                    isVision: capabilities.isVision,
                                    onSelect: {
                                        selectRemoteModel(modelName)
                                    }
                                )
                                .id("Remote:\(modelName)")
                            }
                        }
                        
                        // Empty state
                        if filteredLocalModels.isEmpty && filteredRemoteModels.isEmpty {
                            VStack(spacing: 8) {
                                Text("No models found")
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                                if !searchText.isEmpty {
                                    Text("Try a different search term")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .task {
                    // Scroll to selected model after view appears
                    await Task.yield() // Let the view render first
                    
                    if !InferenceSettings.useServer {
                        // Scroll to selected local model
                        if let selectedModel = filteredLocalModels.first(where: { Settings.modelUrl == $0.url }) {
                            proxy.scrollTo("Local:\(selectedModel.name)", anchor: .center)
                        }
                    } else if InferenceSettings.useServer && !serverModelName.isEmpty {
                        // Scroll to selected remote model
                        if filteredRemoteModels.contains(serverModelName) {
                            proxy.scrollTo("Remote:\(serverModelName)", anchor: .center)
                        }
                    }
                    
                    // Reset search when opening
                    searchText = ""
                }
            }
            
            Divider()
            
            // Bottom actions
            HStack(spacing: 8) {
                Button {
                    self.isManagingCustomModel = true
                } label: {
                    Text("Manage Custom Models")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                
                Spacer()
                
                Button {
                    InferenceSettings.useServer.toggle()
                    NotificationCenter.default.post(
                        name: Notifications.changedInferenceConfig.name,
                        object: nil
                    )
                } label: {
                    Text(InferenceSettings.useServer ? "Disable Remote" : "Enable Remote")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding([.horizontal, .bottom], 12)
            .padding(.top, 8)
        }
    }
    
    
    private func sectionHeader(
        title: String,
        id: String,
        count: Int
    ) -> some View {
        Text("\(title) (\(count))")
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .id(id)
    }
    
    private func selectLocalModel(_ modelFile: ModelManager.ModelFile) {
        Settings.selectMainLocalModel(modelFile.url)
        NotificationCenter.default.post(
            name: Notifications.changedInferenceConfig.name,
            object: nil
        )
        showingDropdown = false
    }
    
    private func selectRemoteModel(_ modelName: String) {
        self.serverModelName = modelName
        // Enable remote server if not already enabled
        if !InferenceSettings.useServer {
            InferenceSettings.useServer = true
        }
        NotificationCenter.default.post(
            name: Notifications.changedInferenceConfig.name,
            object: nil
        )
        showingDropdown = false
    }
    
    private func refreshModelNames() async {
        self.remoteModelNames = await LlamaServer.getAvailableModels()
    }
    
    // Get model capabilities from model name
    private func getModelCapabilities(_ modelName: String) -> (isReasoning: Bool, isVision: Bool) {
        // Clean up the model name for better matching
        var cleanedName = modelName
        
        // Remove file extensions (for local models)
        if cleanedName.hasSuffix(".gguf") {
            cleanedName = String(cleanedName.dropLast(5))
        }
        
        // Remove quantization suffixes (e.g., Q4_K_M, Q8_0, etc.)
        let quantizationPatterns = [
            "-Q4_K_M", "-Q4_K_S", "-Q5_K_M", "-Q5_K_S", "-Q6_K", "-Q8_0",
            "_Q4_K_M", "_Q4_K_S", "_Q5_K_M", "_Q5_K_S", "_Q6_K", "_Q8_0",
            "-q4_k_m", "-q4_k_s", "-q5_k_m", "-q5_k_s", "-q6_k", "-q8_0",
            "_q4_k_m", "_q4_k_s", "_q5_k_m", "_q5_k_s", "_q6_k", "_q8_0"
        ]
        for pattern in quantizationPatterns {
            if cleanedName.hasSuffix(pattern) {
                cleanedName = String(cleanedName.dropLast(pattern.count))
                break
            }
        }
        
        // Try direct lookup first
        if let knownModel = KnownModel(identifier: cleanedName) {
            return (knownModel.isReasoningModel, knownModel.isVision)
        }
        
        // If direct lookup fails, try with original name
        if cleanedName != modelName, let knownModel = KnownModel(identifier: modelName) {
            return (knownModel.isReasoningModel, knownModel.isVision)
        }
        
        // If still no match, try fuzzy matching with normalized names
        let normalizedSearch = cleanedName
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: ".", with: "")
        
        for model in KnownModel.availableModels {
            let normalizedModelName = model.primaryName
                .lowercased()
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: ".", with: "")
                .replacingOccurrences(of: "/", with: "")
            
            // Check if normalized names match closely
            if normalizedSearch.contains(normalizedModelName) || normalizedModelName.contains(normalizedSearch) {
                return (model.isReasoningModel, model.isVision)
            }
        }
        
        return (false, false)
    }
}

// MARK: - Model Row Views

struct LocalModelRow: View {
    
    let modelFile: ModelManager.ModelFile
    let isSelected: Bool
    let isRemoteServerReachable: Bool
    let isReasoning: Bool
    let isVision: Bool
    let onSelect: () -> Void
    
    var shouldHighlight: Bool {
        isSelected && !isRemoteServerReachable
    }
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Text(modelFile.name)
                    .font(.body)
                    .foregroundStyle(.primary)
                Spacer()
                
                HStack(spacing: 6) {
                    if shouldHighlight {
                        Image(systemName: "checkmark")
                            .font(.body)
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.accentColor)
                    }
                    if isReasoning {
                        Image(systemName: "brain")
                            .font(.caption)
                            .foregroundStyle(.purple)
                    }
                    if isVision {
                        Image(systemName: "eye")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(
                    shouldHighlight ? Color.accentColor.opacity(0.25) : Color.clear
                )
        )
    }
}

struct RemoteModelRow: View {
    
    let modelName: String
    let isSelected: Bool
    let isRemoteServerReachable: Bool
    let isReasoning: Bool
    let isVision: Bool
    let onSelect: () -> Void
    
    var shouldHighlight: Bool {
        isSelected && isRemoteServerReachable
    }
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Text(modelName)
                    .font(.body)
                    .foregroundStyle(.primary)
                Spacer()
                
                HStack(spacing: 6) {
                    if shouldHighlight {
                        Image(systemName: "checkmark")
                            .font(.body)
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.accentColor)
                    }
                    if isReasoning {
                        Image(systemName: "brain")
                            .font(.caption)
                            .foregroundStyle(.purple)
                    }
                    if isVision {
                        Image(systemName: "eye")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(
                    shouldHighlight ? Color.accentColor.opacity(0.25) : Color.clear
                )
        )
    }
}

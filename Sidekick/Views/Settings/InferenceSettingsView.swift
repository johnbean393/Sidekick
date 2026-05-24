//
//  InferenceSettingsView.swift
//  Sidekick
//
//  Created by Bean John on 10/14/24.
//

import FSKit_macOS
import MarkdownUI
import SwiftUI
import UniformTypeIdentifiers

struct InferenceSettingsView: View {
    
    @AppStorage("modelUrl") private var modelUrl: URL?
    @AppStorage("workerModelUrl") private var workerModelUrl: URL?
    @AppStorage("specularDecodingModelUrl") private var specularDecodingModelUrl: URL?
    @AppStorage("projectorModelUrl") private var projectorModelUrl: URL?
    
    @State private var isEditingSystemPrompt: Bool = false
    
    @State private var isSelectingModel: Bool = false
    @State private var isSelectingWorkerModel: Bool = false
    @State private var isSelectingSpeculativeDecodingModel: Bool = false
    
    @State private var isConfiguringServerArguments: Bool = false
    
    @AppStorage("useSpeculativeDecoding") private var useSpeculativeDecoding: Bool = InferenceSettings.useSpeculativeDecoding
    
    @AppStorage("localModelUseVision") private var localModelUseVision: Bool = InferenceSettings.localModelUseVision
    
    @AppStorage("enableContextCompression") private var enableContextCompression: Bool = InferenceSettings.enableContextCompression
    @AppStorage("compressionTokenThreshold") private var compressionTokenThreshold: Int = InferenceSettings.compressionTokenThreshold
    
    var body: some View {
        Form {
            Section {
                model
                workerModel
                speculativeDecoding
            } header: {
                Text("Models")
            }
            Section {
                multimodal
            } header: {
                Text("Vision")
            }
            Section {
                parameters
            } header: {
                Text("Parameters")
            }
            ServerModelSettingsView()
        }
        .formStyle(.grouped)
        .scrollIndicators(.never)
        .sheet(isPresented: $isEditingSystemPrompt) {
            SystemPromptEditor(
                isEditingSystemPrompt: $isEditingSystemPrompt
            )
            .frame(maxHeight: 700)
        }
    }
    
    var model: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading) {
                Text("Model: \(modelUrl?.lastPathComponent ?? String(localized: "No Model Selected"))")
                    .font(.title3)
                    .bold()
                Text("This is the default local model used.")
                    .font(.caption)
            }
            Spacer()
            Button {
                self.isSelectingModel.toggle()
            } label: {
                Text("Manage")
            }
        }
        .contextMenu {
            Button {
                guard let modelUrl: URL = Settings.modelUrl else { return }
                FileManager.showItemInFinder(url: modelUrl)
            } label: {
                Text("Show in Finder")
            }
        }
        .sheet(isPresented: $isSelectingModel) {
            ModelListView(
                isPresented: $isSelectingModel,
                modelType: .regular
            )
            .frame(minWidth: 450, maxHeight: 600)
        }
    }
    
    var workerModel: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading) {
                Text(
                    "Worker Model: \(workerModelUrl?.lastPathComponent ?? String(localized: "No Model Selected"))"
                )
                .font(.title3)
                .bold()
                Text("This is the local worker model used for simpler tasks like generating chat titles.")
                    .font(.caption)
            }
            Spacer()
            Button {
                self.isSelectingWorkerModel.toggle()
            } label: {
                Text("Manage")
            }
        }
        .contextMenu {
            Button {
                guard let modelUrl: URL = InferenceSettings.workerModelUrl else {
                    return
                }
                FileManager.showItemInFinder(url: modelUrl)
            } label: {
                Text("Show in Finder")
            }
        }
        .sheet(isPresented: $isSelectingWorkerModel) {
            ModelListView(
                isPresented: $isSelectingWorkerModel,
                modelType: .worker
            )
            .frame(minWidth: 450, maxHeight: 600)
        }
    }
    
    var speculativeDecoding: some View {
        Group {
            useSpeculativeDecodingToggle
            if useSpeculativeDecoding {
                speculativeDecodingModel
            }
        }
    }
    
    var useSpeculativeDecodingToggle: some View {
        HStack(
            alignment: .top
        ) {
            VStack(
                alignment: .leading
            ) {
                HStack {
                    Text("Use Speculative Decoding")
                        .font(.title3)
                        .bold()
                }
                Text("Improve inference speed by running a second model in parallel with the main model. This may use more memory.")
                    .font(.caption)
            }
            Spacer()
            Toggle(
                "",
                isOn: $useSpeculativeDecoding.animation(.linear)
            )
        }
        .onChange(of: useSpeculativeDecoding) {
            // Send notification to reload model
            NotificationCenter.default.post(
                name: Notifications.changedInferenceConfig.name,
                object: nil
            )
        }
    }
    
    var speculativeDecodingModel: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading) {
                Text(
                    "Draft Model: \(specularDecodingModelUrl?.lastPathComponent ?? String(localized: "No Model Selected"))"
                )
                .font(.title3)
                .bold()
                Text("This is the model used for speculative decoding. It should be in the same family as the main model, but with less parameters.")
                    .font(.caption)
            }
            Spacer()
            Button {
                self.isSelectingSpeculativeDecodingModel.toggle()
            } label: {
                Text("Manage")
            }
        }
        .contextMenu {
            Button {
                guard let modelUrl: URL = InferenceSettings.speculativeDecodingModelUrl else {
                    return
                }
                FileManager.showItemInFinder(url: modelUrl)
            } label: {
                Text("Show in Finder")
            }
        }
        .sheet(isPresented: $isSelectingSpeculativeDecodingModel) {
            ModelListView(
                isPresented: $isSelectingSpeculativeDecodingModel,
                modelType: .speculative
            )
            .frame(minWidth: 450, maxHeight: 600)
        }
    }
    
    var multimodal: some View {
        Group {
            useVisionToggle
            projectorModelSelector
        }
    }
    
    var useVisionToggle: some View {
        HStack(
            alignment: .top
        ) {
            VStack(
                alignment: .leading
            ) {
                HStack {
                    Text("Use Vision")
                        .font(.title3)
                        .bold()
                }
                Text("Use a vision capable local model.")
                    .font(.caption)
            }
            Spacer()
            Toggle(
                "",
                isOn: $localModelUseVision.animation(.linear)
            )
        }
    }
    
    var projectorModelSelector: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading) {
                Text(
                    "Projector Model: \(projectorModelUrl?.lastPathComponent ?? String(localized: "No Model Selected"))"
                )
                .font(.title3)
                .bold()
                Text("This is the multimodal projector corresponding to the selected local model, which handles image encoding and projection.")
                    .font(.caption)
            }
            Spacer()
            Button {
                if let url = try? FileManager.selectFile(
                    dialogTitle: String(localized: "Select a Model"),
                    canSelectDirectories: false,
                    allowedContentTypes: [Settings.ggufType]
                ).first {
                    self.projectorModelUrl = url
                }
            } label: {
                Text("Select")
            }
        }
        .contextMenu {
            Button {
                guard let modelUrl: URL = InferenceSettings.projectorModelUrl else {
                    return
                }
                FileManager.showItemInFinder(url: modelUrl)
            } label: {
                Text("Show in Finder")
            }
        }
    }
    
    var parameters: some View {
        Group {
            systemPromptEditor
            contextCompressionToggle
            contextCompressionThresholdEditor
        }
    }
    
    var systemPromptEditor: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading) {
                Text("System Prompt")
                    .font(.title3)
                    .bold()
            }
            Spacer()
            Button {
                self.isEditingSystemPrompt.toggle()
            } label: {
                Text("Customise")
            }
        }
    }
    
    var contextCompressionToggle: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading) {
                Text("Enable Context Compression")
                    .font(.title3)
                    .bold()
                Text("Automatically compresses tool call results during agentic loops to prevent context window errors.")
                    .font(.caption)
            }
            Spacer()
            Toggle("", isOn: $enableContextCompression)
        }
    }
    
    var contextCompressionThresholdEditor: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading) {
                Text("Compression Token Threshold")
                    .font(.title3)
                    .bold()
                Text("Tool call results exceeding this token count will be summarized to save context space.")
                    .font(.caption)
            }
            Spacer()
            TextField(
                "",
                value: $compressionTokenThreshold,
                formatter: NumberFormatter()
            )
            .textFieldStyle(.plain)
            .frame(width: 80)
        }
        .disabled(!enableContextCompression)
        .opacity(enableContextCompression ? 1.0 : 0.5)
    }
    
}

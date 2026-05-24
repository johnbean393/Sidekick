//
//  ModelListView.swift
//  Sidekick
//
//  Created by Bean John on 11/8/24.
//

import SwiftData
import SwiftUI

struct ModelListView: View {

    init(
        isPresented: Binding<Bool>,
        modelType: ModelType
    ) {
        self._isPresented = isPresented
        self.modelType = modelType
        self._modelUrl = AppStorage(modelType.key)
    }

    var modelType: ModelType

    @Binding var isPresented: Bool
    @Query private var modelRows: [LocalModelFileEntity]

    @Environment(\.openWindow) var openWindow

    @AppStorage private var modelUrl: URL?

    @State private var hoveringAdd: Bool = false
    @State private var hoveringDownload: Bool = false

    /// URL of a freshly-added `.gguf` whose load-config sheet should be
    /// presented next. Cleared when the sheet dismisses.
    @State private var pendingConfigUrl: URL? = nil

    private var sortedModels: [ModelManager.ModelFile] {
        return modelRows
            .compactMap(\.modelFile)
            .sorted(by: { $0.name < $1.name })
    }

    var body: some View {
        VStack(
            alignment: .center
        ) {
            exitButton
            list
                .frame(
                    minHeight: 200,
                    maxHeight: 400
                )
            HStack {
                addButton
                downloadButton
            }
            .padding(.vertical, 3)
            .padding(.bottom, 3)
        }
        .padding(7)
        .sheet(
            isPresented: Binding(
                get: { pendingConfigUrl != nil },
                set: { newValue in if !newValue { pendingConfigUrl = nil } }
            )
        ) {
            if let url = pendingConfigUrl {
                ModelLoadConfigSheet(
                    modelUrl: url,
                    mode: .add,
                    isPresented: Binding(
                        get: { pendingConfigUrl != nil },
                        set: { newValue in if !newValue { pendingConfigUrl = nil } }
                    ),
                    onSaved: { _ in
                        // Activate the freshly configured model so the
                        // user lands on a ready-to-chat state.
                        switch modelType {
                            case .regular:
                                Settings.selectMainLocalModel(url)
                                self.modelUrl = Settings.modelUrl
                            case .speculative:
                                InferenceSettings.speculativeDecodingModelUrl = url
                                self.modelUrl = InferenceSettings.speculativeDecodingModelUrl
                            case .worker:
                                InferenceSettings.workerModelUrl = url
                                self.modelUrl = InferenceSettings.workerModelUrl
                        }
                    },
                    onCancelledAdd: {
                        // Undo the speculative insert so a cancelled
                        // add leaves no orphan row.
                        if let entity = ModelManager.entity(for: url) {
                            ModelManager.delete(id: entity.id)
                        }
                    }
                )
            }
        }
    }

    var list: some View {
        List(sortedModels) { model in
            ModelRowView(
                modelFile: model,
                modelUrl: $modelUrl,
                modelType: modelType
            )
        }
        .listRowSeparator(.visible)
    }

    var addButton: some View {
        Button {
            self.addModel()
        } label: {
            Label(
                "Add Model",
                systemImage: "plus"
            )
        }
        .buttonStyle(.plain)
        .padding(5)
        .padding(.horizontal, 5)
        .background {
            RoundedRectangle(cornerRadius: 7)
                .fill(
                    Color.secondary.opacity(self.hoveringAdd ? 0.15 : 0)
                )
                .frame(height: 30)
        }
        .onHover { hovering in
            self.hoveringAdd = hovering
        }
    }

    var downloadButton: some View {
        Button {
            self.openWindow(id: "models")
        } label: {
            Label(
                "Download Model",
                systemImage: "square.and.arrow.down"
            )
        }
        .buttonStyle(.plain)
        .padding(.bottom, 6)
        .padding(.top, 4)
        .padding(.horizontal, 5)
        .background {
            RoundedRectangle(cornerRadius: 7)
                .fill(
                    Color.secondary.opacity(self.hoveringDownload ? 0.15 : 0)
                )
                .frame(height: 30)
        }
        .onHover { hovering in
            self.hoveringDownload = hovering
        }
    }

    var exitButton: some View {
        HStack {
            ExitButton {
                self.isPresented.toggle()
            }
            Spacer()
        }
        .padding([.horizontal, .top], 3)
    }

    /// Function to add model. Picks a `.gguf` and (for regular models)
    /// hands off to the load-config sheet so the user can choose a
    /// context length before the model is first loaded.
    private func addModel() {
        switch self.modelType {
            case .regular:
                if let url = Settings.selectAndAddModel() {
                    // Defer activation until after the sheet saves so a
                    // cancel doesn't leave us pointing at an unconfigured
                    // model.
                    self.pendingConfigUrl = url
                }
            case .speculative, .worker:
                let _ = ModelManager.addModel()
        }
        NotificationCenter.default.post(
            name: Notifications.changedInferenceConfig.name,
            object: nil
        )
    }

    /// Function to get the url of the current model type
    private func getModelUrl() -> URL? {
        switch self.modelType {
            case .regular:
                return Settings.modelUrl
            case .speculative:
                return InferenceSettings.speculativeDecodingModelUrl
            case .worker:
                return InferenceSettings.workerModelUrl
        }
    }

    enum ModelType: String, CaseIterable {

        case regular, speculative, worker

        /// The key of the model in UserDefaults
        var key: String {
            switch self {
                case .regular:
                    return "modelUrl"
                case .speculative:
                    return "speculativeDecodingModelUrl"
                case .worker:
                    return "workerModelUrl"
            }
        }
    }

}

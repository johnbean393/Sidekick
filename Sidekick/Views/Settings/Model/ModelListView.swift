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

    /// Function to add model
    private func addModel() {
        if self.modelType == .regular {
            let _ = Settings.selectModel()
        } else {
            let _ = ModelManager.addModel()
        }
        // Send notification to reload model
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

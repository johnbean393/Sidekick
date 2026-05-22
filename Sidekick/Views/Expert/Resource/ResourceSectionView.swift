//
//  ResourceSectionView.swift
//  Sidekick
//
//  Created by Bean John on 10/11/24.
//

import FSKit_macOS
import SwiftUI

struct ResourceSectionView: View {
    
    @Binding var expert: Expert
    
    @State private var showAddOptions: Bool = false
    @State private var isAddingWebsite: Bool = false
    @State private var isAddingEmail: Bool = false
    
        @Environment(LengthyTasksController.self) private var lengthyTasksController
    
    var isTutorial: Bool = false
    var fileUrl: URL? = nil
    
    var isUpdating: Bool {
        let taskName: String = String(
            localized: "Updating resource index for expert \"\(self.expert.name)\""
        )
        return lengthyTasksController.tasks
            .map(\.name)
            .contains(
                taskName
            )
    }
    
    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 16) {
                selectResources
                Divider()
                persistResources
                if RetrievalSettings.graphRAGEnabled {
                    graphRAGControls
                }
            }
            .padding(.horizontal, 5)
        } header: {
            Text("Resources")
        }
        .confirmationDialog(
            "Resource Type",
            isPresented: $showAddOptions
        ) {
            Button {
                if !isTutorial {
                    self.addFile()
                } else {
                    self.tutorialAddFile()
                }
            } label: {
                Text("File / Folder")
            }
            Button {
                self.isAddingWebsite.toggle()
            } label: {
                Text("Website")
            }
            .disabled(isTutorial)
            Button {
                self.isAddingEmail.toggle()
            } label: {
                Text("Email (Mail.app only)")
            }
            .disabled(isTutorial)
        } message: {
            Text("What type of resource do you want to add?")
        }
        .sheet(isPresented: $isAddingWebsite) {
            WebsiteSelectionView(
                expert: $expert,
                isAddingWebsite: $isAddingWebsite
            )
        }
        .sheet(isPresented: $isAddingEmail) {
            EmailSelectionView(
                expert: $expert,
                isAddingEmail: $isAddingEmail
            )
        }
    }
    
    var selectResources: some View {
        VStack(alignment: .leading) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Resources")
                        .font(.title3)
                        .bold()
                    Text("Files, folders or websites stored in the chatbot's long-term memory")
                        .font(.caption)
                }
                Spacer()
                Button {
                    self.showAddOptions.toggle()
                } label: {
                    Text("Add")
                }
                .disabled(self.isUpdating)
                Button {
                    Task { await updateIndexes() }
                } label: {
                    Text("Update Index")
                }
                .disabled(self.isUpdating || self.isTutorial)
            }
            Divider()
            ResourceSelectionView(expert: self.$expert)
        }
    }
    
    var persistResources: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading) {
                Text("Persist Resources")
                    .font(.title3)
                    .bold()
                Text("Keep resources between sessions")
                    .font(.caption)
            }
            Spacer()
            Toggle("", isOn: $expert.persistResources)
                .toggleStyle(.switch)
                .disabled(isTutorial)
        }
    }
    
    @ViewBuilder
    private var graphRAGControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Enable Knowledge Graphs")
                            .font(.title3)
                            .bold()
                        StatusLabelView.experimental
                    }
                    Text("Use knowledge graphs to enhance retrieval with entity relationships.")
                        .font(.caption)
                }
                Spacer()
                Toggle("", isOn: $expert.useGraphRAG)
                    .disabled(isUpdating)
            }
            
            if expert.useGraphRAG {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Graph Status")
                                .font(.title3)
                                .bold()
                            Text(statusText(for: expert.resources.graphStatus))
                                .font(.caption)
                        }
                        Spacer()
                        
                        if expert.resources.graphStatus == .building,
                           let progress = expert.resources.graphProgress {
                            PercentProgressView(progress: progress.clampedOverall)
                                .frame(width: 40, height: 40)
                        } else {
                            statusIcon(for: expert.resources.graphStatus)
                        }
                    }
                    
                    if expert.resources.graphStatus == .building,
                       let progress = expert.resources.graphProgress {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: progress.clampedStage, total: 1.0)
                                .progressViewStyle(.linear)
                            
                            Text(progressCaption(for: progress))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .accessibilityLabel("Graph indexing progress")
                        }
                    }
                    
                    HStack(spacing: 12) {
                        VStack(alignment: .leading) {
                            Text("Rebuild Knowledge Graph")
                                .font(.title3)
                                .bold()
                            Text("Re-index all resources with graph extraction. This may take several minutes.")
                                .font(.caption)
                        }
                        Spacer()
                        Button("Rebuild") {
                            rebuildGraph()
                        }
                        .disabled(isUpdating)
                    }
                }
            }
        }
    }
    
    private func progressCaption(for progress: Resources.GraphProgress) -> String {
        let stagePercent = Int((progress.clampedStage * 100).rounded())
        let fallback = "Building Knowledge Graph (\(stagePercent)%)"
        
        guard let stage = progress.stage, !stage.isEmpty else {
            return fallback
        }
        
        return "\(stage) (\(stagePercent)%)"
    }
    
    private func statusText(for status: Resources.GraphStatus?) -> String {
        guard let status = status else {
            return "Not yet indexed"
        }
        
        switch status {
            case .building:
                if isUpdating {
                    return "Building knowledge graph..."
                }
                return "Indexing in progress..."
            case .ready:
                return "Knowledge graph ready"
            case .error:
                return "Error building graph"
        }
    }
    
    @ViewBuilder
    private func statusIcon(for status: Resources.GraphStatus?) -> some View {
        Group {
            if let status = status {
                switch status {
                    case .building:
                        ProgressView()
                            .controlSize(.small)
                    case .ready:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    case .error:
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                }
            } else {
                Image(systemName: "circle.dashed")
                    .foregroundColor(.secondary)
            }
        }
    }
    
    private func rebuildGraph() {
        Task {
            // Capture values before async context
            let expertId = expert.id
            let expertName = expert.name
            await MainActor.run {
                expert.resources.graphStatus = .building
                ExpertManager.update(expert)
            }
            var updatedExpert = expert
            await updatedExpert.resources.migrateToGraphRAG(expertName: expertName) { progress in
                updateExpertProgress(expertId: expertId, progress: progress)
            }
            await MainActor.run {
                expert = updatedExpert
                ExpertManager.update(updatedExpert)
            }
        }
    }
    
    @MainActor
    private func addFile() {
        guard let selectedUrls: [URL] = try? FileManager.selectFile(
            dialogTitle: String(localized: "Select Files or Folders"),
            allowMultipleSelection: true
        ) else { return }
        self.addUrls(urls: selectedUrls)
    }
    
    @MainActor
    private func tutorialAddFile() {
        guard let selectedUrls: [URL] = try? FileManager.selectFile(
            rootUrl: fileUrl,
            dialogTitle: String(localized: "Select Files or Folders"),
            allowMultipleSelection: true
        ) else { return }
        // Check
        print("selectedUrls: \(selectedUrls)")
        print("fileUrl: \(fileUrl?.lastPathComponent ?? "")")
        if selectedUrls != [fileUrl] {
            // Show alert and return
            Dialogs.showAlert(
                title: String(localized: "Error"),
                message: String(localized: "Wrong files selected. Please select the file \"\(fileUrl?.lastPathComponent ?? "")\".")
            )
            return
        }
        // Add
        self.addUrls(urls: selectedUrls)
    }
    
    @MainActor
    private func addUrls(urls: [URL]) {
        let resources: [Resource] = urls.map({
            Resource(url: $0)
        })
        Task { @MainActor in
            var current = expert
            current.resources.addResources(resources)
            expert = current
            ExpertManager.update(current)
        }
    }
    
    @MainActor
    private func updateIndexes() async {
        // Capture values before async context
        let expertId = expert.id
        let expertName = expert.name
        
        var updatedExpert = expert
        await updatedExpert.resources.updateResourcesIndex(
            expertName: expertName,
            progressUpdate: { progress in
                updateExpertProgress(expertId: expertId, progress: progress)
            }
        )
        await MainActor.run {
            expert = updatedExpert
            ExpertManager.update(updatedExpert)
        }
    }
    
    private func updateExpertProgress(expertId: UUID, progress: Resources.GraphProgress) {
        Task { @MainActor in
            guard var current = ExpertManager.getExpert(id: expertId) else {
                return
            }
            current.resources.graphStatus = .building
            current.resources.graphProgress = progress
            ExpertManager.update(current)
        }
    }
    
}

private extension Resources.GraphProgress {
    
    var clampedOverall: Double {
        max(0.0, min(percentComplete, 1.0))
    }
    
    var clampedStage: Double {
        let stageValue = stagePercentComplete ?? percentComplete
        return max(0.0, min(stageValue, 1.0))
    }
    
}

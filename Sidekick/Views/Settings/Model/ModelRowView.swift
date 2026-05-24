//
//  ModelRowView.swift
//  Sidekick
//
//  Created by Bean John on 11/8/24.
//

import FSKit_macOS
import SwiftUI

struct ModelRowView: View {

    let modelFile: ModelManager.ModelFile
    @Binding var modelUrl: URL?
    @State var isHovering: Bool = false
    @State private var isConfiguring: Bool = false
	
    var modelType: ModelListView.ModelType
	
	var isSelected: Bool {
		return modelFile.url == modelUrl
	}
	
    var body: some View {
		HStack {
			selectedIndicator
			Text(modelFile.name)
			Spacer()
			button
			state
		}
		.onTapGesture {
			self.select()
		}
		.onHover { isHovering in
			self.isHovering = isHovering
		}
		.contextMenu {
			configureButton
			openButton
		}
		.sheet(isPresented: $isConfiguring) {
			ModelLoadConfigSheet(
				modelUrl: modelFile.url,
				mode: .edit,
				isPresented: $isConfiguring
			)
		}
    }
	
	var openButton: some View {
		Button {
			FileManager.showItemInFinder(url: modelFile.url)
		} label: {
			Text("Show in Finder")
		}
	}
	
	/// Per-model load configuration entry point (regular models only).
	/// Speculative and worker models share the main model's loader
	/// settings today, so we hide the option for them to avoid
	/// suggesting otherwise.
	@ViewBuilder
	var configureButton: some View {
		if modelType == .regular {
			Button {
				self.isConfiguring = true
			} label: {
				Text("Configure…")
			}
		}
	}
	
	var selectedIndicator: some View {
		Circle()
			.fill(
				self.isSelected ? Color.green : Color.clear
			)
			.frame(width: 5, height: 5)
	}
	
	var state: some View {
		Group {
			if !modelFile.url.fileExists {
				StatusLabelView(
					text: String(localized: "Missing"),
					textColor: .primary,
					fill: .yellow
				)
				.help("Model could not be found")
			}
		}
	}
	
	var button: some View {
		Group {
			 if isHovering {
				HStack(spacing: 8) {
					if modelType == .regular {
						Button {
							self.isConfiguring = true
						} label: {
							Label(
								"Configure",
								systemImage: "gearshape"
							)
							.labelStyle(.iconOnly)
							.foregroundStyle(.secondary)
						}
						.buttonStyle(.plain)
						.help("Configure load parameters for this model")
					}
					Button {
						if self.isSelected {
							self.modelUrl = nil
						}
						ModelManager.delete(id: self.modelFile.id)
					} label: {
						Label(
							"Delete",
							systemImage: "trash"
						)
						.labelStyle(.iconOnly)
						.foregroundStyle(.red)
					}
					.buttonStyle(.plain)
				}
			}
		}
	}
	
	/// Function to select model
	private func select() {
		// Update variables
        switch self.modelType {
            case .regular:
				Settings.selectMainLocalModel(self.modelFile.url)
                self.modelUrl = Settings.modelUrl
            case .speculative:
                InferenceSettings.speculativeDecodingModelUrl = self.modelFile.url
                self.modelUrl = InferenceSettings.speculativeDecodingModelUrl
            case .worker:
                InferenceSettings.workerModelUrl = self.modelFile.url
                self.modelUrl = InferenceSettings.workerModelUrl
        }
		// Send notification to reload model
		NotificationCenter.default.post(
			name: Notifications.changedInferenceConfig.name,
			object: nil
		)
	}
	
}

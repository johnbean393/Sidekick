//
//  ModelSelectionView.swift
//  Sidekick
//
//  Created by Bean John on 9/23/24.
//

import DefaultModels
import SwiftUI

struct ModelSelectionView: View {
	
	@Environment(DownloadManager.self) private var downloadManager
	@Binding var selectedModel: Bool
	
	@State private var showServerModelSetup: Bool = false
	@State private var didPressDownload: Bool = false
	
    var body: some View {
		VStack {
			welcome
			downloadButton
				.padding(.top, 5)
			downloadManager.progressView
			advancedDivider
			selectButton
			connectButton
		}
		.padding(.horizontal)
		.padding()
		.onChange(
			of: downloadManager.didFinishDownloadingModel
		) {
			selectedModel = downloadManager.didFinishDownloadingModel
		}
    }
	
	var welcome: some View {
		Group {
			ZStack {
				self.appIconImage
					.scaleEffect(1.2)
					.blur(radius: 7, opaque: false)
					.opacity(0.7)
				self.appIconImage
			}
			Text("Welcome to Sidekick")
				.foregroundStyle(.primary)
				.font(.largeTitle)
				.fontWeight(.heavy)
			Text("Download or Select a Model to get started")
				.foregroundStyle(.secondary)
				.font(.title3)
		}
	}
	
	var appIconImage: some View {
		Image(.appIcon)
			.resizable()
			.foregroundStyle(.secondary)
			.frame(width: 100, height: 100)
	}
	
	var advancedDivider: some View {
		HStack {
			Rectangle().fill(.secondary).frame(height: 1)
			Text("Alternatively...")
				.font(.body)
				.foregroundStyle(.secondary)
			Rectangle().fill(.secondary).frame(height: 1)
		}
		.frame(maxWidth: 500)
		.padding(.vertical, 4)
	}
	
	var downloadButton: some View {
		Button {
			// Toggle flag
			self.didPressDownload = true
			// Start download of the default model
			Task { @MainActor in
				await self.downloadManager.downloadDefaultModel()
			}
		} label: {
			Text("Download Default Model")
				.padding(.horizontal, 20)
		}
		.keyboardShortcut(.defaultAction)
		.disabled(didPressDownload)
		.controlSize(.large)
		.frame(minWidth: 220)
	}
	
	var selectButton: some View {
		Button {
			// Select a model
			let didSelect: Bool = Settings.selectModel()
			// After selection, move to next screen
			selectedModel = didSelect
		} label: {
			Text("Use GGUF model")
		}
		.buttonStyle(.link)
	}
	
	var connectButton: some View {
		Button {
			self.showServerModelSetup.toggle()
		} label: {
			Text("Use model server")
		}
		.buttonStyle(.link)
		.sheet(isPresented: $showServerModelSetup) {
			ServerModelSetupView(
				isPresented: $showServerModelSetup,
				selectedModel: $selectedModel
			)
			.frame(maxWidth: 500)
		}
	}
	
}

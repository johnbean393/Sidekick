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
	@State private var pendingConfigUrl: URL? = nil
	
	private var isDownloading: Bool {
		!downloadManager.tasks.isEmpty
	}
	
	private var downloadButtonDisabled: Bool {
		// Block while a download is in flight or completing. We
		// intentionally re-enable after a failure (via the error UI
		// resetting `didPressDownload`) so users can retry without
		// restarting setup.
		downloadManager.recommendedModel == nil ||
		downloadManager.isResolvingRecommendedModel ||
		(didPressDownload && downloadManager.downloadError == nil)
	}
	
    var body: some View {
		VStack {
			welcome
			modelPreview
			if isDownloading {
				downloadInProgressPanel
					.padding(.top, 5)
			} else {
				downloadButton
					.padding(.top, 5)
			}
			if let error = downloadManager.downloadError {
				errorView(error: error)
			}
			advancedDivider
			selectButton
			connectButton
		}
		.padding(.horizontal)
		.padding()
		.task {
			// Resolve the recommended model lazily so the preview can
			// display "what" will be downloaded. Skipped when already
			// cached so re-entering the screen is instant.
			if downloadManager.recommendedModel == nil {
				await downloadManager.prepareRecommendedModel()
			}
		}
		.onChange(
			of: downloadManager.didFinishDownloadingModel
		) { _, didFinish in
			// Surface the load-config sheet for the freshly downloaded
			// default model before advancing to the next setup step.
			if didFinish, let modelUrl = Settings.modelUrl, pendingConfigUrl == nil {
				pendingConfigUrl = modelUrl
			} else if !didFinish {
				selectedModel = false
			}
		}
		.onChange(of: downloadManager.downloadError) { _, error in
			// Re-enable the download button as soon as a failure is
			// reported so the user can retry.
			if error != nil {
				didPressDownload = false
			}
		}
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
						Settings.selectMainLocalModel(url)
						selectedModel = true
					},
					onCancelledAdd: {
						// Leave the file on disk, but undo the
						// SwiftData row and the speculative
						// `selectMainLocalModel` call so setup
						// returns to the model-picker screen.
						if let entity = ModelManager.entity(for: url) {
							ModelManager.delete(id: entity.id)
						}
						if Settings.modelUrl == url {
							Settings.modelUrl = nil
						}
						// Re-enable the download button so the user
						// can retry from the model-picker without
						// having to leave and re-enter setup.
						didPressDownload = false
						selectedModel = false
					}
				)
			}
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
	
	@ViewBuilder
	var modelPreview: some View {
		if let model = downloadManager.recommendedModel {
			VStack(alignment: .leading, spacing: 4) {
				HStack(alignment: .firstTextBaseline) {
					Text(model.name)
						.font(.headline)
						.bold()
					Spacer()
					if let bytes = downloadManager.recommendedModelDownloadSize {
						Text(Self.formatBytes(bytes))
							.font(.subheadline.monospacedDigit())
							.foregroundStyle(.secondary)
					}
				}
				Text(Self.previewSubtitle(for: model))
					.font(.subheadline)
					.foregroundStyle(.secondary)
			}
			.padding(10)
			.frame(maxWidth: 420)
			.background(
				RoundedRectangle(cornerRadius: 8)
					.fill(Color.secondary.opacity(0.15))
			)
			.padding(.top, 6)
		} else if downloadManager.isResolvingRecommendedModel {
			HStack(spacing: 6) {
				ProgressView()
					.controlSize(.small)
				Text("Choosing a model for your Mac…")
					.font(.subheadline)
					.foregroundStyle(.secondary)
			}
			.padding(.top, 6)
		}
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
			self.didPressDownload = true
			Task { @MainActor in
				await self.downloadManager.downloadDefaultModel()
			}
		} label: {
			Text(downloadButtonLabel)
				.padding(.horizontal, 20)
		}
		.keyboardShortcut(.defaultAction)
		.disabled(downloadButtonDisabled)
		.controlSize(.large)
		.frame(minWidth: 220)
	}

	/// Live download panel shown in place of the "Download" button
	/// while a download is in flight. Provides pause/resume, a hard
	/// cancel (which drops the user back to the picker), and a live
	/// byte-counter so users can see real progress.
	var downloadInProgressPanel: some View {
		VStack(spacing: 8) {
			HStack(alignment: .firstTextBaseline) {
				Text(downloadingTitle)
					.font(.subheadline)
					.bold()
				Spacer()
				Text(downloadProgressText)
					.font(.caption.monospacedDigit())
					.foregroundStyle(.secondary)
			}
			downloadManager.progressView
				.padding(.top, -4)
			HStack(spacing: 8) {
				Spacer()
				Button {
					if downloadManager.isPaused {
						downloadManager.resumeAllDownloads()
					} else {
						downloadManager.pauseAllDownloads()
					}
				} label: {
					Label(
						downloadManager.isPaused
							? String(localized: "Resume")
							: String(localized: "Pause"),
						systemImage: downloadManager.isPaused
							? "play.fill"
							: "pause.fill"
					)
				}
				Button(role: .destructive) {
					cancelActiveDownload()
				} label: {
					Label(
						String(localized: "Cancel"),
						systemImage: "xmark"
					)
				}
			}
		}
		.padding(12)
		.frame(maxWidth: 420)
		.background(
			RoundedRectangle(cornerRadius: 8)
				.fill(Color.secondary.opacity(0.15))
		)
	}

	private var downloadingTitle: String {
		let name = downloadManager.recommendedModel?.name
			?? String(localized: "Default Model")
		if downloadManager.isPaused {
			return String(localized: "Paused — \(name)")
		}
		return String(localized: "Downloading \(name)…")
	}

	private var downloadProgressText: String {
		let written: Int64 = downloadManager.bytesWritten
		let expected: Int64 = downloadManager.bytesExpected > 0
			? downloadManager.bytesExpected
			: (downloadManager.recommendedModelDownloadSize ?? 0)
		if expected > 0 {
			let percent: Int = min(
				100,
				max(0, Int((Double(written) / Double(expected)) * 100))
			)
			return "\(Self.formatBytes(written)) / \(Self.formatBytes(expected)) · \(percent)%"
		}
		if written > 0 {
			return Self.formatBytes(written)
		}
		return String(localized: "Starting…")
	}

	/// Cancels any in-flight download and resets local UI state so
	/// the picker is interactive again. Safe to call when nothing is
	/// downloading (no-op).
	private func cancelActiveDownload() {
		_ = downloadManager.cancelAllDownloads()
		// Reset our local "user clicked Download" flag so the main
		// download button (and disabled-state logic) refresh cleanly.
		didPressDownload = false
	}
	
	private var downloadButtonLabel: String {
		guard let model = downloadManager.recommendedModel else {
			return String(localized: "Download Default Model")
		}
		if let bytes = downloadManager.recommendedModelDownloadSize {
			return String(
				localized: "Download \(model.name) (\(Self.formatBytes(bytes)))"
			)
		}
		return String(localized: "Download \(model.name)")
	}
	
	@ViewBuilder
	private func errorView(error: String) -> some View {
		VStack(spacing: 6) {
			Text("Download failed")
				.font(.subheadline)
				.bold()
				.foregroundStyle(.red)
			Text(error)
				.font(.caption)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
				.lineLimit(3)
			Button {
				didPressDownload = true
				Task { @MainActor in
					await downloadManager.downloadDefaultModel()
				}
			} label: {
				Text("Try Again")
			}
			.controlSize(.regular)
		}
		.padding(.top, 4)
		.frame(maxWidth: 420)
	}
	
	var selectButton: some View {
		Button {
			// Pick the .gguf and present the load-config sheet before
			// advancing setup. ``selectAndAddModel`` adds to the
			// registry without activating, so a cancelled config can
			// be cleanly undone.
			if let url = Settings.selectAndAddModel() {
				// The user committed to an existing GGUF; abandon any
				// in-flight default-model download so it doesn't keep
				// running silently in the background.
				cancelActiveDownload()
				pendingConfigUrl = url
			}
		} label: {
			Text("Use GGUF model")
		}
		.buttonStyle(.link)
	}
	
	var connectButton: some View {
		Button {
			// Same rationale as `selectButton`: committing to a
			// remote provider means the default-model download is no
			// longer wanted.
			cancelActiveDownload()
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
	
	/// Render a human-friendly byte count (e.g. `"4.7 GB"`). Uses
	/// `ByteCountFormatter` so it respects the user's locale.
	private static func formatBytes(_ bytes: Int64) -> String {
		let formatter: ByteCountFormatter = ByteCountFormatter()
		formatter.allowedUnits = [.useGB, .useMB]
		formatter.countStyle = .file
		return formatter.string(fromByteCount: bytes)
	}
	
	/// Compact secondary label describing the model: parameter count
	/// and model family (e.g. `"8.0B parameters · Qwen 3"`).
	private static func previewSubtitle(for model: HuggingFaceModel) -> String {
		let params: String
		let count: Float = (model.params * 10).rounded() / 10
		if Float(Int(count)) == count {
			params = "\(Int(count))B parameters"
		} else {
			params = String(format: "%.1fB parameters", count)
		}
		return "\(params) · \(model.modelFamily.rawValue)"
	}
	
}

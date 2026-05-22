//
//  CompletionsDownloadView.swift
//  Sidekick
//
//  Created by John Bean on 3/25/25.
//

import SwiftUI

struct CompletionsDownloadView: View {

	@State private var downloadManager: DownloadManager = .shared
	
	@EnvironmentObject private var completionsSetupViewModel: CompletionsSetupViewModel
	
    var body: some View {
		VStack {
			if downloadManager.tasks.isEmpty {
				Text("Click the button below to download a completion model.")
					.font(.title3)
					.bold()
					.multilineTextAlignment(.center)
			} else {
				downloadManager.progressView
			}
			downloadButton
		}
		.frame(maxWidth: 350)
		.padding(.horizontal, 4)
		.padding(.vertical, 3)
		.padding(.bottom, 2)
		.onAppear {
			// If completion model is available
			if InferenceSettings.completionsModelUrl != nil {
				// Skip
				self.completionsSetupViewModel.step.nextCase()
			}
		}
	}
	
	var downloadButton: some View {
		Button {
			// Start download of the default completion model
			Task { @MainActor in
				await self.downloadManager.downloadDefaultCompletionsModel()
			}
		} label: {
			Text("Download")
				.padding(.horizontal, 20)
		}
		.keyboardShortcut(.defaultAction)
		.controlSize(.large)
		.frame(minWidth: 220)
		.disabled(!self.downloadManager.tasks.isEmpty)
		.onChange(
			of: downloadManager.didFinishDownloadingModel
		) {
			self.completionsSetupViewModel.step.nextCase()
		}
	}
	
}

#Preview {
    CompletionsDownloadView()
}

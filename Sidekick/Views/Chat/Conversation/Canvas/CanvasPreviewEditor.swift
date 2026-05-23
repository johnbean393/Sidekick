//
//  CanvasPreviewEditor.swift
//  Sidekick
//
//  Created by John Bean on 3/19/25.
//

import SwiftfulLoadingIndicators
import SwiftUI
import WebViewKit

struct CanvasPreviewEditor: View {
	
	@EnvironmentObject private var canvasController: CanvasController
	@Environment(ConversationState.self) private var conversationState
	@Environment(ConversationManager.self) private var conversationManager
	
	var selectedConversation: Conversation? {
		return self.conversationState.selectedConversation
	}
	
	var selectedSnapshot: Snapshot? {
		guard let selectedMessageId = canvasController.selectedMessageId else {
			return nil
		}
		return selectedConversation?.getMessage(selectedMessageId)?.snapshot
	}
	
	var body: some View {
		VStack(
			spacing: 0
		) {
			Spacer(minLength: 0)
			if self.canvasController.isExtractingSnapshot {
				extractingSnapshotIndicator
			} else {
				content
			}
			Spacer(minLength: 0)
			Divider()
			buttonBar
		}
	}
	
	var content: some View {
		ZStack {
			Color.clear
				.frame(minHeight: 0, maxHeight: .infinity)
			if let selectedSnapshot {
				switch selectedSnapshot.type {
					case .text:
						SnapshotTextEditor()
					case .site:
						WebView(url: selectedSnapshot.site!.url)
				}
			} else {
				Text("No version selected.")
			}
		}
	}
	
	var buttonBar: some View {
		HStack {
			exitButton
			IfFits {
				Text("Canvas")
					.font(.title3)
					.bold()
					.foregroundStyle(.secondary)
					.labelStyle(.titleOnly)
			}
			Spacer()
			if let selectedSnapshot {
				SnapshotCopyButton(snapshot: selectedSnapshot)
				SnapshotExportButton(snapshot: selectedSnapshot)
			}
			if let messages = selectedConversation?.messagesWithSnapshots,
				messages.count > 1 {
				CanvasVersionSelector()
			}
		}
		.padding([.bottom, .leading], 9)
		.padding([.trailing, .top], 7)
	}
	
	var exitButton: some View {
		Button {
			withAnimation(.linear) {
				self.conversationState.useCanvas = false
			}
		} label: {
			Label("Exit", systemImage: "xmark.circle.fill")
				.labelStyle(.iconOnly)
				.foregroundStyle(.secondary)
		}
		.buttonStyle(.plain)
	}
	
	var extractingSnapshotIndicator: some View {
		VStack {
			LoadingIndicator(
				animation: .doubleHelix,
				size: .large
			)
			Text("Extracting content...")
				.font(.title2)
				.bold()
		}
	}
	
}

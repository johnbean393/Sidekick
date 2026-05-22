//
//  DebugCommands.swift
//  Sidekick
//
//  Created by Bean John on 10/5/24.
//

import Foundation
import SwiftUI
import TipKit

@MainActor
public class DebugCommands {
	
	static var commands: some Commands {
        CommandGroup(after: .help) {
			Menu("Debug") {
				Self.debugSettings
				Self.debugConversations
				Self.debugPersistence
				Button(
					action: ExpertManager.resetToDefaults
				) {
					Text("Delete All Experts")
				}
				Button {
					FileManager.showItemInFinder(
						url: Settings.containerUrl
					)
				} label: {
					Text("Show Container in Finder")
				}
			}
		}
	}

	private static var debugPersistence: some View {
		Menu("Persistence") {
			Button {
				Task { @MainActor in
					Self.reimportFromLegacyJSON()
				}
			} label: {
				Text("Re-import From Legacy JSON")
			}
			Button {
				FileManager.showItemInFinder(
					url: Settings.containerUrl.appendingPathComponent("Legacy")
				)
			} label: {
				Text("Show Legacy JSON in Finder")
			}
		}
	}

	/// Runs the SwiftData importer against whatever legacy JSON
	/// files are still present (either in their original locations
	/// or under `…/Legacy/<file>.legacy`). Used by the Debug menu
	/// for diagnosing migration issues; new rows are skipped if the
	/// matching id already exists in SwiftData.
	@MainActor
	private static func reimportFromLegacyJSON() {
		do {
			try JSONImporter.importAll(into: PersistenceController.shared.container)
			Dialogs.showAlert(
				title: String(localized: "Re-import Complete"),
				message: String(localized: "Legacy JSON content was successfully re-imported into the SwiftData store. Restart Sidekick to see the latest data.")
			)
		} catch {
			Dialogs.showAlert(
				title: String(localized: "Re-import Failed"),
				message: error.localizedDescription
			)
		}
	}
	
	private static var debugSettings: some View {
		Menu("Settings") {
			Button(
				action: Settings.clearUserDefaults
			) {
				Text("Clear All Settings")
			}
			Button(
				action: InferenceSettings.setDefaults
			) {
				Text("Set Inference Settings to Defaults")
			}
		}
	}
	
	private static var debugConversations: some View {
		Menu("Conversations") {
			Button(
				action: ConversationManager.shared.createBackup
			) {
				Text("Backup Conversations")
			}
			if ConversationManager.shared.backupExists {
				Button(
					action: ConversationManager.shared.retoreFromBackup
				) {
					Text("Restore Conversations from Backup")
				}
			}
			Button(
				action: ConversationManager.shared.resetDatastore
			) {
				Text("Delete All Conversations")
			}
		}
	}
	
}

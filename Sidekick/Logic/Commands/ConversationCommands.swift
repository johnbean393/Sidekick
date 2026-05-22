//
//  ConversationCommands.swift
//  Sidekick
//
//  Created by Bean John on 10/8/24.
//

import Foundation
import SwiftUI

@MainActor
public class ConversationCommands {
	
	/// The `New Conversation` command replacing the new file command
	static var commands: some Commands {
		CommandGroup(replacing: .newItem) {
			Button {
				ConversationManager.shared.newConversation()
			} label: {
				Text("New Conversation")
			}
			.keyboardShortcut("n", modifiers: .command)
		}
	}

	/// A set to commands to activate experts
	static var expertCommands: some Commands {
		CommandGroup(after: .newItem) {
			Menu {
				ForEach(
					ExpertManager.experts()
				) { expert in
					ExpertSelectionButton(
						expert: expert
					)
				}
			} label: {
				Text("Experts")
			}
		}
	}
	
	/// A button to activate an expert
	private struct ExpertSelectionButton: View {
		
		/// The expert that is activated on press, of type ``Expert``
		public var expert: Expert
		
		/// The index of the expert, of type `Int`
		private var index: Int {
			return ExpertManager.getExpertIndex(
				expert: expert
			) + 1
		}
		
		public var body: some View {
			Button {
				self.selectExpert()
			} label: {
				Text(expert.name)
			}
			.if(index <= 10) { view in
				view
					.keyboardShortcut(
						KeyEquivalent(
							Character(
                                String(
									(index % 10)
								)
							)
						),
						modifiers: .command
					)
			}
		}
		
		/// Function to select the expert associated with this button
		private func selectExpert() {
			AppState.setCommandSelectedExpertId(
				expert.id
			)
			NotificationCenter.default.post(
				name: Notifications.didCommandSelectExpert.name,
				object: nil
			)
		}
		
	}
	
}

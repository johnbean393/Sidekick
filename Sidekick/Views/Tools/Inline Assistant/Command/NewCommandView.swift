//
//  NewCommandView.swift
//  Sidekick
//
//  Created by Bean John on 11/19/24.
//

import SwiftUI

struct NewCommandView: View {

	@State private var name: String = ""
	@State private var prompt: String = ""
	@Binding var isAddingCommand: Bool
	
    var body: some View {
		VStack(
			alignment: .leading
		) {
			form
			controls
		}
		.padding()
    }
	
	var form: some View {
		Form {
			Section {
				VStack(
					alignment: .leading
				) {
					nameEditor
					promptEditor
				}
				.padding(.horizontal, 5)
			}
		}
		.formStyle(.grouped)
	}
	
	var nameEditor: some View {
		Group {
			HStack {
				VStack(alignment: .leading) {
					Text("Name")
						.font(.title3)
						.bold()
					Text("This command's name")
						.font(.caption)
				}
				Spacer()
				TextField("", text: $name)
					.textFieldStyle(.plain)
			}
		}
	}
	
	var promptEditor: some View {
		Group {
			HStack(
				alignment: .top
			) {
				VStack(alignment: .leading) {
					Text("Prompt")
						.font(.title3)
						.bold()
					Text("This command's prompt")
						.font(.caption)
				}
				Spacer()
				TextEditor(text: $prompt)
					.frame(minHeight: 125)
			}
		}
	}
	
	var controls: some View {
		HStack {
			Spacer()
			Button {
				self.isAddingCommand.toggle()
			} label: {
				Text("Cancel")
			}
			Button {
				let newCommand: Command = .init(
					name: name,
					prompt: prompt
				)
				CommandManager.add(newCommand)
				self.isAddingCommand.toggle()
			} label: {
				Text("Add")
			}
			.disabled(name.isEmpty || prompt.isEmpty)
			.keyboardShortcut(.defaultAction)
		}
	}
	
}

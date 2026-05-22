//
//  CommandButton.swift
//  Sidekick
//
//  Created by Bean John on 11/18/24.
//

import SwiftUI

struct CommandButton: View {

    @EnvironmentObject private var model: Model
    @EnvironmentObject private var inlineAssistantController: InlineAssistantController

    @State private var isEditingCommand: Bool = false
    @State private var editingCommand: Command

    let command: Command
    var action: () -> Void

    init(command: Command, action: @escaping () -> Void) {
        self.command = command
        self.action = action
        self._editingCommand = State(initialValue: command)
    }

    var body: some View {
        Button {
            self.action()
        } label: {
            label
        }
        .buttonStyle(.plain)
        .contextMenu {
            contextMenu
        }
        .sheet(isPresented: $isEditingCommand) {
            CommandEditorView(
                command: $editingCommand,
                isEditingCommand: $isEditingCommand
            )
            .frame(minWidth: 350, minHeight: 300)
        }
    }

    var label: some View {
        Text(self.command.name)
            .bold()
            .padding(5)
            .background {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.textBackground)
            }
            .font(.body)
    }

    var contextMenu: some View {
        Group {
            Button {
                self.editingCommand = self.command
                self.isEditingCommand.toggle()
            } label: {
                Text("Edit")
            }
            Button {
                CommandManager.delete(id: self.command.id)
            } label: {
                Text("Delete")
            }
        }
    }
}

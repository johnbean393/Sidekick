//
//  ServerArgumentsEditor.swift
//  Sidekick
//
//  Created by John Bean on 4/29/25.
//

import SwiftData
import SwiftUI

struct ServerArgumentsEditor: View {

    @Binding var isPresented: Bool

    @State private var tableId: UUID = UUID()

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ServerArgumentEntity.sortIndex)
    private var argumentRows: [ServerArgumentEntity]

    @State private var selections = Set<UUID>()

    var body: some View {
        VStack {
            table
                .id(tableId)
                .padding(.horizontal, 10)
            Divider()
            bottomBar
        }
        .padding(.vertical, 12)
    }

    var bottomBar: some View {
        HStack {
            Link(
                "Docs",
                destination: URL(
                    string: "https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md"
                )!
            )
            Spacer()
            resetButton
            addButton
            doneButton
        }
        .controlSize(.large)
        .padding(.horizontal, 12)
    }

    var resetButton: some View {
        Button {
            let _ = Dialogs.showConfirmation(
                title: String(localized: "Delete All Server Arguments"),
                message: String(localized: "Are you sure you want to delete all server arguments?")
            ) {
                withAnimation(.linear) {
                    ServerArgumentsStore.resetToDefaults()
                    self.tableId = UUID()
                }
            }
        } label: {
            Text("Use Defaults")
        }
    }

    var addButton: some View {
        Button {
            withAnimation(.linear) {
                ServerArgumentsStore.add(ServerArgument(flag: "", value: ""))
            }
        } label: {
            Text("Add")
        }
    }

    var doneButton: some View {
        Button {
            NotificationCenter.default.post(
                name: Notifications.changedInferenceConfig.name,
                object: nil
            )
            withAnimation(.linear) {
                self.isPresented.toggle()
            }
        } label: {
            Text("Done")
        }
    }

    var table: some View {
        Table(of: ServerArgumentEntity.self, selection: $selections) {
            TableColumn("Active") { row in
                @Bindable var row = row
                Toggle(isOn: $row.isActive, label: {})
                    .toggleStyle(.checkbox)
            }
            .width(max: 37.5)
            TableColumn("Flag") { row in
                @Bindable var row = row
                if let commonArgument = ServerArgument.CommonArgument(flag: row.flag) {
                    commonArgument.label
                } else {
                    TextField(text: $row.flag, label: {})
                }
            }
            TableColumn("Value") { row in
                @Bindable var row = row
                if let commonArgument = ServerArgument.CommonArgument(flag: row.flag) {
                    commonArgument.getEditor(stringValue: $row.value)
                } else {
                    TextField(text: $row.value, label: {})
                }
            }
            .width(min: 250)
        } rows: {
            ForEach(argumentRows) { row in
                TableRow(row)
                    .contextMenu {
                        Button {
                            ServerArgumentsStore.delete(id: row.id)
                        } label: {
                            Text("Delete")
                        }
                    }
            }
        }
    }
}

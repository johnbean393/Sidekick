//
//  ExpertEditorView.swift
//  Sidekick
//
//  Created by Bean John on 10/10/24.
//

import SwiftUI
import SymbolPicker

struct ExpertEditorView: View {
    
        @Environment(LengthyTasksController.self) private var lengthyTasksController
    
    @Binding var expert: Expert
    
    @State private var isSelectingSymbol: Bool = false
    @State private var systemPrompt: String = ""
    
    @Binding var isEditing: Bool
    
    var isUpdating: Bool {
        let taskName: String = String(
            localized: "Updating resource index for expert \"\(self.expert.name)\""
        )
        return lengthyTasksController.tasks
            .map(\.name)
            .contains(
                taskName
            )
    }
    
    var body: some View {
        VStack {
            Group {
                form
            }
            Divider()
            HStack {
                Spacer()
                Button {
                    isEditing.toggle()
                } label: {
                    Text("Done")
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
            }
            .padding([.trailing, .bottom], 10)
        }
        .onAppear {
            systemPrompt = expert.systemPrompt ?? InferenceSettings.systemPrompt
        }
        .sheet(isPresented: $isSelectingSymbol) {
            SymbolPicker(
                symbol: $expert.symbolName
            )
            .frame(maxWidth: 600, maxHeight: 800)
        }
    }
    
    var form: some View {
        Form {
            if !self.expert.isDefault {
                Section {
                    name
                } header: {
                    Text("Name")
                }
                Section {
                    icon
                } header: {
                    Text("Icon")
                }
            }
            ResourceSectionView(expert: self.$expert)
            Section {
                webSearch
            } header: {
                Text("Search")
            }
            Section {
                systemPromptEditor
            } header: {
                Text("System Prompt")
            }
        }
        .formStyle(.grouped)
    }
    
    var name: some View {
        Group {
            HStack {
                VStack(alignment: .leading) {
                    Text("Name")
                        .font(.title3)
                        .bold()
                    Text("This expert's name")
                        .font(.caption)
                }
                Spacer()
                TextField("", text: $expert.name)
                    .textFieldStyle(.plain)
                    .disabled(isUpdating)
            }
        }
        .padding(.horizontal, 5)
    }
    
    var icon: some View {
        Group {
            VStack {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Icon:")
                            .font(.title3)
                            .bold()
                        Text("This expert's icon")
                            .font(.caption)
                    }
                    Spacer()
                    expert.label
                }
                symbol
                HStack {
                    VStack(alignment: .leading) {
                        Text("Color:")
                            .font(.title3)
                            .bold()
                        Text("This icon's color")
                            .font(.caption)
                    }
                    Spacer()
                    ColorPicker(
                        "",
                        selection: $expert.color,
                        supportsOpacity: false
                    )
                    .disabled(isUpdating)
                }
            }
            .padding(.horizontal, 5)
        }
    }
    
    var symbol: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("Symbol:")
                    .font(.title3)
                    .bold()
                Text("This icon's symbol")
                    .font(.caption)
            }
            Spacer()
            Button {
                isSelectingSymbol.toggle()
            } label: {
                Label("Change", systemImage: expert.symbolName)
                    .labelStyle(.titleAndIcon)
            }
            .disabled(isUpdating)
        }
    }
    
    var webSearch: some View {
        Group {
            if RetrievalSettings.canUseWebSearch {
                HStack(alignment: .center) {
                    VStack(alignment: .leading) {
                        Text("Use Search")
                            .font(.title3)
                            .bold()
                        Text("Controls whether this expert searches the web before answering. Note that when enabled, this feature may lead to slower responses.")
                            .font(.caption)
                    }
                    Spacer()
                    Toggle("", isOn: $expert.useWebSearch)
                }
                .padding(.horizontal, 5)
            } else {
                Text("Search is not configured properly in Settings")
                    .font(.title3)
                    .bold()
                    .padding()
            }
        }
    }
    
    var systemPromptEditor: some View {
        Group {
            HStack(alignment: .top) {
                VStack(alignment: .leading) {
                    Text("System Prompt")
                        .font(.title3)
                        .bold()
                    Text("This expert's system prompt")
                        .font(.caption)
                    Button {
                        systemPrompt = InferenceSettings.systemPrompt
                    } label: {
                        Text("Use Default")
                    }
                }
                Spacer()
                TextEditor(text: $systemPrompt)
                    .font(.title2)
                    .onChange(
                        of: systemPrompt
                    ) {
                        saveSystemPrompt()
                    }
            }
        }
        .padding(.horizontal, 5)
    }
    
    private func saveSystemPrompt() {
        // Save system prompt changes
        if !systemPrompt.isEmpty {
            if systemPrompt == InferenceSettings.systemPrompt {
                expert.systemPrompt = nil
                return
            }
            expert.systemPrompt = systemPrompt
        }
    }
    
}

//#Preview {
//    ExpertEditorView()
//}

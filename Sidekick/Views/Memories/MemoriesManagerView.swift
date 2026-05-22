//
//  MemoriesManagerView.swift
//  Sidekick
//
//  Created by John Bean on 4/22/25.
//

import SwiftUI

struct MemoriesManagerView: View {
    
    @Environment(MemoryIndex.self) private var memories

    @State private var query: String = ""
    
    var filteredMemories: [Memory] {
        if query.isEmpty {
            return memories.memories
        } else {
            return memories.memories.filter { memory in
                return memory.text.lowercased().contains(query.lowercased())
            }
        }
    }
    
    var body: some View {
        Section {
            List(
                filteredMemories
            ) { memory in
                MemoryRowView(memory: memory)
                    .listRowSeparator(.visible)
            }
            .listStyle(.inset)
        }
        .navigationTitle("Memories")
        .searchable(
            text: self.$query.animation(.linear),
            placement: .toolbar,
            prompt: "Search Memories"
        )
        .toolbar {
            ToolbarItemGroup {
                Button {
                    self.memories.resetDatastore()
                } label: {
                    Label("Delete All Memories", systemImage: "trash")
                }
                .labelStyle(.iconOnly)
                PopoverButton(
                    arrowEdge: .bottom
                ) {
                    Label("Info", systemImage: "info.circle")
                        .labelStyle(.iconOnly)
                } content: {
                    VStack {
                        Text("Memories")
                            .font(.title2)
                            .bold()
                            .padding(.bottom, 5)
                        Text("Sidekick remembers useful details about you and")
                        Text("your preferences so it can be more helpful.")
                    }
                    .padding()
                }
            }
        }
    }
    
    struct MemoryRowView: View {

        @Environment(MemoryIndex.self) private var memories

        var memory: Memory
        
        var body: some View {
            HStack {
                Text(memory.text)
                Spacer()
                Button {
                    withAnimation(.linear) {
                        self.memories.forget(memory)
                    }
                } label: {
                    Label("Delete", systemImage: "trash.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        
    }
    
}

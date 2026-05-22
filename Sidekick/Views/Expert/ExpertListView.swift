//
//  ExpertListView.swift
//  Sidekick
//
//  Created by Bean John on 10/10/24.
//

import SwiftData
import SwiftUI

struct ExpertListView: View {

    @Query private var expertRows: [ExpertEntity]

    /// Snapshot of every expert as a value type, derived from the
    /// `@Query`-driven entity list.
    private var experts: [Expert] {
        expertRows.map(ExpertManager.expert(from:))
    }

    var body: some View {
        List(experts) { expert in
            // Build a write-through binding so the existing
            // ``ExpertNavigationRowView`` / ``ExpertEditorView``
            // mutation API keeps working without refactoring every
            // leaf control to call ``ExpertManager.update(_:)``.
            ExpertNavigationRowView(expert: binding(for: expert))
                .listRowSeparator(.hidden)
        }
    }

    /// Construct a write-through ``Binding<Expert>`` that delegates
    /// reads to the live SwiftData snapshot and writes to
    /// ``ExpertManager.update(_:)``.
    private func binding(for expert: Expert) -> Binding<Expert> {
        Binding(
            get: {
                ExpertManager.getExpert(id: expert.id) ?? expert
            },
            set: { newValue in
                ExpertManager.update(newValue)
            }
        )
    }
}

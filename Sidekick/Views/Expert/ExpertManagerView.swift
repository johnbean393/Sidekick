//
//  ExpertManagerView.swift
//  Sidekick
//
//  Created by Bean John on 10/10/24.
//

import SwiftUI

struct ExpertManagerView: View {
	
		@Environment(ConversationState.self) private var conversationState

	@State private var selectedExpertId: UUID? = ExpertManager.experts().first?.id

	var selectedExpert: Expert? {
		guard let selectedExpertId = selectedExpertId else { return nil }
		return ExpertManager.getExpert(id: selectedExpertId)
	}

	@State private var editingExpert: Expert = ExpertManager.experts().first ?? Expert.default
	
	var body: some View {
		VStack {
			HStack {
				ExitButton {
					conversationState.isManagingExperts.toggle()
				}
				Spacer()
			}
			.padding(.leading)
			ExpertListView()
			Spacer()
			newExpertButton
		}
		.padding(.vertical)
	}
	
	var newExpertButton: some View {
		Button {
			self.newExpert()
		} label: {
			Label("Add Expert", systemImage: "plus")
		}
		.buttonStyle(PlainButtonStyle())
	}
	
	private func newExpert() {
		let newExpert: Expert = Expert(
			name: "Untitled",
			symbolName: "questionmark.circle.fill",
			color: Color.white
		)
		ExpertManager.add(newExpert)
	}
	
}

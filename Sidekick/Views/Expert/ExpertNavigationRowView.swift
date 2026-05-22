//
//  ExpertNavigationRowView.swift
//  Sidekick
//
//  Created by Bean John on 10/11/24.
//

import SwiftUI

struct ExpertNavigationRowView: View {
	
		@State private var isEditing: Bool = false
	@State private var isDeleting: Bool = false
	
	@State private var isHovering: Bool = false
	
	@Binding var expert: Expert
	
	var isDefault: Bool {
		return expert.id == ExpertManager.default?.id
	}
	
	var body: some View {
		HStack {
			editButton
			Spacer()
			controls
		}
		.padding(.leading, 4)
		.padding(.trailing)
		.background {
			RoundedRectangle(cornerRadius: 7)
				.fill(self.expert.color)
				.shadow(radius: 1.0)
		}
		.onHover { hovering in
			self.isHovering = hovering
		}
		.sheet(isPresented: $isEditing) {
			ExpertEditorView(
				expert: $expert, isEditing: $isEditing
			)
			.frame(minWidth: 650, maxHeight: 700)
		}
		.contextMenu {
			deleteButton
		}
		.confirmationDialog(
			"Delete",
			isPresented: $isDeleting
		) {
			Button {
				ExpertManager.delete(id: self.expert.id)
				withAnimation(.linear) {
					self.isDeleting = false
				}
			} label: {
				Text("Confirm")
			}
		} message: {
			Text("Are you sure you want to delete this expert?")
		}
	}
	
	var editButton: some View {
		Button {
			self.isEditing.toggle()
		} label: {
			self.expert.label
		}
		.buttonStyle(.plain)
	}
	
	var controls: some View {
		Group {
			if isHovering {
				Button {
					self.isEditing.toggle()
				} label: {
					Label("Edit", systemImage: "square.and.pencil")
						.foregroundStyle(self.expert.color.adaptedTextColor)
				}
				.padding(.bottom, 2.5)
			}
			if !isDefault && isHovering {
				deleteButton
			}
		}
		.buttonStyle(.plain)
		.labelStyle(.iconOnly)
	}
	
	var deleteButton: some View {
		Button {
			self.isDeleting.toggle()
		} label: {
			Label("Delete", systemImage: "trash")
				.foregroundStyle(.red)
		}
	}

}

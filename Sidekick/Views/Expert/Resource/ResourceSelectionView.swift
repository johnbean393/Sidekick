//
//  ResourceSelectionView.swift
//  Sidekick
//
//  Created by Bean John on 10/11/24.
//

import Foundation
import SwiftUI

struct ResourceSelectionView: View {
    
    @State private var timer: Timer? = nil
    
	@Binding var expert: Expert
	@Environment(LengthyTasksController.self) private var lengthyTasksController
	
	var hasResources: Bool {
        return !self.expert.resources.resources.isEmpty
	}
	
	var body: some View {
		Group {
			if hasResources {
				list
			} else {
                NoResourceView(
                    expert: self.$expert
                )
			}
		}
		.frame(minHeight: 30)
		.padding(3)
	}
	
	var list: some View {
		List(
			$expert.resources.resources,
			editActions: .move
		) { resource in
			ResourceRowView(
				expert: $expert,
				resource: resource
			)
			.transition(
				.asymmetric(
					insertion: .push(from: .leading),
					removal: .move(edge: .leading)
				)
			)
		}
		.padding(.horizontal)
		.listStyle(.plain)
	}
    
    struct NoResourceView: View {
        
        @Binding var expert: Expert
        
        @Environment(LengthyTasksController.self) private var lengthyTasksController
        
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
        
        var description: String {
            if isUpdating {
                return String(localized: "Indexing in Progress")
            } else {
                return String(localized: "No resources")
            }
        }
        
        var body: some View {
            HStack {
                Spacer()
                VStack {
                    Text(description)
                        .foregroundStyle(.secondary)
                    if isUpdating {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.5)
                    }
                }
                Spacer()
            }
        }
    }
	
}

struct ResourceRowView: View {
	
	@Binding var expert: Expert
	@Binding var resource: Resource
	
	@State private var isHovering: Bool = false

	var body: some View {
		HStack {
			Text(resource.name)
			Spacer()
		}
		.overlay(alignment: .trailing) {
			if isHovering {
				actions
			}
		}
		.onHover { hover in
			withAnimation(.linear) {
				isHovering = hover
			}
		}
		.contextMenu {
			if !resource.url.isWebURL && isHovering {
				showInFinder
			}
		}
	}
	
	var actions: some View {
		Button {
			Task { @MainActor in
				await remove()
			}
		} label: {
			Label("Remove", systemImage: "trash")
				.foregroundStyle(.red)
				.labelStyle(.iconOnly)
		}
		.buttonStyle(.plain)
	}
	
	var showInFinder: some View {
		Button {
			FileManager.showItemInFinder(
				url: resource.url
			)
		} label: {
			Text("Show in Finder")
		}
		.keyboardShortcut("f", modifiers: .command)
	}
	
	@MainActor
	func remove() async {
		await $expert.removeResource(resource)
	}
	
}

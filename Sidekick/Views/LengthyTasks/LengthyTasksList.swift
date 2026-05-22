//
//  LengthyTasksList.swift
//  Sidekick
//
//  Created by Bean John on 10/14/24.
//

import SwiftUI

struct LengthyTasksList: View {
	
	@Environment(LengthyTasksController.self) private var lengthyTasksController
	
    var body: some View {
		Group {
			if !self.lengthyTasksController.hasTasks {
				noTasks
			} else {
				list
			}
		}
		.padding(7)
		.foregroundStyle(.primary)
    }
	
	var noTasks: some View {
		Text("No tasks in progress")
	}
	
	var list: some View {
		List(
			lengthyTasksController.tasks.indices,
			id: \.self
		) { index in
			HStack {
				Text(lengthyTasksController.tasks[index].name)
				Spacer()
				SpinnerView()
			}
		}
		.listStyle(.sidebar)
		.frame(
			minWidth: 400,
			minHeight: 60,
			maxHeight: 400
		)
	}
	
	private struct SpinnerView: View {
		
		var body: some View {
			ProgressView()
				.progressViewStyle(.circular)
				.scaleEffect(0.5, anchor: .center)
		}
		
	}
	
}

#Preview {
    LengthyTasksList()
}

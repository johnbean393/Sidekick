//
//  LengthyTasksController.swift
//  Sidekick
//
//  Created by Bean John on 10/14/24.
//
//  Converted from `ObservableObject` to `@Observable` as part of
//  Phase 1 of the SwiftData migration.
//

import Foundation
import Observation

@MainActor
@Observable
public final class LengthyTasksController {

    static let shared: LengthyTasksController = .init()

    var tasks: [LengthyTask] = []

    /// Computed property that returns whether there are tasks
    public var hasTasks: Bool {
        return !self.tasks.isEmpty
    }

    /// Function to add task to list
    public func addTask(id: UUID, task: String) {
        self.tasks.append(
            LengthyTask(id: id, name: task)
        )
    }

    /// Function to finish task
    public func finishTask(taskId: UUID) {
        for index in self.tasks.indices {
            if self.tasks[index].id == taskId {
                self.tasks.remove(at: index)
                break
            }
        }
    }

    struct LengthyTask: Identifiable, Equatable {
        var id: UUID = UUID()
        var name: String
    }
}

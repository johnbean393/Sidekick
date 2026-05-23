//
//  TodoFunctions.swift
//  Sidekick
//
//  Created by John Bean on 11/6/25.
//

import Foundation

public class TodoFunctions {
    
    /// Storage for active to-do lists (keyed by conversation ID or session)
    static var activeTodoLists: [String: TodoList] = [:]
    
    /// Thread-safe access to active to-do lists
    private static let todoListQueue = DispatchQueue(label: "com.sidekick.todolist", attributes: .concurrent)
    
    static var functions: [AnyFunctionBox] = [
        TodoFunctions.createTodoList,
        TodoFunctions.addTodoItem,
        TodoFunctions.finishTodoItem
    ]
    
    /// A function to create a new to-do list
    static let createTodoList = Function<CreateTodoListParams, String>(
        name: "create_todo_list",
        description: "Creates a persistent to-do list. Incomplete items are surfaced back to you after each tool call.",
        params: [
            FunctionParameter(
                label: "list_id",
                description: "Unique identifier for the list (e.g. `analysis_tasks`).",
                datatype: .string,
                isRequired: true
            ),
            FunctionParameter(
                label: "title",
                description: "List title.",
                datatype: .string,
                isRequired: true
            ),
            FunctionParameter(
                label: "items",
                description: "Actionable to-do items.",
                datatype: .stringArray,
                isRequired: true
            )
        ],
        run: { params in
            return try todoListQueue.sync(flags: .barrier) {
                guard !params.items.isEmpty else {
                    throw TodoError.noItemsProvided
                }
                
                // Create new to-do list
                let todoList = TodoList(
                    id: params.list_id,
                    title: params.title,
                    items: params.items.enumerated().map { index, description in
                        TodoItem(id: "\(index)", description: description)
                    }
                )
                
                // Store the list
                activeTodoLists[params.list_id] = todoList
                
                return """
Created to-do list '\(params.title)' with \(params.items.count) items:

\(todoList.formattedList())
"""
            }
        }
    )
    struct CreateTodoListParams: FunctionParams {
        let list_id: String
        let title: String
        let items: [String]
    }
    
    /// A function to add items to an existing to-do list
    static let addTodoItem = Function<AddTodoItemParams, String>(
        name: "add_todo_item",
        description: "Adds items to an existing to-do list.",
        params: [
            FunctionParameter(
                label: "list_id",
                description: "List identifier.",
                datatype: .string,
                isRequired: true
            ),
            FunctionParameter(
                label: "items",
                description: "Items to add.",
                datatype: .stringArray,
                isRequired: true
            )
        ],
        run: { params in
            return try todoListQueue.sync(flags: .barrier) {
                guard var todoList = activeTodoLists[params.list_id] else {
                    throw TodoError.listNotFound(params.list_id)
                }
                
                guard !params.items.isEmpty else {
                    throw TodoError.noItemsProvided
                }
                
                // Add new items
                let startIndex = todoList.items.count
                let newItems = params.items.enumerated().map { index, description in
                    TodoItem(id: "\(startIndex + index)", description: description)
                }
                
                todoList.items.append(contentsOf: newItems)
                activeTodoLists[params.list_id] = todoList
                
                return """
Added \(params.items.count) new item(s) to '\(todoList.title)':

\(newItems.map { "• \($0.description)" }.joined(separator: "\n"))

Current status:
\(todoList.formattedList())
"""
            }
        }
    )
    struct AddTodoItemParams: FunctionParams {
        let list_id: String
        let items: [String]
    }
    
    /// A function to mark items as finished
    static let finishTodoItem = Function<FinishTodoItemParams, String>(
        name: "finish_todo_item",
        description: "Marks items in a to-do list as finished. Provide either indices or descriptions.",
        params: [
            FunctionParameter(
                label: "list_id",
                description: "List identifier.",
                datatype: .string,
                isRequired: true
            ),
            FunctionParameter(
                label: "item_indices",
                description: "0-based indices of items to mark finished.",
                datatype: .integerArray,
                isRequired: false
            ),
            FunctionParameter(
                label: "item_descriptions",
                description: "Substrings matching items to mark finished.",
                datatype: .stringArray,
                isRequired: false
            )
        ],
        run: { params in
            return try todoListQueue.sync(flags: .barrier) {
                guard var todoList = activeTodoLists[params.list_id] else {
                    throw TodoError.listNotFound(params.list_id)
                }
                
                var finishedCount = 0
                var finishedItems: [String] = []
                
                // Mark by indices
                if let indices = params.item_indices {
                    for index in indices {
                        guard index >= 0 && index < todoList.items.count else {
                            throw TodoError.invalidItemIndex(index, todoList.items.count)
                        }
                        if !todoList.items[index].isCompleted {
                            todoList.items[index].isCompleted = true
                            finishedItems.append(todoList.items[index].description)
                            finishedCount += 1
                        }
                    }
                }
                
                // Mark by descriptions
                if let descriptions = params.item_descriptions {
                    for description in descriptions {
                        for i in todoList.items.indices {
                            if !todoList.items[i].isCompleted &&
                                todoList.items[i].description.localizedCaseInsensitiveContains(description) {
                                todoList.items[i].isCompleted = true
                                finishedItems.append(todoList.items[i].description)
                                finishedCount += 1
                                break // Only mark the first match
                            }
                        }
                    }
                }
                
                guard finishedCount > 0 else {
                    throw TodoError.noItemsToFinish
                }
                
                activeTodoLists[params.list_id] = todoList
                
                let remainingCount = todoList.items.filter { !$0.isCompleted }.count
                
                return """
Marked \(finishedCount) item(s) as finished:
\(finishedItems.map { "✓ \($0)" }.joined(separator: "\n"))

\(remainingCount > 0 ? "Remaining items:\n\(todoList.formattedList())" : "All items completed! 🎉")
"""
            }
        }
    )
    struct FinishTodoItemParams: FunctionParams {
        let list_id: String
        let item_indices: [Int]?
        let item_descriptions: [String]?
    }
    
    /// Get formatted incomplete to-do items for all active lists
    static func getIncompleteTodoSummary() -> String? {
        return todoListQueue.sync {
            let incompleteLists = activeTodoLists.values.filter { list in
                list.items.contains { !$0.isCompleted }
            }
            
            guard !incompleteLists.isEmpty else {
                return nil
            }
            
            let summaries = incompleteLists.map { list -> String in
                let incompleteItems = list.items.enumerated().compactMap { index, item -> String? in
                    !item.isCompleted ? "  \(index). [ ] \(item.description)" : nil
                }
                return """
To-Do List: \(list.title) (ID: \(list.id))
\(incompleteItems.joined(separator: "\n"))
"""
            }
            
            return """

---

📋 Active To-Do Lists (Incomplete Items):

\(summaries.joined(separator: "\n\n"))

Use `finish_todo_item` to mark items as complete, or `add_todo_item` to add more tasks.
"""
        }
    }
    
    /// Clear all to-do lists (useful for cleanup)
    static func clearAllTodoLists() {
        todoListQueue.sync(flags: .barrier) {
            activeTodoLists.removeAll()
        }
    }
    
    /// Clear a specific to-do list
    static func clearTodoList(id: String) {
        let _ = todoListQueue.sync(flags: .barrier) {
            activeTodoLists.removeValue(forKey: id)
        }
    }
    
}

// MARK: - Supporting Types

struct TodoList {
    let id: String
    let title: String
    var items: [TodoItem]
    
    func formattedList() -> String {
        return items.enumerated().map { index, item in
            let checkbox = item.isCompleted ? "[✓]" : "[ ]"
            return "\(index). \(checkbox) \(item.description)"
        }.joined(separator: "\n")
    }
}

struct TodoItem {
    let id: String
    let description: String
    var isCompleted: Bool = false
}

// MARK: - Errors

enum TodoError: Error, LocalizedError {
    case listNotFound(String)
    case noItemsProvided
    case invalidItemIndex(Int, Int) // provided index, max count
    case noItemsToFinish
    
    var errorDescription: String? {
        switch self {
            case .listNotFound(let id):
                return "To-do list with ID '\(id)' not found. Create it first using create_todo_list."
            case .noItemsProvided:
                return "No items were provided. Please specify at least one item."
            case .invalidItemIndex(let index, let count):
                return "Invalid item index \(index). The list has \(count) items (indices 0-\(count-1))."
            case .noItemsToFinish:
                return "No matching items found to mark as finished. Check the indices or descriptions provided."
        }
    }
    
}


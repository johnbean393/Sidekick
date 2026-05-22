//
//  FunctionSelection.swift
//  Sidekick
//
//  Replaces the legacy ``FunctionSelectionManager`` singleton with
//  a thin static façade over the SwiftData store. Views should
//  prefer reading the underlying ``FunctionCategorySelectionEntity``
//  rows directly via `@Query`; this helper exists for the handful
//  of non-View call sites (toolbar menus, inference setup) that
//  cannot easily host a `@Query` property.
//

import Foundation
import OSLog
import SwiftData

@MainActor
public enum FunctionSelection {

    private static let logger: Logger = .init(
        subsystem: Bundle.main.bundleIdentifier!,
        category: "FunctionSelection"
    )

    /// Currently enabled function categories. Falls back to "all
    /// enabled" the first time the store is empty (or fails to load).
    public static var enabledCategories: Set<FunctionCategory> {
        let context = ModelContext(PersistenceController.shared.container)
        do {
            let rows = try context.fetch(FetchDescriptor<FunctionCategorySelectionEntity>())
            if rows.isEmpty {
                let defaults = Set(FunctionCategory.allCases)
                Self.write(defaults)
                return defaults
            }
            return Set(rows.compactMap { FunctionCategory(rawValue: $0.rawValue) })
        } catch {
            Self.logger.error("Failed to read function selection: \(error.localizedDescription, privacy: .public)")
            return Set(FunctionCategory.allCases)
        }
    }

    /// Persists the given category set, replacing the current store
    /// contents.
    public static func write(_ categories: Set<FunctionCategory>) {
        let context = ModelContext(PersistenceController.shared.container)
        do {
            let existing = try context.fetch(FetchDescriptor<FunctionCategorySelectionEntity>())
            for row in existing {
                context.delete(row)
            }
            for category in categories {
                context.insert(FunctionCategorySelectionEntity(rawValue: category.rawValue))
            }
            try context.save()
        } catch {
            Self.logger.error("Failed to save function selection: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Whether a category is currently enabled.
    public static func isEnabled(_ category: FunctionCategory) -> Bool {
        enabledCategories.contains(category)
    }

    /// Toggles a single category and persists.
    public static func toggle(_ category: FunctionCategory) {
        var current = enabledCategories
        if current.contains(category) {
            current.remove(category)
        } else {
            current.insert(category)
        }
        write(current)
    }

    /// Enables every category.
    public static func enableAll() {
        write(Set(FunctionCategory.allCases))
    }

    /// Disables every category.
    public static func disableAll() {
        write([])
    }

    /// All function instances belonging to currently enabled
    /// categories.
    public static func getEnabledFunctions() -> [AnyFunctionBox] {
        return enabledCategories.flatMap { $0.functions }
    }
}

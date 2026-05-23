//
//  FunctionCategory.swift
//  Sidekick
//
//  Created by John Bean on 11/10/25.
//

import Foundation

/// Enum representing different categories of functions available for tool calling
public enum FunctionCategory: String, Codable, CaseIterable, Identifiable, Equatable {
    
    case calendar = "Calendar"
    case code = "Code"
    case expert = "Expert"
    case file = "File"
    case input = "Input"
    case reminders = "Reminders"
    case todo = "Todo"
    case web = "Web"
    case contacts = "Contacts"
    case diagram = "Diagram"
    
    public var id: String {
        return self.rawValue
    }
    
    /// User-facing description of the function category
    var description: String {
        switch self {
        case .calendar:
            return String(localized: "Calendar")
        case .code:
            return String(localized: "Code")
        case .expert:
            return String(localized: "Expert")
        case .file:
            return String(localized: "File")
        case .input:
            return String(localized: "Input")
        case .reminders:
            return String(localized: "Reminders")
        case .todo:
            return String(localized: "Todo")
        case .web:
            return String(localized: "Web")
        case .contacts:
            return String(localized: "Contacts")
        case .diagram:
            return String(localized: "Diagram")
        }
    }
    
    /// Get functions for this category
    var functions: [AnyFunctionBox] {
        switch self {
        case .calendar:
            return CalendarFunctions.functions
        case .code:
            return CodeFunctions.functions
        case .expert:
            return ExpertFunctions.functions
        case .file:
            return FileFunctions.functions
        case .input:
            return InputFunctions.functions
        case .reminders:
            return RemindersFunctions.functions
        case .todo:
            return TodoFunctions.functions
        case .web:
            return WebFunctions.functions
        case .contacts:
            return [DefaultFunctions.fetchContacts]
        case .diagram:
            return [DefaultFunctions.drawDiagram]
        }
    }
    
}

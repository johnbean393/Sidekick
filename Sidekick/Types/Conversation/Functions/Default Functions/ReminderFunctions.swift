//
//  RemindersFunctions.swift
//  Sidekick
//
//  Created by John Bean on 4/17/25.
//

import EventKit
import Foundation

public class RemindersFunctions {
    
    static var functions: [AnyFunctionBox] = [
        RemindersFunctions.getReminders,
        RemindersFunctions.addReminder
    ]
    
    /// An object representing a ``Reminder``
    public struct Reminder: Identifiable, Codable {
        
        init(
            reminder: EKReminder
        ) {
            self.title = reminder.title
            self.reminderIdentifier = reminder.calendarItemIdentifier
            self.dueDate = reminder.dueDateComponents?.date?.toString(dateFormat: "yyyy-MM-dd HH:mm:ss")
            self.isCompleted = reminder.isCompleted
            self.notes = reminder.notes
            self.priority = {
                switch reminder.priority {
                    case 1:
                        return "High"
                    case 5:
                        return "Medium"
                    case 9:
                        return "Low"
                    default:
                        return "None"
                }
            }()
            self.completionDate = reminder.completionDate?.toString(dateFormat: "yyyy-MM-dd HH:mm:ss")
        }
        
        public var id: String { self.reminderIdentifier }
        
        var title: String
        var dueDate: String?
        var isCompleted: Bool
        var notes: String?
        var priority: String
        var completionDate: String?
        var reminderIdentifier: String
        
    }
    
    /// A set of errors applicable to multiple reminder functions
    public enum RemindersFunctionsError: LocalizedError {
        
        case noPermissions
        case invalidDateFormat
        case failedToSaveReminder(Error)
        
        public var errorDescription: String? {
            switch self {
                case .invalidDateFormat:
                    return "Invalid date format"
                case .noPermissions:
                    return "Permissions to access reminders was denied"
                case .failedToSaveReminder(let error):
                    return "Failed to save reminder: \(error.localizedDescription)"
            }
        }
        
    }
    
    /// A function to request full access to the user's reminders
    /// - Returns: A boolean indicating whether access was granted.
    private static func requestRemindersAccess() async -> Bool {
        let eventStore = EKEventStore()
        return await withCheckedContinuation { continuation in
            eventStore.requestFullAccessToReminders { granted, error in
                continuation.resume(returning: granted)
            }
        }
    }
    
    /// A function to convert strings to dates
    private static func convertStringToDate(_ input: String) throws -> Date {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if let date = dateFormatter.date(from: input) {
            return date
        } else {
            throw RemindersFunctionsError.invalidDateFormat
        }
    }
    
    /// A ``Function`` for getting all reminders, optionally filtered by completion state and due date range
    static let getReminders = Function<GetRemindersParams, String>(
        name: "get_reminders",
        description: "Returns reminders, optionally filtered by completion and due-date range.",
        clearance: .sensitive,
        params: [
            FunctionParameter(
                label: "completed",
                description: "Include completed reminders. Defaults to false.",
                datatype: .boolean,
                isRequired: false
            ),
            FunctionParameter(
                label: "startDueDate",
                description: "Start due date in `yyyy-MM-dd HH:mm:ss`.",
                datatype: .string,
                isRequired: false
            ),
            FunctionParameter(
                label: "endDueDate",
                description: "End due date in `yyyy-MM-dd HH:mm:ss`.",
                datatype: .string,
                isRequired: false
            )
        ],
        run: { params in
            // Ask for permissions
            if await !RemindersFunctions.requestRemindersAccess() {
                throw RemindersFunctionsError.noPermissions
            }
            let eventStore = EKEventStore()
            let predicate: NSPredicate
            let calendars = eventStore.calendars(for: .reminder)
            // Build predicate for date range or all reminders
            if let startDue = params.startDueDate, let endDue = params.endDueDate {
                let startDate = try RemindersFunctions.convertStringToDate(startDue)
                let endDate = try RemindersFunctions.convertStringToDate(endDue)
                predicate = eventStore.predicateForIncompleteReminders(
                    withDueDateStarting: startDate,
                    ending: endDate,
                    calendars: calendars
                )
            } else {
                predicate = eventStore.predicateForReminders(in: calendars)
            }
            
            // Fetch reminders (async API)
            let reminders = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[EKReminder], Error>) in
                eventStore.fetchReminders(matching: predicate) { reminders in
                    continuation.resume(returning: reminders ?? [])
                }
            }
            
            let filteredReminders: [Reminder]
            if let completed = params.completed {
                filteredReminders = reminders
                    .filter { $0.isCompleted == completed }
                    .map { Reminder(reminder: $0) }
            } else {
                filteredReminders = reminders.map { Reminder(reminder: $0) }
            }
            
            let jsonEncoder: JSONEncoder = JSONEncoder()
            jsonEncoder.outputFormatting = [.prettyPrinted]
            let jsonData: Data = try jsonEncoder.encode(filteredReminders)
            return String(data: jsonData, encoding: .utf8)!
        }
    )
    struct GetRemindersParams: FunctionParams {
        var completed: Bool?
        var startDueDate: String?
        var endDueDate: String?
    }
    
    /// A ``Function`` for adding a reminder to the user's reminders
    static let addReminder = Function<AddReminderParams, String>(
        name: "add_reminder",
        description: "Creates a new reminder.",
        clearance: .sensitive,
        params: [
            FunctionParameter(
                label: "title",
                description: "Reminder title.",
                datatype: .string,
                isRequired: true
            ),
            FunctionParameter(
                label: "dueDate",
                description: "Due date/time in `yyyy-MM-dd HH:mm:ss`.",
                datatype: .string,
                isRequired: false
            ),
            FunctionParameter(
                label: "notes",
                description: "Reminder notes.",
                datatype: .string,
                isRequired: false
            ),
            FunctionParameter(
                label: "priority",
                description: "Priority: 0 = none, 1 = high, 5 = medium, 9 = low.",
                datatype: .integer,
                isRequired: false
            )
        ],
        run: { params in
            if await !RemindersFunctions.requestRemindersAccess() {
                throw RemindersFunctionsError.noPermissions
            }
            let eventStore = EKEventStore()
            let calendars = eventStore.calendars(for: .reminder)
            guard let calendar = eventStore.defaultCalendarForNewReminders() ?? calendars.first else {
                throw RemindersFunctionsError.noPermissions // Could introduce a new error type here
            }
            // Create reminder
            let reminder = EKReminder(eventStore: eventStore)
            reminder.calendar = calendar
            reminder.title = params.title
            if let dueDateString = params.dueDate {
                let dueDate = try RemindersFunctions.convertStringToDate(dueDateString)
                reminder.dueDateComponents = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute, .second],
                    from: dueDate
                )
            }
            if let notes = params.notes {
                reminder.notes = notes
            }
            if let priority = params.priority {
                reminder.priority = priority
            }
            // Create reminder
            do {
                try eventStore.save(reminder, commit: true)
            } catch {
                throw RemindersFunctionsError.failedToSaveReminder(error)
            }
            // Returned the created reminder as JSON
            let createdReminder = RemindersFunctions.Reminder(reminder: reminder)
            let jsonEncoder = JSONEncoder()
            jsonEncoder.outputFormatting = [.prettyPrinted]
            let jsonData = try jsonEncoder.encode(createdReminder)
            return String(data: jsonData, encoding: .utf8)!
        }
    )
    struct AddReminderParams: FunctionParams {
        var title: String
        var dueDate: String?
        var notes: String?
        var priority: Int?
    }
    
}

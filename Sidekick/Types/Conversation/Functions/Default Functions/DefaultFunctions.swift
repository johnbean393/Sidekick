//
//  DefaultFunctions.swift
//  Sidekick
//
//  Created by John Bean on 4/7/25.
//

import AppKit
import Contacts
import Foundation
import FSKit_macOS

public protocol FunctionParams: Codable, Hashable {}

struct BlankParams: FunctionParams {}

public class DefaultFunctions {
    
    /// An list of all functions available (unfiltered)
    static var allFunctions: [AnyFunctionBox] = [
        DefaultFunctions.chatFunctions
    ].flatMap { $0 }
    
    /// An sorted list of all functions available (unfiltered)
    static var sortedFunctions: [AnyFunctionBox] {
        return DefaultFunctions.allFunctions.sorted(by: {
            $0.params.count > $1.params.count
        })
    }
    
    /// An list of functions available in chat (unfiltered)
    static var chatFunctions: [AnyFunctionBox] = [
        CalendarFunctions.functions,
        CodeFunctions.functions,
        ExpertFunctions.functions,
        FileFunctions.functions,
        InputFunctions.functions,
        RemindersFunctions.functions,
        TodoFunctions.functions,
        WebFunctions.functions,
        [
            DefaultFunctions.fetchContacts,
            DefaultFunctions.drawDiagram
        ]
    ].flatMap { $0 }
    
    /// Get enabled functions based on FunctionSelectionManager
    static func getEnabledFunctions() async -> [AnyFunctionBox] {
        return await MainActor.run { FunctionSelection.getEnabledFunctions() }
    }
    
    /// Get sorted enabled functions based on FunctionSelectionManager
    static func getSortedEnabledFunctions() async -> [AnyFunctionBox] {
        let functions = await getEnabledFunctions()
        return functions.sorted(by: {
            $0.params.count > $1.params.count
        })
    }
    
    /// A function to get all contacts
    static let fetchContacts = Function<FetchContactsParams, String>(
        name: "fetch_contacts",
        description: "Returns the user's macOS contacts (name, emails, phones, birthday, address). Optionally filter by name, email, or phone.",
        clearance: .sensitive,
        params: [
            FunctionParameter(
                label: "name",
                description: "Substring to match against contact names.",
                datatype: .string,
                isRequired: false
            ),
            FunctionParameter(
                label: "email",
                description: "Substring to match against contact emails.",
                datatype: .string,
                isRequired: false
            ),
            FunctionParameter(
                label: "phone",
                description: "Substring to match against contact phone numbers.",
                datatype: .string,
                isRequired: false
            )
        ],
        run: { params in
            return try await { () -> String in
                struct Contact: Codable {
                    let name: String
                    let emails: [String]
                    let phoneNumbers: [String]
                    let birthday: String?
                    let address: [String]
                }
                // Get contacts
                let store = CNContactStore()
                // Request access to contacts
                let accessGranted = try await CNContactStore.requestContactsAccess(using: store)
                guard accessGranted else {
                    throw ContactError.accessDenied
                }
                // Define the keys we want to fetch
                let keys: [CNKeyDescriptor] = [
                    CNContactGivenNameKey as CNKeyDescriptor,
                    CNContactFamilyNameKey as CNKeyDescriptor,
                    CNContactEmailAddressesKey as CNKeyDescriptor,
                    CNContactPhoneNumbersKey as CNKeyDescriptor,
                    CNContactPostalAddressesKey as CNKeyDescriptor,
                    CNContactBirthdayKey as CNKeyDescriptor
                ]
                // Create a fetch request for contacts
                let request = CNContactFetchRequest(keysToFetch: keys)
                var contactsList: [CNContact] = []
                try store.enumerateContacts(with: request) { contact, _ in
                    contactsList.append(contact)
                }
                // Apply filtering if filters are provided
                if let nameFilter = params.name, !nameFilter.isEmpty {
                    contactsList = contactsList.filter { contact in
                        let fullName = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
                        return fullName.localizedCaseInsensitiveContains(nameFilter)
                    }
                }
                if let emailFilter = params.email, !emailFilter.isEmpty {
                    contactsList = contactsList.filter { contact in
                        contact.emailAddresses.contains { email in
                            let emailString = email.value as String
                            return emailString.localizedCaseInsensitiveContains(emailFilter)
                        }
                    }
                }
                if let phoneFilter = params.phone, !phoneFilter.isEmpty {
                    contactsList = contactsList.filter { contact in
                        contact.phoneNumbers.contains { phone in
                            let phoneString = phone.value.stringValue
                            return phoneString.localizedCaseInsensitiveContains(phoneFilter)
                        }
                    }
                }
                // Check if any contacts remain after filtering
                guard !contactsList.isEmpty else {
                    throw ContactError.noContactsFound
                }
                // Map each CNContact to a Contact instance
                let mappedContacts = contactsList.map { contact -> Contact in
                    let fullName = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
                    let emails = contact.emailAddresses.map { $0.value as String }
                    let phoneNumbers = contact.phoneNumbers.map { $0.value.stringValue }
                    // Format birthday as a string
                    var birthdayString: String? = nil
                    if let birthday = contact.birthday, birthday.month != nil, birthday.day != nil {
                        birthdayString = birthday.date?.dateString
                    }
                    let addresses = contact.postalAddresses.map { postal in
                        let addr = postal.value
                        return "\(addr.street), \(addr.city), \(addr.state), \(addr.postalCode), \(addr.country)"
                    }
                    return Contact(name: fullName, emails: emails, phoneNumbers: phoneNumbers, birthday: birthdayString, address: addresses)
                }
                // Encode the contacts array to JSON
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted]
                guard let jsonData = try? encoder.encode(mappedContacts),
                      let jsonString = String(data: jsonData, encoding: .utf8) else {
                    throw ContactError.jsonEncodingFailed
                }
                return jsonString
                // Error enum
                enum ContactError: Error, LocalizedError {
                    
                    case accessDenied
                    case noContactsFound
                    case jsonEncodingFailed
                    
                    var errorDescription: String? {
                        switch self {
                            case .accessDenied:
                                return "Access to contacts was denied."
                            case .noContactsFound:
                                return "No contacts remain after filtering."
                            case .jsonEncodingFailed:
                                return "Failed to encode contacts to JSON."
                        }
                    }
                }
            }()
        }
    )
    struct FetchContactsParams: FunctionParams {
        var name: String?
        var email: String?
        var phone: String?
    }
    
    /// A function to draw a diagram
    static let drawDiagram = Function<DrawDiagramParams, String>(
        name: "draw_diagram",
        description: "Renders MermaidJS code to an SVG file and returns its path.",
        params: [
            FunctionParameter(
                label: "diagram_name",
                description: "Filename for the saved diagram.",
                datatype: .string,
                isRequired: true
            ),
            FunctionParameter(
                label: "mermaid_code",
                description: "MermaidJS code. Wrap all node text in double quotes (e.g. `A[\"Start\"] ==> B{\"Is it?\"};`).",
                datatype: .string,
                isRequired: true
            )
        ],
        run: { params in
            // Save code
            let code: String = params.mermaid_code.replacingOccurrences(
                of: "```mermaid",
                with: ""
            ).replacingOccurrences(
                of: "```",
                with: ""
            ).replacingOccurrences(
                of: "_",
                with: " "
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            MermaidRenderer.saveMermaidCode(code: code)
            // Init renderer
            let renderer = MermaidRenderer()
            // Render
            do {
                try await renderer.render(
                    attemptsRemaining: 0
                )
            } catch {
                throw DrawDiagramError.renderingFailed(error.localizedDescription)
            }
            // Move diagram
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
            // Check if date can be extracted
            let dateStr = dateFormatter.string(from: Date.now)
            let name: String = params.diagram_name.dropSuffixIfPresent(
                ".svg"
            )
            let newUrl: URL = Settings
                .containerUrl
                .appendingPathComponent("Generated Images")
                .appendingPathComponent("\(name)-\(dateStr).svg")
            FileManager.copyItem(
                from: MermaidRenderer.previewFileUrl,
                to: newUrl
            )
            return """
The rendered diagram was saved to "\(newUrl.posixPath)".

Display it to the user using Markdown image syntax. e.g. ![](\(newUrl.path(percentEncoded: true)))
"""
            enum DrawDiagramError: Error,
                                   LocalizedError {
                
                case renderingFailed(String?)
                
                var errorDescription: String? {
                    switch self {
                        case .renderingFailed(let message):
                            if let message,
                               let cheatsheetURL: URL = Bundle.main.url(
                                forResource: "mermaidCheatsheet",
                                withExtension: "md"
                               ) {
                                // Get cheatsheet text
                                let cheatsheetText: String = try! String(
                                    contentsOf: cheatsheetURL,
                                    encoding: .utf8
                                )
                                return """
The diagram failed to render with the error output below:

```error_output
\(message)

Check if ALL text in nodes is correctly wrapped with double quotes.
Examples:
A["Start"] ==> B{"Is it?"};
E --> F{"Is arr[j] < arr[min_index]?"}
```

Use the MermaidJS syntax cheatsheet below.

```mermaid_syntax
\(cheatsheetText)
```
"""
                            } else {
                                return "Failed to render the diagram."
                            }
                    }
                }
            }
        }
    )
    struct DrawDiagramParams: FunctionParams {
        let diagram_name: String
        let mermaid_code: String
    }
    
    
}

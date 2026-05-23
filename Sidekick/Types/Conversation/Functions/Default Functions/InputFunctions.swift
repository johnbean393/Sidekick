//
//  InputFunctions.swift
//  Sidekick
//
//  Created by John Bean on 4/18/25.
//

import AppKit
import Foundation

public class InputFunctions {
    
    static var functions: [AnyFunctionBox] = [
        InputFunctions.getConfirmation,
        InputFunctions.getUserSelection,
        InputFunctions.getTextInput
    ]
    
    /// A ``Function`` to ask for confirmation
    static let getConfirmation = Function<GetConfirmationParams, String>(
        name: "get_confirmation",
        description: "Shows a Yes/No confirmation dialog and returns `Yes` or `No`.",
        params: [
            FunctionParameter(
                label: "title",
                description: "Dialog title.",
                datatype: .string,
                isRequired: true
            ),
            FunctionParameter(
                label: "message",
                description: "Dialog message, phrased as a yes/no question.",
                datatype: .string,
                isRequired: true
            )
        ],
        run: { params in
            let dialogResult: Bool = Dialogs.showConfirmation(
                title: params.title,
                message: params.message
            )
            return """
An confirmation dialog with the message \"\(params.message)\" was shown.

The user responded by clicking \(dialogResult ? "Yes" : "No").
"""
        }
    )
    struct GetConfirmationParams: FunctionParams {
        let title: String
        let message: String
    }
    
    /// A ``Function`` to ask for user selection
    static let getUserSelection = Function<GetUserSelectionParams, String>(
        name: "get_user_selection",
        description: "Shows a dialog with a list of options and returns the one the user picked.",
        params: [
            FunctionParameter(
                label: "title",
                description: "Dialog title.",
                datatype: .string,
                isRequired: true
            ),
            FunctionParameter(
                label: "message",
                description: "Dialog message asking the user to choose.",
                datatype: .string,
                isRequired: true
            ),
            FunctionParameter(
                label: "options",
                description: "Options to choose from.",
                datatype: .stringArray,
                isRequired: true
            )
        ],
        run: { params in
            // Check if options are blank
            guard !params.options.isEmpty else {
                throw GetSelectionError.noOptions
            }
            // Put together alert
            let alert = NSAlert()
            alert.messageText = params.title
            alert.informativeText = params.message
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            let popupButton = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 26))
            popupButton.addItems(withTitles: params.options)
            alert.accessoryView = popupButton
            // Present alert
            let response = alert.runModal()
            if response == .alertFirstButtonReturn,
               let selection = popupButton.selectedItem?.title,
               params.options.contains(selection) {
                return selection
            } else {
                throw GetSelectionError.declined
            }
            enum GetSelectionError: LocalizedError {
                case declined
                case noOptions
                var errorDescription: String? {
                    switch self {
                        case .noOptions:
                            return "The `options` parameter cannot be empty."
                        case .declined:
                            return "The user declined the request without making a selection."
                    }
                }
            }
        }
    )
    struct GetUserSelectionParams: FunctionParams {
        let title: String
        let message: String
        let options: [String]
    }
    
    /// A ``Function`` to ask for text input
    static let getTextInput = Function<GetTextInputParams, String>(
        name: "get_text_input",
        description: "Shows a dialog asking for free-form text and returns the user's response.",
        params: [
            FunctionParameter(
                label: "title",
                description: "Dialog title.",
                datatype: .string,
                isRequired: true
            ),
            FunctionParameter(
                label: "message",
                description: "Prompt shown to the user.",
                datatype: .string,
                isRequired: true
            )
        ],
        run: { params in
            // Put together alert
            let alert = NSAlert()
            alert.messageText = params.title
            alert.informativeText = params.message
            alert.alertStyle = .informational
            // Configure elements
            let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
            textField.bezelStyle = .roundedBezel
            alert.accessoryView = textField
            alert.addButton(withTitle: "Done")
            alert.addButton(withTitle: "Cancel")
            // Ask user
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                return textField.stringValue
            } else {
                throw TextInputError.declined
            }
            enum TextInputError: LocalizedError {
                case declined
                var errorDescription: String? {
                    switch self {
                        case .declined:
                            return "The user declined the request."
                    }
                }
            }
        }
    )
    struct GetTextInputParams: FunctionParams {
        let title: String
        let message: String
    }
    
}

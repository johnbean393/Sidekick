//
//  Dialogs.swift
//  Sidekick
//
//  Created by Bean John on 10/4/24.
//

import AppKit
import Foundation

@MainActor
public class Dialogs {
	
	/// Function to show an alert
	public static func showAlert(
		title: String,
		message: String? = nil
	) {
		let alert: NSAlert = NSAlert()
		alert.messageText = title
		if let message = message {
			alert.informativeText = message
		}
		alert.runModal()
	}
	
	/// Function to show a confirmation modal
	public static func showConfirmation(
		title: String,
		message: String? = nil,
		ifConfirmed: @escaping () -> Void
	) -> Bool {
		// Define alert
		let alert: NSAlert = NSAlert()
		alert.messageText = title
		if let message = message {
			alert.informativeText = message
		}
		alert.addButton(withTitle: "Yes")
		alert.addButton(withTitle: "No")
		// Run modal
		let result: Bool = alert.runModal() == .alertFirstButtonReturn
		if result {
			// If "yes"
			ifConfirmed()
		}
		return result
	}
	
	
	/// Function to show a dichotomy modal
	public static func dichotomy(
		title: String,
		message: String? = nil,
		option1: String,
		option2: String,
		ifOption1: @escaping () -> Void,
		ifOption2: @escaping () -> Void
	) -> Bool {
		// Define alert
		let alert: NSAlert = NSAlert()
		alert.messageText = title
		if let message = message {
			alert.informativeText = message
		}
		alert.addButton(withTitle: option1)
		alert.addButton(withTitle: option2)
		// Run modal
		let result: Bool = alert.runModal() == .alertFirstButtonReturn
		if result {
			ifOption1()
		} else {
			ifOption2()
		}
		return result
	}
	
}
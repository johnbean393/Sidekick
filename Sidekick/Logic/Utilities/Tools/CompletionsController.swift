//
//  CompletionsController.swift
//  Sidekick
//
//  Created by John Bean on 3/25/25.
//

import AppKit
import ApplicationServices
import AXSwift
import Carbon
import Foundation
import OSLog
import SwiftUI

public class CompletionsController: ObservableObject {
	
	/// A `Logger` object for the `Model` object
	private static let logger: Logger = .init(
		subsystem: Bundle.main.bundleIdentifier!,
		category: String(describing: Model.self)
	)
	
	/// Static constant for the global ``CompletionsController`` object
	static public let shared: CompletionsController = .init()
	
	/// The event monitors (for scroll and click events) and the event tap for keyUp
	private var monitors: [Any] = []
	private var keyEventTap: CFMachPort?
	
	/// A `String` for the completion content
	@Published var completion: String? = nil
	
	/// A `Bool` representing if typing is in progress
	private var isTyping: Bool = false
	
	/// A list of `NSPanel` to display the content
	private var panels: [NSPanel] = []
	
	/// An `Observer` for accessibility events
	private var observer: Observer?
	
	/// A `LlamaServer` object for an instance of `llama-server`
	private var server: LlamaServer? = nil
	/// An `Int` representing the port on which the server responds
	private var port: Int = 9020
	
	/// Initializes the ``CompletionsController`` object
	init() {
		// Assign variables
		self.completion = nil
		// If enabled, setup
		if Settings.useCompletions && Settings.didSetUpCompletions {
			self.setup()
		}
	}
	
	/// Function to setup completions
	public func setup() {
		// Start server
		self.server = LlamaServer(
            modelType: .completions,
            contextLength: 4096
		)
		Task { [weak self] in
			guard let self = self else { return }
			try await self.server?.startServer(
                canReachRemoteServer: false
            )
		}
		self.setupObservers()
	}
	
	deinit {
		// Stop everything
		self.stop()
	}
	
	/// Function to stop completions
	public func stop() {
		self.tearDownObservers()
		Task { [weak self] in
			guard let self = self else { return }
			await self.server?.stopServer()
		}
	}
	
	/// Awaitable shutdown used during coordinated app termination.
	///
	/// Mirrors ``stop()`` but waits for the underlying ``LlamaServer`` to
	/// fully release its child process before returning so callers (e.g.
	/// ``AppDelegate.applicationShouldTerminate``) can guarantee that no
	/// completions `llama-server` is left running once the app exits.
	public func stopAsync() async {
		self.tearDownObservers()
		await self.server?.stopServer()
		self.server = nil
	}
	
	/// Tear down all event observers and taps. Synchronous and safe to call
	/// from either ``stop()`` or the async shutdown path.
	private func tearDownObservers() {
		for monitor in self.monitors {
			NSEvent.removeMonitor(monitor)
		}
		self.monitors.removeAll()
		NSWorkspace.shared.notificationCenter.removeObserver(self)
		if let keyEventTap = self.keyEventTap {
			CFMachPortInvalidate(keyEventTap)
			CFRunLoopRemoveSource(CFRunLoopGetCurrent(),
								  CFMachPortCreateRunLoopSource(kCFAllocatorDefault, keyEventTap, 0),
								  .commonModes)
			self.keyEventTap = nil
		}
	}
	
	/// A function to type the next word in the completion
	@MainActor
	public func typeNextWord() {
		guard let completion = self.completion, !self.isTyping else {
			return
		}
		var word: String = completion
		self.isTyping = true
		ShortcutController.refreshCompletionsShortcuts(isEnabled: false)
		let passCount = completion.count(where: { $0.isASCII })
		let percent = Double(passCount) / Double(completion.count)
		if percent > 0.3 {
			let components = completion.components(separatedBy: " ")
			word = ""
			for component in components {
				if component.isEmpty {
					word += " "
					continue
				}
				word += component
				break
			}
		} else {
			if let first = completion.first {
				word = String(first)
			}
		}
		let _ = Accessibility.shared.simulateTyping(for: word)
		self.isTyping = false
	}
	
	/// A function to type the complete text
	@MainActor
	public func typeCompletion() {
		guard let completion = self.completion, !self.isTyping else {
			return
		}
		self.isTyping = true
		ShortcutController.refreshCompletionsShortcuts(isEnabled: false)
		let _ = Accessibility.shared.simulateTyping(for: completion)
		self.isTyping = false
	}
	
	/// Function to generate and display the next completion
	private func generateAndDisplayCompletion() async {
		// Exit if disabled
		guard Settings.didSetUpCompletions && Settings.useCompletions else { return }
		// Exit if is typing or if app is on exclusion list
		guard !self.isTyping else { return }
		if let currentId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
		   Settings.completionsExcludedApps.contains(currentId) {
			return
		}
		// Reset completions
		self.reset()
		// Get text
		guard let (preText, postText) = self.fetchText() else {
			return
		}
		// Check following text
		if !postText.isEmpty && !postText.hasPrefix("\n\n") {
			return
		}
		// Check preceding text
		let lengthThreshold = 5
		guard preText.count >= lengthThreshold else {
			return
		}
		// Fetch the text being edited and check length
		guard let content: String = await self.generateCompletion(
			text: preText
		) else {
			return
		}
		// If the text being typed has already changed, exit
		guard let (newPreText, _) = self.fetchText(), newPreText == preText else {
			return
		}
		self.completion = content
		// Enable shortcut
		if !self.isTyping {
			self.displayCompletion(text: content)
			await MainActor.run {
				ShortcutController.refreshCompletionsShortcuts(isEnabled: true)
			}
		}
	}
	
	/// Function to generate the completion text from the focused element.
	private func fetchText() -> (
		preText: String,
		postText: String
	)? {
		// Get text of focused field
		guard var preText = try? ActiveApplicationInspector.getFocusedElementText() else {
			return nil
		}
		// Extract part preceding text caret
		var postText: String = ""
		if let focusedElementRef = ActiveApplicationInspector.getFocusedElement() {
			let properties: [String: Any] = ActiveApplicationInspector.getAllProperties(for: focusedElementRef)
			let markedRange = properties["AXSelectedTextRange"]
			if let location = ActiveApplicationInspector.getEditingLocation(from: markedRange) {
				postText = String(
					preText.dropFirst(min(location, preText.count))
				)
				let dropCount: Int = max(preText.count - location, 0)
				preText = String(preText.dropLast(dropCount))
			} else {
				return nil
			}
		} else {
			return nil
		}
		return (preText, postText)
	}
	
	/// Function to generate a completion for focused text field's text
	private func generateCompletion(
		text: String,
        threshold: Settings.CompletionSuggestionThreshold? = nil
	) async -> String? {
		// Generate tokens
		guard let tokens = await self.server?.getCompletion(
			text: text,
			maxTokenNumber: 5
		) else {
			return nil
		}
		// Filter tokens
        let threshold: Settings.CompletionSuggestionThreshold = threshold ?? (Settings.CompletionSuggestionThreshold(
            rawValue: Settings.completionSuggestionThreshold
        ) ?? .medium)
        let thresholdOffset: Int = threshold.rawValue
        let confidenceThreshold: Double = -2.5 + Double(thresholdOffset) * 2
		let maxSpecialCharacters: Double = 0.5
		var failCount = tokens.count
		for token in tokens {
			let logprobPass = token.logprob > confidenceThreshold
			let charPass = token.token.nonSpecialCharactersPercent() > (1 - maxSpecialCharacters)
			if logprobPass && charPass {
				failCount -= 1
			} else {
				break
			}
		}
		var content: String = tokens.map({ token in token.token }).dropLast(failCount).joined()
		if content.first == " " && text.last == " " {
			content.trimPrefix(" ")
		}
		return content
	}
	
	/// Function to get the rect of the focused field.
	private func getRect() -> CGRect? {
		if let focusedElementRef = ActiveApplicationInspector.getFocusedElement() {
			let properties: [String: Any] = ActiveApplicationInspector.getAllProperties(for: focusedElementRef)
			if let axFrame = properties["AXFrame"] {
				let axFrameValue = axFrame as! AXValue
				var rect = CGRect.zero
				if AXValueGetValue(axFrameValue, .cgRect, &rect) {
					return rect
				}
			}
		}
		return nil
	}
	
	/// Function to display the generated completion in floating panels.
	private func displayCompletion(text: String) {
		guard let rect = self.getRect() else {
			print("Failed to get focused field rect")
			return
		}
		let size = rect.size
		let position = rect.origin
		let cursorBounds = CursorBounds()
		let topLeading = cursorBounds.getOrigin(xCorner: .minX, yCorner: .minY)
		let bottomTrailing = cursorBounds.getOrigin(xCorner: .maxX, yCorner: .maxY)
		guard let topLeadingOrigin = topLeading, let bottomTrailingOrigin = bottomTrailing, topLeadingOrigin.type.rawValue.contains("Caret") else {
			return
		}
		// Calculate coordinates
		let height = abs(topLeadingOrigin.NSPoint.y - bottomTrailingOrigin.NSPoint.y)
		let originY: CGFloat = {
			if topLeadingOrigin.type == .caretFallback {
				return bottomTrailingOrigin.NSPoint.y - height
			}
			return bottomTrailingOrigin.NSPoint.y
		}()
		let sameRowRect = CGRect(
			origin: NSPoint(
				x: bottomTrailingOrigin.NSPoint.x,
				y: originY
			),
			size: CGSize(
				width: (position.x + size.width) - topLeadingOrigin.NSPoint.x,
				height: height
			)
		)
		let rowRect = CGRect(
			origin: CGPoint(
				x: rect.minX,
				y: originY - height
			),
			size: CGSize(
				width: rect.width,
				height: height
			)
		)
		Task { @MainActor [weak self] in
			guard let self = self else { return }
			self.panels.forEach { panel in
				panel.close()
			}
			self.panels.removeAll()
			var textToDisplay = text
			let panelResult = self.getFloatingPanel(with: sameRowRect, text: textToDisplay)
			self.panels.append(panelResult.panel)
			textToDisplay = panelResult.leftoverText
			if !textToDisplay.isEmpty {
				let newRowPanelResult = self.getFloatingPanel(with: rowRect, text: textToDisplay)
				self.panels.append(newRowPanelResult.panel)
			}
		}
	}
	
	/// Returns a tuple with the NSPanel displaying the text that fits and any leftover text.
	func getFloatingPanel(with rect: CGRect, text: String) -> (panel: NSPanel, leftoverText: String) {
		let font = NSFont.systemFont(ofSize: rect.height * 0.8)
		let (fittingText, leftoverText) = self.fittingSubstring(for: text, in: rect, using: font)
		let panel = NSPanel(
			contentRect: rect,
			styleMask: [.nonactivatingPanel, .borderless],
			backing: .buffered,
			defer: false
		)
		panel.isFloatingPanel = true
		panel.level = .modalPanel
		panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
		panel.backgroundColor = NSColor.clear
		let textField = NSTextField(labelWithString: fittingText)
		textField.frame = panel.contentView?.bounds ?? rect
		textField.alignment = .left
		textField.font = font
		textField.textColor = NSColor(Color.primary).withAlphaComponent(0.6)
		textField.backgroundColor = .clear
		textField.autoresizingMask = [.width, .height]
		panel.contentView = textField
		panel.hasShadow = false
		panel.orderFrontRegardless()
		return (panel, leftoverText)
	}
	
	/// Function to set the AXObserver.
	@objc private func refreshObserver(note: NSNotification) {
		self.reset()
		self.refreshObserver()
	}
	
	/// Function to reset the completion.
	private func reset() {
		Task { @MainActor in
			ShortcutController.refreshCompletionsShortcuts(isEnabled: false)
		}
		self.removePanels()
	}
	
	/// Function to remove all panels.
	private func removePanels() {
		Task { @MainActor [weak self] in
			guard let self = self else { return }
			self.panels.forEach { panel in
				panel.close()
			}
			self.panels.removeAll()
		}
	}
	
	/// Function to setup event observers, including a CGEvent tap for keyUp events.
	private func setupObservers() {
		let notifications: [NSNotification.Name: Selector] = [
			NSWorkspace.didDeactivateApplicationNotification: #selector(refreshObserver(note:)),
			NSWorkspace.didLaunchApplicationNotification: #selector(refreshObserver(note:)),
			NSWorkspace.didTerminateApplicationNotification: #selector(refreshObserver(note:)),
			NSWorkspace.activeSpaceDidChangeNotification: #selector(refreshObserver(note:))
		]
		for (notification, selector) in notifications {
			NSWorkspace.shared.notificationCenter.addObserver(self,
															  selector: selector,
															  name: notification,
															  object: nil)
		}
		// Setup a CGEvent tap for keyUp events that works globally.
		let eventMask = (1 << CGEventType.keyUp.rawValue)
		let callback: CGEventTapCallBack = { (proxy, type, event, refcon) in
			guard type == CGEventType.keyUp else { return Unmanaged.passUnretained(event) }
			if let refcon = refcon {
				let controller = Unmanaged<CompletionsController>.fromOpaque(refcon).takeUnretainedValue()
				Task {
					await controller.generateAndDisplayCompletion()
				}
			}
			return Unmanaged.passUnretained(event)
		}
		
		let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
		if let tap = CGEvent.tapCreate(
			tap: .cgSessionEventTap,
			place: .headInsertEventTap,
			options: .listenOnly,
			eventsOfInterest: CGEventMask(eventMask),
			callback: callback,
			userInfo: refcon
		) {
			self.keyEventTap = tap
			let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
			CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
			CGEvent.tapEnable(tap: tap, enable: true)
		} else {
			print("Failed to create key event tap. Ensure the app is trusted for accessibility.")
		}
		
		// Global monitors for scroll and click events.
		let scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] _ in
			self?.reset()
		}
		let clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
			self?.reset()
		}
        self.monitors.append(
            contentsOf: [scrollMonitor as Any, clickMonitor as Any]
        )
	}
	
	/// Function to refresh the AXObserver.
	private func refreshObserver() {
		guard let appId = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
			print("No frontmost application")
			return
		}
		if let app = Application(forProcessID: appId) {
			self.observer = app.createObserver { [weak self] (observer, element, event, info) in
				self?.reset()
			}
			let observedEvents: [AXNotification] = [
				.focusedWindowChanged,
				.focusedUIElementChanged,
				.windowMoved
			]
			for observedEvent in observedEvents {
				try? self.observer?.addNotification(observedEvent, forElement: app)
			}
		}
	}
}

extension CompletionsController {
	
	/// Helper function to determine the maximum substring that fits in the rect while ensuring that no word is cut off.
	func fittingSubstring(for text: String, in rect: CGRect, using font: NSFont) -> (fitting: String, leftover: String) {
		func removePartialWord(from candidate: String, in fullText: String) -> String {
			if candidate.isEmpty || candidate.last!.isWhitespace {
				return candidate
			}
			if candidate.count == fullText.count {
				return candidate
			}
			if let scalar = candidate.unicodeScalars.last,
			   scalar.value >= 0x4E00 && scalar.value <= 0x9FFF {
				return candidate
			}
			let nextIndex = fullText.index(fullText.startIndex, offsetBy: candidate.count)
			if !fullText[nextIndex].isWhitespace {
				if let lastSpaceIndex = candidate.lastIndex(where: { $0.isWhitespace }) {
					return String(candidate[..<lastSpaceIndex])
				}
				return ""
			}
			return candidate
		}
		func doesFit(_ substring: String) -> Bool {
			let attrStr = NSAttributedString(string: substring, attributes: [.font: font])
			let boundingSize = CGSize(width: rect.width, height: CGFloat.greatestFiniteMagnitude)
			let boundingRect = attrStr.boundingRect(with: boundingSize, options: [.usesLineFragmentOrigin, .usesFontLeading])
			return boundingRect.height <= rect.height
		}
		let totalLength = text.count
		var low = 0
		var high = totalLength
		var bestFit = 0
		let characters = Array(text)
		while low <= high {
			let mid = (low + high) / 2
			let candidate = String(characters.prefix(mid))
			let adjusted = removePartialWord(from: candidate, in: text)
			if adjusted.isEmpty {
				low = mid + 1
				continue
			}
			if doesFit(adjusted) {
				bestFit = adjusted.count
				low = mid + 1
			} else {
				high = mid - 1
			}
		}
		let fittingStr = String(characters.prefix(bestFit))
		let leftover = bestFit < totalLength ? String(characters.suffix(totalLength - bestFit)) : ""
		return (fittingStr, leftover)
	}
	
}

extension NSAccessibility.Notification {
	var name: Notification.Name { .init(self.rawValue) }
}

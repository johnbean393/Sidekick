//
//  Settings.swift
//  Sidekick
//
//  Created by Bean John on 9/23/24.
//

import AppKit
import DefaultModels
import Foundation
import FSKit_macOS
import SwiftUI
import UniformTypeIdentifiers

public class Settings {
	
	/// Static constant for the `gguf` UniformTypeIdentifier
	static let ggufType: UTType = UTType("com.npc-pet.Chats.gguf") ?? .data
	
	/// A `String` representing the user's name
	public static var username: String {
		get {
			guard let username = UserDefaults.standard.string(
				forKey: "username"
			) else {
				print("Failed to get username, using default")
				return NSFullUserName()
			}
			return username
		}
		set {
			// Save
			UserDefaults.standard.set(newValue, forKey: "username")
		}
	}
	
	/// A `Bool` representing whether the app's setup was completed
	static var setupComplete: Bool {
		get {
			return UserDefaults.standard.bool(
				forKey: "setupComplete"
			)
		}
		set {
			UserDefaults.standard.set(newValue, forKey: "setupComplete")
		}
	}
	
	/// Static constant for the application's container directory
	static let containerUrl: URL = URL
		.applicationSupportDirectory
		.appendingPathComponent("com.pattonium.Sidekick")
	
	/// Static constant for the application's cache directory
	static var cacheUrl: URL {
		// Check existence
		let url: URL = URL
			.applicationSupportDirectory
			.appendingPathComponent("com.pattonium.Sidekick")
			.appendingPathComponent("Cache")
		if !url.fileExists {
			// Create directory if missing
			try? FileManager.default.createDirectory(
				at: url,
				withIntermediateDirectories: true
			)
		}
		return url
	}
	
	/// Static constant for the LLM directory
	static let dirUrl: URL = Settings
		.containerUrl
		.appendingPathComponent("Models")
	
	/// Computed property for the LLM's location
	static var modelUrl: URL? {
		get {
			let result: URL
			if let url = UserDefaults.standard.url(forKey: "modelUrl") {
				result = url
			} else {
				// Get default
				if let modelUrl: URL = Self.dirUrl.contents?.compactMap({
					$0
				}).filter({
					$0.pathExtension == "gguf"
				}).first {
					result = modelUrl
				} else {
					// If no model, return nil
					return nil
				}
			}
			return result
		}
		set {
			UserDefaults.standard.set(newValue, forKey: "modelUrl")
		}
	}

	/// Function to select the main local model and auto-configure vision if a projector is bundled alongside it.
	static func selectMainLocalModel(_ modelUrl: URL) {
		Self.modelUrl = modelUrl
		let visionConfiguration = Self.localVisionConfiguration(
			for: modelUrl
		)
		InferenceSettings.projectorModelUrl = visionConfiguration.projectorModelUrl
		InferenceSettings.localModelUseVision = visionConfiguration.useVision
	}

	/// Function to determine the local vision configuration for a model.
	static func localVisionConfiguration(
		for modelUrl: URL
	) -> (projectorModelUrl: URL?, useVision: Bool) {
		guard let projectorModelUrl = Self.matchingProjectorModelUrl(
			for: modelUrl
		) else {
			return (nil, false)
		}
		return (projectorModelUrl, true)
	}

	/// Function to locate a companion `mmproj` model stored next to a GGUF model.
	static func matchingProjectorModelUrl(
		for modelUrl: URL
	) -> URL? {
		let directoryUrl: URL = modelUrl.deletingLastPathComponent()
		guard let contents = try? FileManager.default.contentsOfDirectory(
			at: directoryUrl,
			includingPropertiesForKeys: nil,
			options: [.skipsHiddenFiles]
		) else {
			return nil
		}
		let projectorCandidates: [URL] = contents.filter { url in
			guard url != modelUrl else {
				return false
			}
			let isGGUF: Bool = url.pathExtension.localizedCaseInsensitiveCompare(
				"gguf"
			) == .orderedSame
			let isProjector: Bool = url.deletingPathExtension()
				.lastPathComponent
				.localizedCaseInsensitiveContains("mmproj")
			return isGGUF && isProjector
		}
		return projectorCandidates.sorted {
			$0.lastPathComponent.localizedStandardCompare(
				$1.lastPathComponent
			) == .orderedAscending
		}.first
	}
	
	/// A `Bool` representing  if an model exists for use, whether it is local or on a server
	static var hasModel: Bool {
		// Check for local model & remote model
		let hasLocalModel: Bool = Self.modelUrl?.fileExists ?? false
		let hasServerModel: Bool = InferenceSettings.serverModelSetupComplete && InferenceSettings.useServer
		return hasLocalModel || hasServerModel
	}
	
	/// A `Bool` representing whether functions are enabled
	static var useFunctions: Bool {
		get {
			// Set default
            if !UserDefaults.standard.exists(key: "useFunctions") {
                // Default to true if using server
                Self.useFunctions = InferenceSettings.useServer
            }
			return UserDefaults.standard.bool(
				forKey: "useFunctions"
			)
		}
		set {
			UserDefaults.standard.set(newValue, forKey: "useFunctions")
		}
	}
    
    /// A `Bool` representing whether sensitive and dangerous functions can run without prompting for confirmation or authentication
    static var runFunctionsWithoutApproval: Bool {
        get {
            // Default to requiring approval
            if !UserDefaults.standard.exists(key: "runFunctionsWithoutApproval") {
                Self.runFunctionsWithoutApproval = false
            }
            return UserDefaults.standard.bool(
                forKey: "runFunctionsWithoutApproval"
            )
        }
        set {
            UserDefaults.standard.set(
                newValue,
                forKey: "runFunctionsWithoutApproval"
            )
        }
    }

    /// A `Bool` representing whether completion if checked in the midst of a function call
    static var checkFunctionsCompletion: Int {
        get {
            // Default to none
            if !UserDefaults.standard.exists(key: "checkFunctionsCompletion") {
                Self.checkFunctionsCompletion = 0
            }
            return UserDefaults.standard.integer(
                forKey: "checkFunctionsCompletion"
            )
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "checkFunctionsCompletion")
        }
    }
    /// An enum for the selected send shortcut
    public enum FunctionCompletionCheckMode: Int, CaseIterable, Identifiable {
        
        public init(
            _ checkFunctionsCompletion: Int
        ) {
            // Check for mode
            for mode in Self.allCases {
                if mode.rawValue == checkFunctionsCompletion {
                    self = mode
                    return
                }
            }
            // Default to none
            self = .none
        }
        
        public var id: Int { return self.rawValue }
        
        case none = 0
        case useRegularModel = 1
        case useWorkerModel = 2
        
        var modelType: ModelType? {
            switch self {
                case .none:
                    return nil
                case .useRegularModel:
                    return .regular
                case .useWorkerModel:
                    return .worker
            }
        }
        
        var description: String {
            switch self {
                case .none:
                    return "None"
                case .useRegularModel:
                    return "Use Regular Model"
                case .useWorkerModel:
                    return "Use Worker Model"
            }
        }
        
    }
	
	/// A `Bool` representing whether the app is in debug mode
	static var isDebugMode: Bool {
		get {
			// Set default
			if !UserDefaults.standard.exists(key: "isDebugMode") {
				// Default to false
				Self.isDebugMode = false
			}
			return UserDefaults.standard.bool(
				forKey: "isDebugMode"
			)
		}
		set {
			UserDefaults.standard.set(newValue, forKey: "isDebugMode")
		}
	}
	
	/// A `Bool` representing whether the app generates conversation titles automatically
	static var generateConversationTitles: Bool {
		get {
			// Set default
			if !UserDefaults.standard.exists(key: "generateConversationTitles") {
				// Use default
				Self.generateConversationTitles = InferenceSettings.useServer && !InferenceSettings.serverWorkerModelName.isEmpty
			}
			return UserDefaults.standard.bool(
				forKey: "generateConversationTitles"
			)
		}
		set {
			UserDefaults.standard.set(newValue, forKey: "generateConversationTitles")
		}
	}
	
	/// A `String` representing the ID of the selected voice
	public static var voiceId: String {
		get {
			guard let voiceId = UserDefaults.standard.string(
				forKey: "voiceId"
			) else {
				return ""
			}
			return voiceId
		}
		set {
			// Save
			UserDefaults.standard.set(newValue, forKey: "voiceId")
		}
	}
	
	/// Computed property for whether sound effects are played
	static var playSoundEffects: Bool {
		get {
			return UserDefaults.standard.bool(
				forKey: "playSoundEffects"
			)
		}
		set {
			UserDefaults.standard.set(newValue, forKey: "playSoundEffects")
		}
	}
	
	/// Function to select a model
	@MainActor
	static func selectModel() -> Bool {
		if let modelUrls = try? FileManager.selectFile(
			dialogTitle: String(
				localized: "Select a Model"
			),
			canSelectDirectories: false,
			allowedContentTypes: [Self.ggufType],
			allowMultipleSelection: false,
			persistPermissions: true
		) {
			guard let modelUrl = modelUrls.first else {
				return false
			}
			// Set and signal success
			Self.selectMainLocalModel(modelUrl)
			// Add to model list
			ModelManager.add(modelUrl)
			return true
		} else {
			// Signal failure
			return false
		}
	}
	
	/// Function to clear user defaults (for debug uses)
	@MainActor
	static func clearUserDefaults() {
		// Show dialog
		let _ = Dialogs.showConfirmation(
			title: String(
				localized: "Are you sure you want clear all Settings? This will delete all settings and quit Sidekick."
			)
		) {
			// If "yes"
			UserDefaults.standard.dictionaryRepresentation().keys.forEach({
				UserDefaults.standard.removeObject(forKey: $0)
			})
			// Set defaults
			Settings.setDefaults()
			InferenceSettings.setDefaults()
			NSApplication.shared.terminate(nil)
		}
	}
	
	/// Computed property that determines whether the setup screen should be shown
	static var showSetup: Bool {
		// Show if setup is marked as incomplete, or model is missing
		return !Self.setupComplete || !Self.hasModel
	}
	
	/// Function to set defaults
	static func setDefaults() {
		Settings.setupComplete = false
	}
	
	/// Function to finish setup
	static func finishSetup() {
		Settings.setupComplete = true
		InferenceSettings.setDefaults()
	}
    
    /// A `Bool` representing whether `Command + Return` is used for sending messages
    static var useCommandReturn: Bool {
        get {
            // Set default
            if !UserDefaults.standard.exists(key: "useCommandReturn") {
                // Default to false
                Self.useCommandReturn = false
            }
            return UserDefaults.standard.bool(
                forKey: "useCommandReturn"
            )
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "useCommandReturn")
        }
    }
    /// An enum for the selected send shortcut
    public enum SendShortcut: String, CaseIterable {
        
        public init(_ useCommandReturn: Bool) {
            self = useCommandReturn ? .commandReturn : .`return`
        }
        
        case `return` = "Return"
        case commandReturn = "Command + Return"
        
        var label: some View {
            Group {
                switch self {
                    case .return:
                        Text("Return \(Image(systemName: "return"))")
                    case .commandReturn:
                        Text("Command \(Image(systemName: "command")) + Return \(Image(systemName: "return"))")
                }
            }
        }
        
    }
	
}

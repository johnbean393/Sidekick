//
//  GeneralSettingsView.swift
//  Sidekick
//
//  Created by Bean John on 10/14/24.
//

import MarkdownUI
import LaunchAtLogin
import SwiftUI

struct GeneralSettingsView: View {
	
	@AppStorage("username") private var username: String = NSFullUserName()
	
    @AppStorage("useCommandReturn") private var useCommandReturn: Bool = Settings.useCommandReturn
    @AppStorage("playSoundEffects") private var playSoundEffects: Bool = false
    @AppStorage("generateConversationTitles") private var generateConversationTitles: Bool = InferenceSettings.useServer && !InferenceSettings.serverWorkerModelName.isEmpty
    @AppStorage("voiceId") private var voiceId: String = ""
    
    @AppStorage("useFunctions") private var useFunctions: Bool = Settings.useFunctions
    @AppStorage("runFunctionsWithoutApproval") private var runFunctionsWithoutApproval: Bool = Settings.runFunctionsWithoutApproval
    @AppStorage("checkFunctionsCompletion") private var checkFunctionsCompletion: Int = 0

    @StateObject private var speechSynthesizer: SpeechSynthesizer = .shared
	
    var body: some View {
        Form {
            Section {
                launchAtLogin
            } header: {
                Text("General")
            }
            Section {
                usernameEditor
                sendShortcutToggle
                soundEffects
                generateConversationTitlesToggle
                voice
            } header: {
                Text("Chat")
            }
            Section {
                useFunctionsToggle
                runFunctionsWithoutApprovalToggle
                checkFunctionsCompletionPicker
            } header: {
                Text("Functions")
            }
			InlineWritingAssistantSettingsView()
		}
		.formStyle(.grouped)
		.task {
			SpeechSynthesizer.shared.fetchVoices()
		}
    }
	
	var launchAtLogin: some View {
		HStack(alignment: .center) {
			VStack(alignment: .leading) {
				Text("Launch at Login")
					.font(.title3)
					.bold()
				Text("Controls whether Sidekick launches automatically at login.")
					.font(.caption)
			}
			Spacer()
			LaunchAtLogin.Toggle()
				.labelsHidden()
		}
	}
	
	var usernameEditor: some View {
		HStack(alignment: .center) {
			VStack(alignment: .leading) {
				Text("Username")
					.font(.title3)
					.bold()
				Text("Sidekick will refer to you by this username.")
					.font(.caption)
			}
			Spacer()
			TextField("", text: $username)
				.textFieldStyle(.roundedBorder)
				.frame(width: 300)
		}
	}
	
    var sendShortcutToggle: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading) {
                Text("Send Message")
                    .font(.title3)
                    .bold()
                Text("Send a message with the selected shortcut.")
                    .font(.caption)
            }
            Spacer()
            Picker(
                selection: self.$useCommandReturn
            ) {
                Settings.SendShortcut(true).label
                    .tag(true)
                Settings.SendShortcut(false).label
                    .tag(false)
            }
        }
    }

	var soundEffects: some View {
		HStack(alignment: .center) {
			VStack(alignment: .leading) {
				Text("Play Sound Effects")
					.font(.title3)
					.bold()
				Text("Play sound effects when text generation begins and ends.")
					.font(.caption)
			}
			Spacer()
			Toggle("", isOn: $playSoundEffects)
				.toggleStyle(.switch)
		}
	}
	
	var generateConversationTitlesToggle: some View {
		HStack(alignment: .center) {
			VStack(alignment: .leading) {
				Text("Generate Conversation Titles")
					.font(.title3)
					.bold()
				Text("Automatically generate conversation titles based on the first message in each conversation.")
					.font(.caption)
			}
			Spacer()
			Toggle("", isOn: $generateConversationTitles)
				.toggleStyle(.switch)
		}
	}
	
	var useFunctionsToggle: some View {
		HStack(alignment: .center) {
			VStack(alignment: .leading) {
                HStack {
                    Text("Use Functions")
                        .font(.title3)
                        .bold()
                }
				Text("Encourage models to use functions, which are evaluated to execute actions.")
					.font(.caption)
			}
			Spacer()
            Toggle("", isOn: $useFunctions)
				.toggleStyle(.switch)
                .onChange(of: useFunctions) {
                    // Send notification to reload model with jinja
                    NotificationCenter.default.post(
                        name: Notifications.changedInferenceConfig.name,
                        object: nil
                    )
                }
		}
	}
    
    var runFunctionsWithoutApprovalToggle: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading) {
                Text("Run Functions Without Approval")
                    .font(.title3)
                    .bold()
                Text("Allow sensitive and dangerous functions to run without confirmation dialogs or password verification.")
                    .font(.caption)
            }
            Spacer()
            Toggle("", isOn: $runFunctionsWithoutApproval)
                .toggleStyle(.switch)
                .disabled(!useFunctions)
        }
    }

    var checkFunctionsCompletionPicker: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading) {
                Text("Check Functions Completion")
                    .font(.title3)
                    .bold()
                Text("Check if functions have reached the initial target. Useful for staying on task after long chains of function calls.")
                    .font(.caption)
            }
            Spacer()
            Picker(
                selection: $checkFunctionsCompletion.animation(.linear)
            ) {
                ForEach(
                    Settings.FunctionCompletionCheckMode.allCases
                ) { mode in
                    Text(mode.description)
                        .tag(mode.rawValue)
                }
            }
            .pickerStyle(.menu)
        }
    }
	
	var voice: some View {
		HStack(alignment: .center) {
			VStack(alignment: .leading) {
				Text("Voice")
					.font(.title3)
					.bold()
				Text("The voice used to read responses aloud. Download voices in [System Settings -> Accessibility](x-apple.systempreferences:com.apple.preference.universalaccess?SpeakableItems) -> Spoken Content -> System Voice -> Manage Voices.")
					.font(.caption)
			}
			Spacer()
			Picker(
				selection: self.$voiceId
			) {
				ForEach(
					speechSynthesizer.voices,
					id: \.self.identifier
				) { voice in
					Text(voice.prettyName)
						.tag(voice.identifier)
				}
			}
		}
	}
	
}

#Preview {
    GeneralSettingsView()
}

//
//  ProfileSelectionMenu.swift
//  Sidekick
//
//  Created by Bean John on 10/10/24.
//

import SwiftUI

struct ProfileSelectionMenu: View {
	
	@Environment(\.colorScheme) var colorScheme
	
	@EnvironmentObject private var profileManager: ProfileManager
	@EnvironmentObject private var conversationState: ConversationState
	
	var selectedProfile: Profile? {
		guard let selectedProfileId = conversationState.selectedProfileId else {
			return nil
		}
		return profileManager.getProfile(id: selectedProfileId)
	}
	
	var isInverted: Bool {
		guard let luminance = selectedProfile?.color.luminance else { return false }
		let forDark: Bool = (luminance > 0.5) && (colorScheme == .dark)
		let forLight: Bool = (luminance < 0.5) && (
			colorScheme == .light
		)
		return forDark || forLight
	}
	
	var inactiveProfiles: [Profile] {
		return profileManager.profiles.filter({ profile in
			profile != selectedProfile
		})
	}
	
	var createProfileTip: CreateProfilesTip = .init()
	
	var body: some View {
		Group {
			prevButton
			menu
				.popoverTip(
					createProfileTip,
					arrowEdge: .top
				) { action in
					// Open profile editor
					conversationState.isManagingProfiles.toggle()
				}
			nextButton
		}
		.if(isInverted) { view in
			view.colorInvert()
		}
	}
	
	var prevButton: some View {
		Button {
			switchToPrevProfile()
		} label: {
			Label("Previous Profile", systemImage: "chevron.backward")
		}
		.keyboardShortcut("[", modifiers: [.command])
	}
	
	var nextButton: some View {
		Button {
			switchToNextProfile()
		} label: {
			Label("Next Profile", systemImage: "chevron.forward")
		}
		.keyboardShortcut("]", modifiers: [.command])
	}
	
	var menu: some View {
		Menu {
			Group {
				selectOptions
				if !inactiveProfiles.isEmpty {
					Divider()
				}
				manageProfilesButton
			}
		} label: {
			label
		}
	}
	
	var selectOptions: some View {
		ForEach(
			inactiveProfiles
		) { profile in
			Button {
				withAnimation(.linear) {
					conversationState.selectedProfileId = profile.id
				}
			} label: {
				profile.label
			}
		}
	}
	
	var manageProfilesButton: some View {
		Button {
			conversationState.isManagingProfiles.toggle()
		} label: {
			Text("Manage Profiles")
		}
		.onChange(of: conversationState.isManagingProfiles) {
			// Show tip if needed
			if !conversationState.isManagingProfiles &&
				LengthyTasksController.shared.hasTasks {
				LengthyTasksProgressTip.hasLengthyTask = true
			}
		}
	}
	
	var label: some View {
		Group {
			if selectedProfile == nil {
				Text("Select a Profile")
					.bold()
					.padding(7)
					.padding(.horizontal, 2)
					.background {
						RoundedRectangle(cornerRadius: 8)
							.fill(Color.white)
							.opacity(0.5)
					}
			} else {
				HStack {
					Image(systemName: self.selectedProfile!.symbolName)
					Text(self.selectedProfile!.name)
						.bold()
				}
			}
		}
	}
	
	/// Function to switch to the next profile
	private func switchToNextProfile() {
		let profilesIds: [UUID] = (profileManager.profiles + profileManager.profiles).map({ $0.id })
		guard let selectedProfileId = conversationState.selectedProfileId else {
			withAnimation(.linear) {
				self.conversationState.selectedProfileId = profileManager.firstProfile?.id
			}
			return
		}
		guard let index = profilesIds.firstIndex(of: selectedProfileId) else {
			return
		}
		withAnimation(.linear) {
			self.conversationState.selectedProfileId = profilesIds[index + 1]
		}
	}
	
	/// Function to switch to the last profile
	private func switchToPrevProfile() {
		let profilesIds: [UUID] = (profileManager.profiles + profileManager.profiles).map({ $0.id })
		guard let selectedProfileId = conversationState.selectedProfileId else {
			withAnimation(.linear) {
				self.conversationState.selectedProfileId = profileManager.lastProfile?.id
			}
			return
		}
		guard let index = profilesIds.lastIndex(of: selectedProfileId) else {
			return
		}
		withAnimation(.linear) {
			self.conversationState.selectedProfileId = profilesIds[index - 1]
		}
	}
	
}

//#Preview {
//    ProfileSelectionMenu()
//}

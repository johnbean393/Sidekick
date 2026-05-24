//
//  AppState.swift
//  Sidekick
//
//  Created by Bean John on 11/5/24.
//
//  Converted from `ObservableObject` to `@Observable` as part of
//  the SwiftData migration's Phase 1 cleanup. The shared instance
//  is now injected via `.environment(AppState.shared)` and read
//  via `@Environment(AppState.self)`.
//

import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
public final class AppState {

    static let shared: AppState = AppState()

    var commandSelectedExpertId: UUID? = nil

    /// Controls presentation of the onboarding ``SetupView`` sheet from
    /// ``ContentView``. Initialized from ``Settings/showSetup`` so the
    /// usual first-run behavior is preserved, but can be toggled at any
    /// time (e.g. from the Help menu) to re-run the onboarding wizard
    /// for debugging the setup flow.
    var isShowingSetup: Bool = Settings.showSetup

    static func setCommandSelectedExpertId(_ id: UUID) {
        Self.shared.commandSelectedExpertId = id
    }

    /// Re-presents the onboarding wizard, regardless of whether setup
    /// has already been completed. Used by the Help menu's
    /// "Show Onboarding Wizard" item.
    static func showOnboardingWizard() {
        Self.shared.isShowingSetup = true
    }
}

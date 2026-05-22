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

    static func setCommandSelectedExpertId(_ id: UUID) {
        Self.shared.commandSelectedExpertId = id
    }
}

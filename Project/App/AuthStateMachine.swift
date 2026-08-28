//
//  AuthStateMachine.swift
//  LootList
//
//  Created by Ben Mackin on 8/28/26.
//

import Foundation
import os

@MainActor
final class AuthStateMachine {
    enum Event: Sendable {
        case accountChanged
        case sessionRestored
        case restoreFailed
    }

    private let defaults: UserDefaults
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "AuthStateMachine")

    private weak var appState: AppState?

    init(defaults: UserDefaults = .standard, appState: AppState? = nil) {
        self.defaults = defaults
        self.appState = appState
    }

    func attach(to appState: AppState) {
        self.appState = appState
    }

    func send(_ event: Event) async {
        await transition(event)
    }

    func transition(_ event: Event) async {
        guard let appState else { return }
        handle(event, appState: appState)
    }

    private func handle(_ event: Event, appState: AppState) {
        switch event {
        case .accountChanged:
            // Former didSet: defer discovery while a complete persisted session awaits restoreSession.
            let proposed: AppState.AuthStatus = .checkingCloudData
            let current = appState.authStatus
            guard proposed == .checkingCloudData,
                  current == .restoringSession,
                  appState.family == nil,
                  appState.currentProfile == nil,
                  hasCompletePersistedSession()
            else {
                if appState.authStatus != .checkingCloudData {
                    appState.authStatus = .checkingCloudData
                }
                return
            }
            logger.info("Deferring account-change discovery until the persisted session is restored")
            appState.authStatus = .restoringSession
        case .sessionRestored:
            // Serialized completion marker; restoreSession itself sets .authenticated.
            break
        case .restoreFailed:
            appState.authStatus = .checkingCloudData
        }
    }

    // WHY: Centralized persisted-session completeness check owned by the machine; eliminates duplicate logic in AppState.
    private func hasCompletePersistedSession() -> Bool {
        defaults.bool(forKey: "session_hasActiveSession")
            && defaults.string(forKey: "session_profileRecordName") != nil
            && defaults.string(forKey: "session_familyRecordName") != nil
            && defaults.string(forKey: "session_familyZoneName") != nil
            && defaults.string(forKey: "session_familyZoneOwnerName") != nil
    }
}

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
    private let logger = Logger(category: "AuthStateMachine")

    private weak var appState: AppState?

    init(defaults: UserDefaults = .standard, appState: AppState) {
        self.defaults = defaults
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
            // WHY defer: account flap must not interrupt an in-flight session restore.
            if appState.authStatus == .restoringSession, hasCompletePersistedSession() {
                logger.info("Deferring account-change discovery until the persisted session is restored")
                return
            }
            if appState.authStatus != .checkingCloudData {
                appState.authStatus = .checkingCloudData
            }
        case .sessionRestored:
            // Serialized completion marker; restoreSession itself sets .authenticated.
            break
        case .restoreFailed:
            appState.authStatus = .checkingCloudData
        }
    }

    private func hasCompletePersistedSession() -> Bool {
        defaults.bool(forKey: SessionKeys.hasActiveSession.rawValue)
            && defaults.string(forKey: SessionKeys.profileRecordName.rawValue) != nil
            && defaults.string(forKey: SessionKeys.familyRecordName.rawValue) != nil
            && defaults.string(forKey: SessionKeys.familyZoneName.rawValue) != nil
            && defaults.string(forKey: SessionKeys.familyZoneOwnerName.rawValue) != nil
    }
}

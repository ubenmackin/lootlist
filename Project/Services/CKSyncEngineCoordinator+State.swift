//
//  CKSyncEngineCoordinator+State.swift
//  LootList
//
//  Created by Ben Mackin on 11/17/26.
//

import CloudKit
import Foundation
import os

@MainActor
extension CKSyncEngineCoordinator {
    // MARK: - State Key Resolution

    /// Resolves stable family identifier scoping engine state.
    func stableFamilyRecordName() -> String? {
        // WHY family-first: zone names can collide across families.
        if let familyRecordName = appState?.family?.id.recordName, !familyRecordName.isEmpty {
            return familyRecordName
        }
        if let zoneName = cloudKitService.activeFamilyZoneID?.zoneName, !zoneName.isEmpty {
            return zoneName
        }
        return nil
    }

    /// Builds UserDefaults state key per family and database scope.
    func stateKey(for scope: CKDatabase.Scope) -> String? {
        guard let familyRecordName = stableFamilyRecordName() else {
            return nil
        }
        return (scope == .private)
            ? "ck_sync_engine_state.\(familyRecordName).private"
            : "ck_sync_engine_state.\(familyRecordName).shared"
    }

    // MARK: - State Serialization Persistence

    func saveState(_ serialization: CKSyncEngine.State.Serialization, for scope: CKDatabase.Scope) {
        guard let key = stateKey(for: scope) else {
            logger.info("saveState skipped: no active family identity to scope CKSyncEngine state")
            return
        }
        do {
            let data = try PropertyListEncoder().encode(serialization)
            defaults.set(data, forKey: key)
        } catch {
            logger.error("Failed to encode CKSyncEngine.State.Serialization for \(String(describing: scope)): \(error, privacy: .private)")
        }
    }

    func loadState(for scope: CKDatabase.Scope) -> CKSyncEngine.State.Serialization? {
        if let key = stateKey(for: scope), let data = defaults.data(forKey: key) {
            do {
                return try PropertyListDecoder().decode(
                    CKSyncEngine.State.Serialization.self,
                    from: data
                )
            } catch {
                logger.error(
                    "Failed to decode CKSyncEngine.State.Serialization for \(String(describing: scope)): \(error, privacy: .private)"
                )
            }
        }
        if let profileName = appState?.currentProfile?.id.recordName {
            let legacyKey = "ck_sync_engine_state.\(profileName).\(scope == .private ? "private" : "shared")"
            if let data = defaults.data(forKey: legacyKey) {
                do {
                    let decoded = try PropertyListDecoder().decode(
                        CKSyncEngine.State.Serialization.self,
                        from: data
                    )
                    if let stableKey = stateKey(for: scope) {
                        defaults.set(data, forKey: stableKey)
                    }
                    return decoded
                } catch {
                    logger.error(
                        "Failed to decode legacy profile CKSyncEngine state for \(String(describing: scope)): \(error, privacy: .private)"
                    )
                }
            }
        }
        let unscopedKey = scope == .private ? "ck_sync_engine_state_private" : "ck_sync_engine_state_shared"
        if let data = defaults.data(forKey: unscopedKey) {
            do {
                let decoded = try PropertyListDecoder().decode(
                    CKSyncEngine.State.Serialization.self,
                    from: data
                )
                if let stableKey = stateKey(for: scope) {
                    defaults.set(data, forKey: stableKey)
                }
                return decoded
            } catch {
                logger.error(
                    "Failed to decode unscoped CKSyncEngine state for \(String(describing: scope)): \(error, privacy: .private)"
                )
            }
        }
        return nil
    }

    func resetState(forAccountID explicitAccountID: String? = nil) {
        if let explicitAccountID {
            defaults.removeObject(forKey: "ck_sync_engine_state.\(explicitAccountID).private")
            defaults.removeObject(forKey: "ck_sync_engine_state.\(explicitAccountID).shared")
            defaults.removeObject(forKey: "ck_sync_engine_state_private")
            defaults.removeObject(forKey: "ck_sync_engine_state_shared")
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("cache_fresh_\(explicitAccountID)_") {
                defaults.removeObject(forKey: key)
            }
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("ck_buffer_overflow.") {
                defaults.removeObject(forKey: key)
            }
            clearEngineTrackingForReset()
            logger.info("CKSyncEngine state reset for both private and shared databases (account: \(explicitAccountID, privacy: .private))")
            return
        }

        if let stableName = stableFamilyRecordName() {
            defaults.removeObject(forKey: "ck_sync_engine_state.\(stableName).private")
            defaults.removeObject(forKey: "ck_sync_engine_state.\(stableName).shared")
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("cache_fresh_\(stableName)_") {
                defaults.removeObject(forKey: key)
            }
        }
        defaults.removeObject(forKey: "ck_sync_engine_state_private")
        defaults.removeObject(forKey: "ck_sync_engine_state_shared")
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("ck_sync_engine_state.") || key.hasPrefix("cache_fresh_") || key.hasPrefix("ck_buffer_overflow.") {
            defaults.removeObject(forKey: key)
        }

        clearEngineTrackingForReset()
        let logID = stableFamilyRecordName() ?? appState?.currentProfile?.id.recordName ?? "none"
        logger.info("CKSyncEngine state reset for both private and shared databases (account: \(logID, privacy: .private))")
    }
}

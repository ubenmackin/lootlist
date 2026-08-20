//
//  FamilyService+Settings.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation

extension FamilyService {
    // MARK: - Family Settings

    @discardableResult
    func updateFamilyName(family: Family, newName: String) async throws -> Family {
        try ActiveFamilyScopeGuard.requireActiveFamilyScope(
            family: family,
            cloudKit: cloudKit,
            appState: appState
        )
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw FamilyServiceError.persistenceFailed
        }
        let actingIsParent = appState.currentProfile?.role.isParent ?? false
        let ownerAnchorGrant: Bool = if family.creatorUserRecordName != nil {
            await isFamilyOwner(family)
        } else {
            false
        }
        guard actingIsParent || ownerAnchorGrant else {
            throw FamilyServiceError.unauthorized
        }

        var updated = family
        updated.name = trimmed

        cacheService?.upsertFamily(updated)
        appState.family = updated

        let isOwner = appState.isZoneOwner
        syncCoordinator?.enqueueSave(recordID: updated.id, isOwner: isOwner)
        return updated
    }

    @discardableResult
    func updatePayoutPolicy(family: Family, policy: PayoutPolicy) async throws -> Family {
        try Task.checkCancellation()
        try ActiveFamilyScopeGuard.requireActiveFamilyScope(
            family: family,
            cloudKit: cloudKit,
            appState: appState
        )
        let actingIsParent = appState.currentProfile?.role.isParent ?? false
        let ownerAnchorGrant: Bool = if family.creatorUserRecordName != nil {
            await isFamilyOwner(family)
        } else {
            false
        }
        guard actingIsParent || ownerAnchorGrant else {
            throw FamilyServiceError.unauthorized
        }

        try Task.checkCancellation()

        var updated = family
        updated.payoutPolicy = policy

        cacheService?.upsertFamily(updated)
        appState.family = updated

        // Re-resolve owner from authoritative CloudKit scope after AppState sync;
        // avoids using a pre-debounce stale owner when the zone switched.
        let isOwner = cloudKit.activeIsOwner
        syncCoordinator?.enqueueSave(recordID: updated.id, isOwner: isOwner)
        return updated
    }

    @discardableResult
    func updatePayoutDay(family: Family, day: PayoutDay) async throws -> Family {
        try Task.checkCancellation()
        try ActiveFamilyScopeGuard.requireActiveFamilyScope(
            family: family,
            cloudKit: cloudKit,
            appState: appState
        )
        let actingIsParent = appState.currentProfile?.role.isParent ?? false
        let ownerAnchorGrant: Bool = if family.creatorUserRecordName != nil {
            await isFamilyOwner(family)
        } else {
            false
        }
        guard actingIsParent || ownerAnchorGrant else {
            throw FamilyServiceError.unauthorized
        }

        try Task.checkCancellation()

        var updated = family
        updated.payoutDay = day

        cacheService?.upsertFamily(updated)
        appState.family = updated

        let isOwner = appState.isZoneOwner
        syncCoordinator?.enqueueSave(recordID: updated.id, isOwner: isOwner)
        return updated
    }

    @discardableResult
    func updateProfilePayoutPolicy(profile: Profile, policy: PayoutPolicy) async throws -> Profile {
        try Task.checkCancellation()
        guard let acting = appState.currentProfile, acting.id == profile.id || acting.role.isParent else {
            throw FamilyServiceError.unauthorized
        }
        try ActiveFamilyScopeGuard.requireActiveFamilyScope(
            familyRecordName: profile.family.recordID.recordName,
            zoneID: profile.id.zoneID,
            appState: appState,
            cloudKit: cloudKit
        )

        try Task.checkCancellation()

        var updated = profile
        updated.payoutPolicy = policy

        cacheService?.upsertProfile(updated)
        if appState.currentProfile?.id == profile.id {
            appState.currentProfile = updated
        }

        // Re-resolve owner from authoritative CloudKit scope after AppState sync.
        let isOwner = cloudKit.activeIsOwner
        syncCoordinator?.enqueueSave(recordID: updated.id, isOwner: isOwner)
        return updated
    }

    @discardableResult
    func updateProfilePayoutDay(profile: Profile, day: PayoutDay?) async throws -> Profile {
        try Task.checkCancellation()
        guard let acting = appState.currentProfile, acting.id == profile.id || acting.role.isParent else {
            throw FamilyServiceError.unauthorized
        }
        try ActiveFamilyScopeGuard.requireActiveFamilyScope(
            familyRecordName: profile.family.recordID.recordName,
            zoneID: profile.id.zoneID,
            appState: appState,
            cloudKit: cloudKit
        )

        try Task.checkCancellation()

        var updated = profile
        updated.payoutDay = day

        cacheService?.upsertProfile(updated)
        if appState.currentProfile?.id == profile.id {
            appState.currentProfile = updated
        }

        let isOwner = appState.isZoneOwner
        syncCoordinator?.enqueueSave(recordID: updated.id, isOwner: isOwner)
        return updated
    }

    @discardableResult
    func updateProfileDisplayName(profile: Profile, newName: String) async throws -> Profile {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FamilyServiceError.persistenceFailed
        }
        guard let acting = appState.currentProfile, acting.id == profile.id || acting.role.isParent else {
            throw FamilyServiceError.unauthorized
        }
        try ActiveFamilyScopeGuard.requireActiveFamilyScope(
            familyRecordName: profile.family.recordID.recordName,
            zoneID: profile.id.zoneID,
            appState: appState,
            cloudKit: cloudKit
        )

        var updated = profile
        updated.displayName = trimmed

        cacheService?.upsertProfile(updated)
        if appState.currentProfile?.id == profile.id {
            appState.currentProfile = updated
        }

        let isOwner = appState.isZoneOwner
        syncCoordinator?.enqueueSave(recordID: updated.id, isOwner: isOwner)
        return updated
    }

    @discardableResult
    func updateProfileAvatar(profile: Profile,
                             avatarClass: AvatarClass?,
                             avatarPresetID: String?,
                             customAvatarImageData: Data?) async throws -> Profile
    {
        guard let acting = appState.currentProfile, acting.id == profile.id || acting.role.isParent else {
            throw FamilyServiceError.unauthorized
        }
        try ActiveFamilyScopeGuard.requireActiveFamilyScope(
            familyRecordName: profile.family.recordID.recordName,
            zoneID: profile.id.zoneID,
            appState: appState,
            cloudKit: cloudKit
        )

        var updated = profile
        updated.avatarClass = avatarClass
        updated.avatarPresetID = avatarPresetID
        updated.customAvatarImageData = customAvatarImageData

        cacheService?.upsertProfile(updated)
        if appState.currentProfile?.id == updated.id {
            appState.currentProfile = updated
        }

        let isOwner = appState.isZoneOwner
        syncCoordinator?.enqueueSave(recordID: updated.id, isOwner: isOwner)
        return updated
    }
}

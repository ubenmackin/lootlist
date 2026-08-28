//
//  FamilyService+Settings.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
import os

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

        await cacheService?.upsertFamily(updated)
        appState.family = updated

        // WHY: owner routing uses Family.creatorUserRecordName anchor via resolvedIsOwner, not role.
        let isOwner = resolvedIsOwner()
        let storedOwner = appState.isZoneOwner
        if isOwner != storedOwner {
            logger.warning("FamilyService.updateFamilyName isOwner corrected via creator anchor: stored=\(storedOwner) resolved=\(isOwner)")
        }
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

        await cacheService?.upsertFamily(updated)
        appState.family = updated

        // WHY: owner routing uses Family.creatorUserRecordName anchor via resolvedIsOwner, not role.
        let isOwner = resolvedIsOwner()
        let storedOwner = appState.isZoneOwner
        if isOwner != storedOwner {
            logger.warning("FamilyService.updatePayoutPolicy isOwner corrected via creator anchor: stored=\(storedOwner) resolved=\(isOwner)")
        }
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

        await cacheService?.upsertFamily(updated)
        appState.family = updated

        // WHY: owner routing uses Family.creatorUserRecordName anchor via resolvedIsOwner, not role.
        let isOwner = resolvedIsOwner()
        let storedOwner = appState.isZoneOwner
        if isOwner != storedOwner {
            logger.warning("FamilyService.updatePayoutDay isOwner corrected via creator anchor: stored=\(storedOwner) resolved=\(isOwner)")
        }
        syncCoordinator?.enqueueSave(recordID: updated.id, isOwner: isOwner)
        return updated
    }

    @discardableResult
    func updateProfilePayoutPolicy(profileCache: ProfileCache, policy: PayoutPolicy?) async throws -> Profile {
        guard let zoneID = appState.familyZoneID else { throw FamilyServiceError.unauthorized }
        return try await updateProfilePayoutPolicy(profile: profileCache.toProfile(zoneID: zoneID), policy: policy)
    }

    @discardableResult
    func updateProfilePayoutPolicy(profile: Profile, policy: PayoutPolicy?) async throws -> Profile {
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

        await cacheService?.upsertProfile(updated)
        if appState.currentProfile?.id == profile.id {
            appState.currentProfile = updated
        }

        // WHY: owner routing uses Family.creatorUserRecordName anchor via resolvedIsOwner, not role.
        let isOwner = resolvedIsOwner()
        let storedOwner = appState.isZoneOwner
        if isOwner != storedOwner {
            logger.warning("FamilyService.updateProfilePayoutPolicy isOwner corrected via creator anchor: stored=\(storedOwner) resolved=\(isOwner)")
        }
        syncCoordinator?.enqueueSave(recordID: updated.id, isOwner: isOwner)
        return updated
    }

    @discardableResult
    func updateProfilePayoutDay(profileCache: ProfileCache, day: PayoutDay?) async throws -> Profile {
        guard let zoneID = appState.familyZoneID else { throw FamilyServiceError.unauthorized }
        return try await updateProfilePayoutDay(profile: profileCache.toProfile(zoneID: zoneID), day: day)
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

        await cacheService?.upsertProfile(updated)
        if appState.currentProfile?.id == profile.id {
            appState.currentProfile = updated
        }

        // WHY: owner routing uses Family.creatorUserRecordName anchor via resolvedIsOwner, not role.
        let isOwner = resolvedIsOwner()
        let storedOwner = appState.isZoneOwner
        if isOwner != storedOwner {
            logger.warning("FamilyService.updateProfilePayoutDay isOwner corrected via creator anchor: stored=\(storedOwner) resolved=\(isOwner)")
        }
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

        await cacheService?.upsertProfile(updated)
        if appState.currentProfile?.id == profile.id {
            appState.currentProfile = updated
        }

        // WHY: owner routing uses Family.creatorUserRecordName anchor via resolvedIsOwner, not role.
        let isOwner = resolvedIsOwner()
        let storedOwner = appState.isZoneOwner
        if isOwner != storedOwner {
            logger.warning("FamilyService.updateProfileDisplayName isOwner corrected via creator anchor: stored=\(storedOwner) resolved=\(isOwner)")
        }
        syncCoordinator?.enqueueSave(recordID: updated.id, isOwner: isOwner)
        return updated
    }

    @discardableResult
    func updateProfileAvatar(profileCache: ProfileCache,
                             avatarClass: AvatarClass?,
                             avatarPresetID: String?,
                             customAvatarImageData: Data?,
                             avatarEmoji: String? = nil) async throws -> Profile
    {
        guard let zoneID = appState.familyZoneID else { throw FamilyServiceError.unauthorized }
        return try await updateProfileAvatar(
            profile: profileCache.toProfile(zoneID: zoneID),
            avatarClass: avatarClass,
            avatarPresetID: avatarPresetID,
            customAvatarImageData: customAvatarImageData,
            avatarEmoji: avatarEmoji
        )
    }

    @discardableResult
    func updateProfileAvatar(profile: Profile,
                             avatarClass: AvatarClass?,
                             avatarPresetID: String?,
                             customAvatarImageData: Data?,
                             avatarEmoji: String? = nil) async throws -> Profile
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
        updated.avatarEmoji = avatarEmoji

        await cacheService?.upsertProfile(updated)
        if appState.currentProfile?.id == updated.id {
            appState.currentProfile = updated
        }

        // WHY: owner routing uses Family.creatorUserRecordName anchor via resolvedIsOwner, not role.
        let isOwner = resolvedIsOwner()
        let storedOwner = appState.isZoneOwner
        if isOwner != storedOwner {
            logger.warning("FamilyService.updateProfileAvatar isOwner corrected via creator anchor: stored=\(storedOwner) resolved=\(isOwner)")
        }
        syncCoordinator?.enqueueSave(recordID: updated.id, isOwner: isOwner)
        return updated
    }

    // MARK: - Savings Split (3-Jar)

    @discardableResult
    func updateSavingsSplit(profileCache: ProfileCache, spend: Int, short: Int, long: Int) async throws -> Profile {
        guard let zoneID = appState.familyZoneID else { throw FamilyServiceError.unauthorized }
        return try await updateSavingsSplit(profile: profileCache.toProfile(zoneID: zoneID), spend: spend, short: short, long: long)
    }

    /// Updates 3-jar split percentages for a hero profile, applying to future payouts.
    @discardableResult
    func updateSavingsSplit(profile: Profile, spend: Int, short: Int, long: Int) async throws -> Profile {
        // 100-sum invariant: every payout split must allocate exactly 100%.
        guard spend >= 0, short >= 0, long >= 0, spend + short + long == 100 else {
            throw FamilyServiceError.persistenceFailed
        }
        // Self-or-parent gate mirrors bucket-transfer self-ownership — a child
        // may configure their own split, parents may configure any child.
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
        updated.splitPercentSpend = spend
        updated.splitPercentShort = short
        updated.splitPercentLong = long

        await cacheService?.upsertProfile(updated)
        if appState.currentProfile?.id == updated.id {
            appState.currentProfile = updated
        }

        let isOwner = resolvedIsOwner()
        // WHY: Hero completions must ride .shared; owner check uses Family.creatorUserRecordName anchor, not role.
        // Hoisted local: Swift 6 requires explicit capture semantics for
        // self-referencing property access inside the logger interpolation.
        let storedOwner = appState.isZoneOwner
        if isOwner != storedOwner {
            logger.warning("updateSavingsSplit isOwner corrected via creator anchor: stored=\(storedOwner) resolved=\(isOwner)")
        }
        syncCoordinator?.enqueueSave(recordID: updated.id, isOwner: isOwner)
        return updated
    }

    private func resolvedIsOwner() -> Bool {
        ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState)
    }
}

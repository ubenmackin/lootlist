//
//  FamilyService+Settings.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation

extension FamilyService {
    @discardableResult
    func updatePayoutPolicy(family: Family, policy: PayoutPolicy) async throws -> Family {
        var updated = family
        updated.payoutPolicy = policy

        let name = family.id.recordName
        let snapshot = cacheService?.fetchFamily(recordName: name)
        let preMutationChangeTag = snapshot?.changeTag
        let snapshotFamily: Family? = snapshot?.toFamily(zoneID: cloudKit.resolvedZoneID)

        let registry = cacheService?.inFlightRegistry
        await registry?.register(name)

        cacheService?.upsertFamily(updated)
        appState.family = updated

        let (zoneID, db) = familyContext(for: family.id)
        do {
            let saved = try await cloudKit.save(updated, in: zoneID, using: db)
            cacheService?.upsertFamily(saved)
            appState.family = saved
            await registry?.deregister(name)
            return saved
        } catch {
            await handleSaveFailure(
                recordID: family.id,
                preMutationChangeTag: preMutationChangeTag,
                snapshot: snapshotFamily,
                fetchCurrentTag: { self.cacheService?.fetchFamily(recordName: name)?.changeTag },
                restore: { restored in
                    cacheService?.upsertFamily(restored)
                    appState.family = restored
                },
                error: error
            )
            await registry?.deregister(name)
            throw FamilyServiceError.persistenceFailed(
                "Could not update payout policy: \(error)"
            )
        }
    }

    @discardableResult
    func updatePayoutDay(family: Family, day: PayoutDay) async throws -> Family {
        var updated = family
        updated.payoutDay = day

        let name = family.id.recordName
        let snapshot = cacheService?.fetchFamily(recordName: name)
        let preMutationChangeTag = snapshot?.changeTag
        let snapshotFamily: Family? = snapshot?.toFamily(zoneID: cloudKit.resolvedZoneID)

        let registry = cacheService?.inFlightRegistry
        await registry?.register(name)

        cacheService?.upsertFamily(updated)
        appState.family = updated

        let (zoneID, db) = familyContext(for: family.id)
        do {
            let saved = try await cloudKit.save(updated, in: zoneID, using: db)
            cacheService?.upsertFamily(saved)
            appState.family = saved
            await registry?.deregister(name)
            return saved
        } catch {
            await handleSaveFailure(
                recordID: family.id,
                preMutationChangeTag: preMutationChangeTag,
                snapshot: snapshotFamily,
                fetchCurrentTag: { self.cacheService?.fetchFamily(recordName: name)?.changeTag },
                restore: { restored in
                    cacheService?.upsertFamily(restored)
                    appState.family = restored
                },
                error: error
            )
            await registry?.deregister(name)
            throw FamilyServiceError.persistenceFailed(
                "Could not update payout day: \(error)"
            )
        }
    }

    @discardableResult
    func updateProfilePayoutPolicy(profile: Profile, policy: PayoutPolicy) async throws -> Profile {
        var updated = profile
        updated.payoutPolicy = policy

        let name = profile.id.recordName
        let snapshot = cacheService?.fetchProfile(recordName: name)
        let preMutationChangeTag = snapshot?.changeTag
        let snapshotProfile: Profile? = snapshot?.toProfile(zoneID: cloudKit.resolvedZoneID)

        let registry = cacheService?.inFlightRegistry
        await registry?.register(name)

        cacheService?.upsertProfile(updated)
        if appState.currentProfile?.id == profile.id {
            appState.currentProfile = updated
        }

        let (zoneID, db) = familyContext(for: profile.family.recordID)
        do {
            let saved = try await cloudKit.save(updated, in: zoneID, using: db)
            cacheService?.upsertProfile(saved)
            if appState.currentProfile?.id == saved.id {
                appState.currentProfile = saved
            }
            await registry?.deregister(name)
            return saved
        } catch {
            await handleSaveFailure(
                recordID: profile.id,
                preMutationChangeTag: preMutationChangeTag,
                snapshot: snapshotProfile,
                fetchCurrentTag: { self.cacheService?.fetchProfile(recordName: name)?.changeTag },
                restore: { restored in
                    cacheService?.upsertProfile(restored)
                    if appState.currentProfile?.id == profile.id {
                        appState.currentProfile = restored
                    }
                },
                error: error
            )
            await registry?.deregister(name)
            throw FamilyServiceError.persistenceFailed(
                "Could not update profile payout policy: \(error)"
            )
        }
    }

    @discardableResult
    func updateProfilePayoutDay(profile: Profile, day: PayoutDay?) async throws -> Profile {
        var updated = profile
        updated.payoutDay = day

        let name = profile.id.recordName
        let snapshot = cacheService?.fetchProfile(recordName: name)
        let preMutationChangeTag = snapshot?.changeTag
        let snapshotProfile: Profile? = snapshot?.toProfile(zoneID: cloudKit.resolvedZoneID)

        let registry = cacheService?.inFlightRegistry
        await registry?.register(name)

        cacheService?.upsertProfile(updated)
        if appState.currentProfile?.id == profile.id {
            appState.currentProfile = updated
        }

        let (zoneID, db) = familyContext(for: profile.family.recordID)
        do {
            let saved = try await cloudKit.save(updated, in: zoneID, using: db)
            cacheService?.upsertProfile(saved)
            if appState.currentProfile?.id == saved.id {
                appState.currentProfile = saved
            }
            await registry?.deregister(name)
            return saved
        } catch {
            await handleSaveFailure(
                recordID: profile.id,
                preMutationChangeTag: preMutationChangeTag,
                snapshot: snapshotProfile,
                fetchCurrentTag: { self.cacheService?.fetchProfile(recordName: name)?.changeTag },
                restore: { restored in
                    cacheService?.upsertProfile(restored)
                    if appState.currentProfile?.id == profile.id {
                        appState.currentProfile = restored
                    }
                },
                error: error
            )
            await registry?.deregister(name)
            throw FamilyServiceError.persistenceFailed(
                "Could not update profile payout day: \(error)"
            )
        }
    }

    @discardableResult
    func updateProfileDisplayName(profile: Profile, newName: String) async throws -> Profile {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FamilyServiceError.persistenceFailed("Character name cannot be empty.")
        }

        var updated = profile
        updated.displayName = trimmed

        let name = profile.id.recordName
        let snapshot = cacheService?.fetchProfile(recordName: name)
        let preMutationChangeTag = snapshot?.changeTag
        let snapshotProfile: Profile? = snapshot?.toProfile(zoneID: cloudKit.resolvedZoneID)

        let registry = cacheService?.inFlightRegistry
        await registry?.register(name)

        cacheService?.upsertProfile(updated)
        if appState.currentProfile?.id == profile.id {
            appState.currentProfile = updated
        }

        let (zoneID, db) = familyContext(for: profile.family.recordID)
        do {
            let saved = try await cloudKit.save(updated, in: zoneID, using: db)
            cacheService?.upsertProfile(saved)
            if appState.currentProfile?.id == saved.id {
                appState.currentProfile = saved
            }
            await registry?.deregister(name)
            return saved
        } catch {
            await handleSaveFailure(
                recordID: profile.id,
                preMutationChangeTag: preMutationChangeTag,
                snapshot: snapshotProfile,
                fetchCurrentTag: { self.cacheService?.fetchProfile(recordName: name)?.changeTag },
                restore: { restored in
                    cacheService?.upsertProfile(restored)
                    if appState.currentProfile?.id == profile.id {
                        appState.currentProfile = restored
                    }
                },
                error: error
            )
            await registry?.deregister(name)
            throw FamilyServiceError.persistenceFailed(
                "Could not update character name: \(error)"
            )
        }
    }

    @discardableResult
    func updateProfileAvatar(profile: Profile,
                             avatarClass: AvatarClass?,
                             avatarPresetID: String?,
                             customAvatarImageData: Data?) async throws -> Profile
    {
        var updated = profile
        updated.avatarClass = avatarClass
        updated.avatarPresetID = avatarPresetID
        updated.customAvatarImageData = customAvatarImageData

        let name = profile.id.recordName
        let snapshot = cacheService?.fetchProfiles(family: profile.family.recordID.recordName)
            .first(where: { $0.recordName == name })
        let preMutationChangeTag = snapshot?.changeTag
        let snapshotProfile: Profile? = snapshot?.toProfile(zoneID: cloudKit.resolvedZoneID)

        let registry = cacheService?.inFlightRegistry
        await registry?.register(name)

        cacheService?.upsertProfile(updated)
        if appState.currentProfile?.id == updated.id {
            appState.currentProfile = updated
        }

        let (zoneID, db) = familyContext(for: profile.family.recordID)
        do {
            let saved = try await cloudKit.save(updated, in: zoneID, using: db)
            cacheService?.upsertProfile(saved)
            if appState.currentProfile?.id == saved.id {
                appState.currentProfile = saved
            }
            await registry?.deregister(name)
            return saved
        } catch {
            await handleSaveFailure(
                recordID: profile.id,
                preMutationChangeTag: preMutationChangeTag,
                snapshot: snapshotProfile,
                fetchCurrentTag: { self.cacheService?.fetchProfiles(family: profile.family.recordID.recordName)
                    .first(where: { $0.recordName == name })?.changeTag
                },
                restore: { restored in
                    cacheService?.upsertProfile(restored)
                    if appState.currentProfile?.id == profile.id {
                        appState.currentProfile = restored
                    }
                },
                error: error
            )
            await registry?.deregister(name)
            throw FamilyServiceError.persistenceFailed(
                "Could not update avatar: \(error)"
            )
        }
    }

    // MARK: - Shared Settings Rollback

    /// Shared rollback path for the optimistic-write settings mutations.
    ///
    /// The settings update methods share one optimistic skeleton: capture a
    /// pre-mutation snapshot, register the in-flight guard, upsert the
    /// optimistic value, save to CloudKit, and — on save failure — discard the
    /// optimistic write. This helper owns that discard step so the rollback
    /// bodies are not copy-pasted across the six settings methods.
    ///
    /// On save failure it:
    /// 1. Asks `ConcurrentEditDetector` whether the server record advanced
    ///    while our write was in flight.
    /// 2. For a concurrent edit: re-fetches the authoritative server record
    ///    and restores it, falling back to the pre-mutation snapshot if the
    ///    re-fetch also fails.
    /// 3. Otherwise: restores the pre-mutation snapshot and surfaces the
    ///    underlying error toast.
    ///
    /// The caller deregisters the in-flight guard and rethrows its domain
    /// error after this returns.
    private func handleSaveFailure<T: CloudKitRecord>(
        recordID: CKRecord.ID,
        preMutationChangeTag: String?,
        snapshot: T?,
        fetchCurrentTag: @escaping () -> String?,
        restore: (T) -> Void,
        error: Error
    ) async {
        let (_, db) = familyContext(for: recordID)
        let concurrentEditDetected = ConcurrentEditDetector.detectConcurrentEdit(
            preMutationChangeTag: preMutationChangeTag,
            fetchCurrent: fetchCurrentTag,
            error: error
        )

        if concurrentEditDetected {
            toastManager?.show(
                message: "Data was modified by another device. Refresh to see the latest.",
                type: .warning
            )

            if let fresh = try? await cloudKit.fetch(T.self, id: recordID, using: db) {
                restore(fresh)
            } else if let snapshot {
                restore(snapshot)
            }
        } else {
            if let snapshot {
                restore(snapshot)
            }
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            toastManager?.show(message: message, type: .error)
        }
    }
}

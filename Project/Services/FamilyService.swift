import CloudKit
import Foundation
import os

enum FamilyServiceError: Error, Equatable, Sendable {
    case invalidInviteCode

    case joinFailed(String)

    case creationFailed(String)

    /// Generic save failure for operations other than family creation
    /// (e.g. role updates, leave-family).
    case persistenceFailed(String)

    case accountUnavailable
}

@MainActor
@Observable
final class FamilyService {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "Security")

    private let cloudKit: CloudKitService

    private let appState: AppState

    init(cloudKit: CloudKitService, appState: AppState) {
        self.cloudKit = cloudKit
        self.appState = appState
    }

    // MARK: - Family Creation (Guild Master Flow)

    /// Creates a new family in the Guild Master's **private** CloudKit database.
    ///
    /// Steps:
    /// 1. Create a custom `CKRecordZone` in `privateCloudDatabase`.
    /// 2. Save the `Family` record in that zone.
    /// 3. Create a `CKShare` anchored to the `Family` record so Heroes can join.
    /// 4. Save the Guild Master's `Profile` in the same zone.
    @discardableResult
    func createFamily(name: String,
                      ownerProfile: Profile) async throws -> (family: Family, profile: Profile, shareURL: URL?)
    {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw FamilyServiceError.creationFailed("Family name cannot be empty.")
        }

        let familyID = CKRecord.ID(recordName: UUID().uuidString)
        let zoneID = CKRecordZone.ID(zoneName: familyID.recordName,
                                     ownerName: CKCurrentUserDefaultName)

        // Step 1: Create the custom zone in the private database.
        do {
            try await cloudKit.ensureZoneExists(zoneID)
        } catch {
            throw FamilyServiceError.creationFailed(
                "Could not create family zone: \(error)"
            )
        }

        var family = Family(name: name,
                            createdBy: ownerProfile.id,
                            id: familyID)

        let pvtDB = cloudKit.privateDatabase

        // Step 2: Save the Family record in the private database.
        do {
            family = try await cloudKit.save(family, in: zoneID, using: pvtDB)
        } catch {
            throw FamilyServiceError.creationFailed(
                "Could not save family record: \(error)"
            )
        }

        // Step 3: Create a CKShare for the Family record.
        var shareURL: URL?
        do {
            let targetID = CKRecord.ID(recordName: familyID.recordName, zoneID: zoneID)
            shareURL = try await cloudKit.fetchOrCreateShareURL(in: zoneID, rootRecordID: targetID)
        } catch {
            logger.error("CKShare creation failed: \(error, privacy: .private)")
        }

        // Step 4: Save the Guild Master profile in the private database.
        var owner = ownerProfile
        owner.role = .guildMaster
        owner.family = CKRecord.Reference(recordID: family.id, action: .none)
        owner.isActive = true

        let savedOwner: Profile
        do {
            savedOwner = try await cloudKit.save(owner, in: zoneID, using: pvtDB)
        } catch {
            throw FamilyServiceError.creationFailed(
                "Could not save guild master profile: \(error)"
            )
        }

        // Update AppState and CloudKitService with zone ownership info.
        appState.familyZoneID = zoneID
        appState.isZoneOwner = true
        appState.activeShareURL = shareURL
        cloudKit.activeFamilyZoneID = zoneID
        cloudKit.activeIsOwner = true
        appState.saveSession(profile: savedOwner, family: family, zoneID: zoneID, isOwner: true)

        return (family, savedOwner, shareURL)
    }

    // MARK: - Join Family (Hero Flow via CKShare Link)

    /// Joins a family by accepting a CKShare invitation.
    /// After acceptance, the family zone appears in the Hero's `sharedCloudDatabase`.
    func joinFamilyViaShare(metadata: CKShare.Metadata,
                            heroProfile: Profile) async throws -> (family: Family, profile: Profile)
    {
        // Step 1: Accept the CKShare.
        do {
            try await cloudKit.acceptShare(metadata: metadata)
        } catch {
            throw FamilyServiceError.joinFailed(
                "Could not accept share invitation: \(error)"
            )
        }

        // Step 2: Discover the shared zone.
        let sharedZones: [CKRecordZone]
        do {
            sharedZones = try await cloudKit.fetchSharedZones()
        } catch {
            throw FamilyServiceError.joinFailed(
                "Could not discover shared zones: \(error)"
            )
        }

        guard let familyZone = sharedZones.first else {
            throw FamilyServiceError.joinFailed(
                "No shared family zone found after accepting invitation."
            )
        }

        let sharedDB = cloudKit.sharedDatabase
        let zoneID = familyZone.zoneID

        // Step 3: Fetch the Family record from the shared zone directly by ID (no query index required).
        let family: Family
        let targetRecordID: CKRecord.ID
        if #available(iOS 16.0, *) {
            targetRecordID = metadata.hierarchicalRootRecordID ?? CKRecord.ID(recordName: "root")
        } else {
            targetRecordID = metadata.rootRecordID
        }
        let sharedFamilyID = CKRecord.ID(
            recordName: targetRecordID.recordName,
            zoneID: zoneID
        )

        do {
            family = try await cloudKit.fetch(Family.self, id: sharedFamilyID, using: sharedDB)
        } catch {
            throw FamilyServiceError.joinFailed(
                "Could not fetch family record in shared zone: \(error)"
            )
        }

        // Step 4: Save the Hero profile in the shared zone.
        var hero = heroProfile
        hero.role = .hero
        hero.family = CKRecord.Reference(recordID: family.id, action: .none)
        hero.isActive = true

        let savedHero: Profile
        do {
            savedHero = try await cloudKit.save(hero, in: zoneID, using: sharedDB)
        } catch {
            throw FamilyServiceError.joinFailed(
                "Could not save hero profile: \(error)"
            )
        }

        // Update AppState and CloudKitService with zone participant info.
        appState.familyZoneID = zoneID
        appState.isZoneOwner = false
        appState.activeShareURL = nil
        cloudKit.activeFamilyZoneID = zoneID
        cloudKit.activeIsOwner = false
        appState.saveSession(profile: savedHero, family: family, zoneID: zoneID, isOwner: false)

        return (family, savedHero)
    }

    // MARK: - Family Settings Updates

    @discardableResult
    func updateFamilyName(family: Family, newName: String) async throws -> Family {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw FamilyServiceError.persistenceFailed("Family name cannot be empty.")
        }

        var updated = family
        updated.name = trimmed

        let (zoneID, db) = familyContext(for: family.id)
        do {
            let saved = try await cloudKit.save(updated, in: zoneID, using: db)
            appState.family = saved
            return saved
        } catch {
            throw FamilyServiceError.persistenceFailed(
                "Could not update family name: \(error)"
            )
        }
    }

    @discardableResult
    func updatePayoutPolicy(family: Family, policy: PayoutPolicy) async throws -> Family {
        var updated = family
        updated.payoutPolicy = policy

        let (zoneID, db) = familyContext(for: family.id)
        do {
            let saved = try await cloudKit.save(updated, in: zoneID, using: db)
            appState.family = saved
            return saved
        } catch {
            throw FamilyServiceError.persistenceFailed(
                "Could not update payout policy: \(error)"
            )
        }
    }



    // MARK: - Role & Membership Management

    /// Fetches all active hero profiles belonging to the given family.
    func fetchHeroes(for family: Family) async throws -> [Profile] {
        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let predicate = NSPredicate(format: "family == %@", familyRef)
        let all = try await cloudKit.query(Profile.self, predicate: predicate)
        return all
            .filter { $0.role == .hero && $0.isActive }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func updateMemberRole(profile: Profile, newRole: UserRole) async throws {
        var updated = profile
        updated.role = newRole

        let (zoneID, db) = familyContext(for: profile.family.recordID)
        do {
            _ = try await cloudKit.save(updated, in: zoneID, using: db)
        } catch {
            throw FamilyServiceError.persistenceFailed(
                "Could not update role: \(error)"
            )
        }
    }

    func leaveFamily(profile: Profile) async throws {
        try await deactivateProfile(profile, errorMessage: "Could not leave family")
    }

    func kickMember(profile: Profile) async throws {
        try await deactivateProfile(profile, errorMessage: "Could not remove member")
    }

    // MARK: - Private Helpers

    /// Returns the CloudKit zone ID and database for the given family record ID,
    /// using the current user's zone-ownership context.
    private func familyContext(for familyID: CKRecord.ID) -> (zone: CKRecordZone.ID, db: CKDatabase) {
        let zoneID = cloudKit.resolvedZoneID  // already set with correct ownerName
        let db = cloudKit.database(isOwner: appState.isZoneOwner)
        return (zoneID, db)
    }

    private func deactivateProfile(_ profile: Profile, errorMessage: String) async throws {
        var updated = profile
        updated.isActive = false

        let (zoneID, db) = familyContext(for: profile.family.recordID)
        do {
            _ = try await cloudKit.save(updated, in: zoneID, using: db)
        } catch {
            throw FamilyServiceError.persistenceFailed("\(errorMessage): \(error)")
        }
    }

    func deleteFamilyAndReset(family: Family) async throws {
        // 1. Delete the CloudKit zone if this user owns it.
        if appState.isZoneOwner, let zoneID = appState.familyZoneID {
            try? await cloudKit.deleteZone(zoneID)
        }

        // 2. Clear CloudKit active state.
        cloudKit.activeFamilyZoneID = nil
        cloudKit.activeIsOwner = true

        // 3. Clear persisted session and reset app state to onboarding.
        appState.clearSession()
    }
}

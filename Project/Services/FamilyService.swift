import CloudKit
import Foundation

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

        let code = Self.generateInviteCode(seed: familyID.recordName)

        var family = Family(name: name,
                            createdBy: ownerProfile.id,
                            inviteCode: code,
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
            let familyRecord = family.toRecord()
            let resolvedRecord = CKRecord(
                recordType: Family.recordType,
                recordID: CKRecord.ID(recordName: familyRecord.recordID.recordName,
                                      zoneID: zoneID)
            )
            for key in familyRecord.allKeys() {
                if let value = familyRecord[key] {
                    resolvedRecord[key] = value
                }
            }

            let share = try await cloudKit.createShare(rootRecord: resolvedRecord,
                                                       in: zoneID)
            shareURL = share.url
        } catch {
            // Share creation failed, but family + zone were created successfully.
            // The Guild Master can retry sharing later from Guild Settings.
            print("Warning: CKShare creation failed: \(error)")
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

    func generateInviteCode(family: Family) -> String {
        family.inviteCode
    }

    static func generateInviteCode(seed: String) -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100_0000_01B3
        }

        var code = ""
        var remaining = hash
        for _ in 0 ..< 6 {
            let index = Int(remaining % UInt64(alphabet.count))
            code.append(alphabet[index])
            remaining /= UInt64(alphabet.count)

            if remaining == 0 {
                remaining = hash &* 0x100_0000_01B3
            }
        }
        return code
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

        // Step 3: Find the Family record in the shared zone.
        let families: [Family]
        do {
            families = try await cloudKit.query(
                Family.self,
                predicate: NSPredicate(value: true),
                in: zoneID,
                using: sharedDB
            )
        } catch {
            throw FamilyServiceError.joinFailed(
                "Could not find family in shared zone: \(error)"
            )
        }

        guard let family = families.first else {
            throw FamilyServiceError.joinFailed(
                "No family record found in shared zone."
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

    // MARK: - Join Family (Hero Flow via Invite Code)

    /// Joins a family using a 6-character invite code.
    /// This searches the **public** or discovers via shared zones.
    /// For invite-code based joining, the parent must have already shared the zone,
    /// and the hero must have accepted the share link first.
    @discardableResult
    func joinFamily(code: String,
                    heroProfile: Profile) async throws -> (family: Family, profile: Profile)
    {
        let normalized = code
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()

        guard !normalized.isEmpty else {
            throw FamilyServiceError.invalidInviteCode
        }

        // Look for the family in any shared zones the user has access to.
        let sharedZones: [CKRecordZone]
        do {
            sharedZones = try await cloudKit.fetchSharedZones()
        } catch {
            throw FamilyServiceError.joinFailed(
                "Could not discover shared zones: \(error)"
            )
        }

        let sharedDB = cloudKit.sharedDatabase

        // Search each shared zone for the family with the matching invite code.
        for zone in sharedZones {
            let families: [Family]
            do {
                families = try await cloudKit.query(
                    Family.self,
                    predicate: NSPredicate(format: "inviteCode == %@", normalized),
                    in: zone.zoneID,
                    using: sharedDB
                )
            } catch {
                continue
            }

            guard let family = families.first else {
                continue
            }

            // Found the family — save the hero profile.
            var hero = heroProfile
            hero.role = .hero
            hero.family = CKRecord.Reference(recordID: family.id, action: .none)
            hero.isActive = true

            let savedHero: Profile
            do {
                savedHero = try await cloudKit.save(hero, in: zone.zoneID, using: sharedDB)
            } catch {
                throw FamilyServiceError.joinFailed(
                    "Could not save hero profile: \(error)"
                )
            }

            // Update AppState and CloudKitService with zone participant info.
            appState.familyZoneID = zone.zoneID
            appState.isZoneOwner = false
            appState.activeShareURL = nil
            cloudKit.activeFamilyZoneID = zone.zoneID
            cloudKit.activeIsOwner = false
            appState.saveSession(profile: savedHero, family: family, zoneID: zone.zoneID, isOwner: false)

            return (family, savedHero)
        }

        throw FamilyServiceError.invalidInviteCode
    }

    // MARK: - Role & Membership Management

    func updateMemberRole(profile: Profile, newRole: UserRole) async throws {
        var updated = profile
        updated.role = newRole

        let zoneID = CKRecordZone.ID(zoneName: profile.family.recordID.recordName,
                                     ownerName: CKCurrentUserDefaultName)
        let db = cloudKit.database(isOwner: appState.isZoneOwner)
        do {
            _ = try await cloudKit.save(updated, in: zoneID, using: db)
        } catch {
            throw FamilyServiceError.persistenceFailed(
                "Could not update role: \(error)"
            )
        }
    }

    func leaveFamily(profile: Profile) async throws {
        var updated = profile
        updated.isActive = false

        let zoneID = CKRecordZone.ID(zoneName: profile.family.recordID.recordName,
                                     ownerName: CKCurrentUserDefaultName)
        let db = cloudKit.database(isOwner: appState.isZoneOwner)
        do {
            _ = try await cloudKit.save(updated, in: zoneID, using: db)
        } catch {
            throw FamilyServiceError.persistenceFailed(
                "Could not leave family: \(error)"
            )
        }
    }

    func kickMember(profile: Profile) async throws {
        var updated = profile
        updated.isActive = false

        let zoneID = CKRecordZone.ID(zoneName: profile.family.recordID.recordName,
                                     ownerName: CKCurrentUserDefaultName)
        let db = cloudKit.database(isOwner: appState.isZoneOwner)
        do {
            _ = try await cloudKit.save(updated, in: zoneID, using: db)
        } catch {
            throw FamilyServiceError.persistenceFailed(
                "Could not remove member: \(error)"
            )
        }
    }

    func deleteFamilyAndReset(family: Family) async throws {
        if appState.isZoneOwner, let zoneID = appState.familyZoneID {
            try? await cloudKit.deleteZone(zoneID)
        }
    }
}

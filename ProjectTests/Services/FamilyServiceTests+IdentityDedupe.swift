//
//  FamilyServiceTests+IdentityDedupe.swift
//  LootList
//
//  Created by Ben Mackin on 8/11/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

/// Hero dedupe branches exercised through `joinFamilyViaShare`:
///   1. an ACTIVE hero already in the joined zone → reuse, no save;
///   2. an INACTIVE hero already in the joined zone → reactivate + resave;
///   3. no hero yet             → brand-new profile save;
///   4. duplicate `displayName`  → must NOT mint a duplicate (dedupe keyed on
///      `iCloudUserID + family`, never `displayName`) — the regression that
///      originally orphaned profiles;
///   5. `findExistingHeroProfile` against an empty zone → nil.
/// Parent-side dedupe is covered in this file's sibling sections below.
@MainActor
struct FamilyServiceIdentityDedupeTests {
    /// The mock's fixed server-authenticated iCloud user — the identity every
    /// seeded hero must carry for the dedupe lookup to match it.
    private static let mockUserRecordName = MockCloudKitService.mockUserRecordName

    /// A `MockCloudKitService` double tailored to the hero-join flow:
    ///  - reports a configurable set of shared zones so `fetchSharedZones()`
    ///    returns the just-accepted fixture zone;
    ///  - counts + captures Profile saves so the reactivate / create branches
    ///    can assert exactly one save of the right shape;
    ///  - emulates real CloudKit's typed field matching for the
    ///    `findExistingHeroProfile` predicate. The mock stores `iCloudUserID`
    ///    as a record-name String (`Profile.toRecord()`) and the predicate
    ///    compares it to a plain String constant of the same shape, so the
    ///    shim matches the stored String directly — no reference coercion.
    ///    The stock mock's `NSPredicate.evaluate(with:)` is bypassed for this
    ///    shape because it applies Foundation key-path semantics rather than
    ///    CloudKit's per-field comparison.
    private final class JoinDedupeCloudKitService: MockCloudKitService {
        var sharedZones: [CKRecordZone] = []
        private(set) var profileSaveCount = 0
        private(set) var savedProfiles: [Profile] = []

        override func fetchSharedZones() async throws -> [CKRecordZone] {
            sharedZones
        }

        override func save<T: CloudKitRecord>(
            _ model: T,
            in zoneID: CKRecordZone.ID? = nil,
            using db: CKDatabase? = nil
        ) async throws -> T {
            if T.recordType == Profile.recordType {
                profileSaveCount += 1
                if let profile = model as? Profile {
                    savedProfiles.append(profile)
                }
            }
            return try await super.save(model, in: zoneID, using: db)
        }

        override func query<T: CloudKitRecord>(
            _: T.Type,
            predicate: NSPredicate,
            in zoneID: CKRecordZone.ID? = nil,
            sortDescriptors: [NSSortDescriptor]? = nil,
            using db: CKDatabase? = nil
        ) async throws -> [T] {
            // Only the hero-dedupe predicate (an `iCloudUserID == <record-name
            // String>` comparison against a `family == <reference>`) needs the
            // typed-constant shim; every other Profile query (e.g.
            // `refreshProfilesFromCloudKit`'s family filter) falls through to
            // the stock mock.
            if T.recordType == Profile.recordType,
               let iCloudUserID = Self.constantValue(forKey: "iCloudUserID", in: predicate) as? String,
               let familyRef = Self.constantValue(forKey: "family", in: predicate) as? CKRecord.Reference
            {
                let matching = mockRecords.values.filter { record in
                    guard record.recordType == Profile.recordType else { return false }
                    guard let stored = record["iCloudUserID"] as? String,
                          stored == iCloudUserID
                    else {
                        return false
                    }
                    guard let storedFamily = record["family"] as? CKRecord.Reference,
                          storedFamily.recordID == familyRef.recordID
                    else {
                        return false
                    }
                    return true
                }
                return try matching.map { try T(record: $0) }
            }
            return try await super.query(T.self, predicate: predicate, in: zoneID, sortDescriptors: sortDescriptors, using: db)
        }

        /// Recursively extracts the constant bound to a given key-path from a
        /// predicate tree (walking `AND`/`OR` compounds). The result is untyped
        /// because it mirrors real CloudKit field semantics: an `iCloudUserID`
        /// constant is a plain record-name String while a `family` constant is
        /// a CKRecord.Reference — callers cast to the type matching the stored
        /// field.
        private static func constantValue(forKey key: String, in predicate: NSPredicate) -> Any? {
            if let comparison = predicate as? NSComparisonPredicate,
               comparison.leftExpression.expressionType == .keyPath,
               comparison.leftExpression.keyPath == key,
               comparison.rightExpression.expressionType == .constantValue
            {
                return comparison.rightExpression.constantValue
            }
            if let compound = predicate as? NSCompoundPredicate {
                for sub in compound.subpredicates {
                    // `subpredicates` is `[Any]` — cast each element back to an
                    // `NSPredicate` before recursing.
                    guard let subPredicate = sub as? NSPredicate,
                          let value = constantValue(forKey: key, in: subPredicate)
                    else { continue }
                    return value
                }
            }
            return nil
        }
    }

    // MARK: - Fixtures

    private func makeFixture() -> ( // swiftlint:disable:this large_tuple
        zoneID: CKRecordZone.ID,
        family: Family,
        familyRef: CKRecord.Reference,
        userID: CKRecord.ID
    ) {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        // The join flow is driven with `nil` metadata (see `makeHeroProfile`'s
        // note), so `joinFamilyViaShare` falls back to the `"root"` record name
        // when locating the Family in the shared zone. Seed the family under
        // that name so the end-to-end fetch resolves.
        let familyID = CKRecord.ID(recordName: "root", zoneID: zoneID)
        let familyRef = CKRecord.Reference(recordID: familyID, action: .none)
        let family = Family(
            name: "Test Guild",
            createdBy: CKRecord.ID(recordName: "owner1", zoneID: zoneID),
            id: familyID
        )
        let userID = CKRecord.ID(recordName: Self.mockUserRecordName, zoneID: zoneID)
        return (zoneID, family, familyRef, userID)
    }

    private func makeJoinService(zoneID: CKRecordZone.ID) -> JoinDedupeCloudKitService {
        let cloudKit = JoinDedupeCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
        cloudKit.sharedZones = [CKRecordZone(zoneID: zoneID)]
        return cloudKit
    }

    private func makeService(cloudKit: MockCloudKitService) -> (familyService: FamilyService, appState: AppState) {
        let appState = AppState()
        let xpService = XPService(cloudKit: cloudKit, appState: appState)
        let questService = QuestService(cloudKit: cloudKit, xpService: xpService, appState: appState)
        let familyService = FamilyService(cloudKit: cloudKit, appState: appState, questService: questService)
        return (familyService, appState)
    }

    /// `joinFamilyViaShare` is driven with `nil` metadata in these tests because
    /// `CKShare.Metadata` cannot be directly constructed in this SDK (it must
    /// come from `CKFetchShareMetadataOperation` or a platform scene/app-delegate
    /// callback). The metadata's only field the join flow consults is
    /// `hierarchicalRootRecordID` — with `nil` metadata it falls back to the
    /// `"root"` record name, which is exactly the seeded family name below. A
    /// `nil` metadata also skips the share-accept step, which is a mock no-op
    /// anyway, so the five hero-dedupe branches are unaffected.
    private func makeHeroProfile(userID: CKRecord.ID, displayName: String) -> Profile {
        Profile(
            displayName: displayName,
            avatarClass: .knight,
            role: .hero,
            iCloudUserID: userID,
            family: CKRecord.Reference(recordID: CKRecord.ID(recordName: "pending"), action: .none)
        )
    }

    // MARK: - Branch 1: Active Hero Reuse

    @Test
    func `joinFamilyViaShare reuses active Hero Profile when one exists`() async throws {
        let fixture = makeFixture()
        let cloudKit = makeJoinService(zoneID: fixture.zoneID)
        let seededHero = Profile(
            displayName: "Existing Hero",
            role: .hero,
            iCloudUserID: fixture.userID,
            family: fixture.familyRef,
            id: CKRecord.ID(recordName: "hero1", zoneID: fixture.zoneID)
        )
        cloudKit.seedMockRecords([fixture.family, seededHero])

        let (familyService, appState) = makeService(cloudKit: cloudKit)
        // Re-onboarding session: the user's existing active hero is current.
        appState.currentProfile = seededHero

        // The joining profile carries the same iCloud identity (dedupe key).
        let heroProfile = makeHeroProfile(userID: fixture.userID, displayName: "Onboarding Hero")
        let result = try await familyService.joinFamilyViaShare(metadata: nil, heroProfile: heroProfile)

        // The returned profile is the seeded hero — not a freshly-minted UUID.
        #expect(result.profile.id.recordName == "hero1")
        // Reuse path performs no save.
        #expect(cloudKit.profileSaveCount == 0)
        // The session's current profile still points at the reused hero.
        #expect(appState.currentProfile?.id.recordName == "hero1")
    }

    // MARK: - Branch 2: Inactive Hero Reactivation

    @Test
    func `joinFamilyViaShare reactivates inactive Hero Profile when one exists`() async throws {
        let fixture = makeFixture()
        let cloudKit = makeJoinService(zoneID: fixture.zoneID)
        var seededHero = Profile(
            displayName: "Inactive Hero",
            role: .hero,
            iCloudUserID: fixture.userID,
            family: fixture.familyRef,
            id: CKRecord.ID(recordName: "hero1", zoneID: fixture.zoneID)
        )
        seededHero.isActive = false
        cloudKit.seedMockRecords([fixture.family, seededHero])

        let (familyService, _) = makeService(cloudKit: cloudKit)
        let heroProfile = makeHeroProfile(userID: fixture.userID, displayName: "Rejoining Hero")
        let result = try await familyService.joinFamilyViaShare(metadata: nil, heroProfile: heroProfile)

        // The reactivated profile is the SEEDED record (same id), not a new one.
        #expect(result.profile.id.recordName == "hero1")
        // Reactivation resaves the profile exactly once.
        #expect(cloudKit.profileSaveCount == 1)
        // The saved profile is reactivated.
        #expect(cloudKit.savedProfiles.first?.isActive == true)
        #expect(result.profile.isActive == true)
    }

    // MARK: - Branch 3: Brand-New Hero Creation

    @Test
    func `joinFamilyViaShare creates new Hero Profile when none exists`() async throws {
        let fixture = makeFixture()
        let cloudKit = makeJoinService(zoneID: fixture.zoneID)
        // No profiles seeded — the dedupe lookup finds nothing.
        cloudKit.seedMockRecords([fixture.family])

        let (familyService, _) = makeService(cloudKit: cloudKit)
        let heroProfile = makeHeroProfile(userID: fixture.userID, displayName: "Brand New Hero")
        let result = try await familyService.joinFamilyViaShare(metadata: nil, heroProfile: heroProfile)

        // The new profile carries the passed-in hero's fresh UUID.
        #expect(result.profile.id.recordName == heroProfile.id.recordName)
        // Exactly one Profile save for the brand-new hero.
        #expect(cloudKit.profileSaveCount == 1)
        #expect(cloudKit.savedProfiles.first?.displayName == "Brand New Hero")
        #expect(cloudKit.savedProfiles.first?.role == .hero)
    }

    // MARK: - Regression: Duplicate DisplayName

    @Test
    func `joinFamilyViaShare rejects duplicate displayName without creating duplicate Profile`() async throws {
        let fixture = makeFixture()
        let cloudKit = makeJoinService(zoneID: fixture.zoneID)
        let seededHero = Profile(
            displayName: "Bob",
            role: .hero,
            iCloudUserID: fixture.userID,
            family: fixture.familyRef,
            id: CKRecord.ID(recordName: "hero1", zoneID: fixture.zoneID)
        )
        cloudKit.seedMockRecords([fixture.family, seededHero])

        let (familyService, _) = makeService(cloudKit: cloudKit)
        // Same display name as the seeded hero — the dedupe must NOT key on it.
        let heroProfile = makeHeroProfile(userID: fixture.userID, displayName: "Bob")
        let result = try await familyService.joinFamilyViaShare(metadata: nil, heroProfile: heroProfile)

        // The returned profile is the seeded hero, not a displayName-minted dup.
        #expect(result.profile.id.recordName == "hero1")
        #expect(cloudKit.profileSaveCount == 0)
    }

    // MARK: - Sanity: Empty Zone

    @Test
    func `findExistingHeroProfile returns nil for empty zone`() async throws {
        let fixture = makeFixture()
        let cloudKit = makeJoinService(zoneID: fixture.zoneID)
        cloudKit.seedMockRecords([fixture.family])

        let (familyService, _) = makeService(cloudKit: cloudKit)
        let found = try await familyService.findExistingHeroProfile(
            in: fixture.zoneID,
            family: fixture.family,
            currentUserRecordID: fixture.userID
        )

        #expect(found == nil)
    }

    // MARK: - Parent Dedupe (Guild Master re-onboarding)

    /// A `MockCloudKitService` double tailored to the `createFamily` owner dedupe
    /// flow:
    ///  - reports a configurable set of private zones so `fetchPrivateZones()`
    ///    returns the just-seeded existing family's zone;
    ///  - counts `Family` saves so the reuse path can assert it never mints a
    ///    duplicate Guild Master family;
    ///  - records every zone passed to `ensureZoneExists` so the reuse path can
    ///    assert it never ensures the existing family's zone;
    ///  - counts + captures `Profile` saves so the reactivate / create branches
    ///    can assert exactly one save of the right shape (mirroring the hero
    ///    dedupe double's `profileSaveCount` / `savedProfiles`);
    ///  - optionally injects a `profileQueryError` so the resolve-profile query
    ///    fallback can be driven down the raw-error → `creationFailed` path.
    private final class ParentDedupeCloudKitService: MockCloudKitService {
        var privateZones: [CKRecordZone] = []
        var profileQueryError: Error?
        private(set) var familySaveCount = 0
        private(set) var profileSaveCount = 0
        private(set) var savedProfiles: [Profile] = []
        private(set) var ensuredPrivateZoneIDs: [CKRecordZone.ID] = []

        override func fetchPrivateZones() async throws -> [CKRecordZone] {
            privateZones
        }

        override func ensureZoneExists(_ zoneID: CKRecordZone.ID) async throws {
            ensuredPrivateZoneIDs.append(zoneID)
            try await super.ensureZoneExists(zoneID)
        }

        override func save<T: CloudKitRecord>(
            _ model: T,
            in zoneID: CKRecordZone.ID? = nil,
            using db: CKDatabase? = nil
        ) async throws -> T {
            if T.recordType == Family.recordType {
                familySaveCount += 1
            } else if T.recordType == Profile.recordType {
                profileSaveCount += 1
                if let profile = model as? Profile {
                    savedProfiles.append(profile)
                }
            }
            return try await super.save(model, in: zoneID, using: db)
        }

        override func query<T: CloudKitRecord>(
            _: T.Type,
            predicate: NSPredicate,
            in zoneID: CKRecordZone.ID? = nil,
            sortDescriptors: [NSSortDescriptor]? = nil,
            using db: CKDatabase? = nil
        ) async throws -> [T] {
            // Fail the Profile query fallback inside
            // `resolveExistingOwnerProfile` so the resolver's raw-error →
            // `creationFailed` translation can be exercised. Other query types
            // (e.g. a stray refresh) fall through to the stock mock.
            if T.recordType == Profile.recordType, let profileQueryError {
                throw profileQueryError
            }
            return try await super.query(T.self, predicate: predicate, in: zoneID, sortDescriptors: sortDescriptors, using: db)
        }
    }

    /// A `MockCloudKitService` whose identity resolution fails, driving
    /// `createFamily` down the `accountUnavailable` path.
    private final class ThrowingUserCloudKitService: MockCloudKitService {
        override func currentUserRecordID() async throws -> CKRecord.ID {
            throw CloudKitServiceError.notFound("Mock iCloud account unavailable")
        }
    }

    /// Bundles the seeded owner-side fixtures returned by
    /// `makeOwnerDedupeFixture` (a small struct instead of a 4-element tuple to
    /// satisfy the `large_tuple` rule). The `ownerProfile` is nil when the GM
    /// profile is not seeded at all (the missing-GM branch).
    private struct OwnerDedupeFixture {
        let cloudKit: ParentDedupeCloudKitService
        let zoneID: CKRecordZone.ID
        let seededFamilyRecordName: String
        let ownerProfile: Profile?
    }

    /// Configures the seeded Guild Master for `makeOwnerDedupeFixture`:
    ///   - `.active` seeds an active GM (the reuse-without-save path);
    ///   - `.inactive` seeds an inactive GM (the reactivation path);
    ///   - `.absent` seeds no GM at all (the fresh-GM-create path).
    private enum OwnerGMSeed {
        case active
        case inactive
        case absent
    }

    /// Builds an existing private custom zone seeded with an owner family (whose
    /// server-stamped creator can be controlled) plus — optionally — a Guild
    /// Master profile, and points `fetchPrivateZones` at that zone. Returns the
    /// zone plus the seeded family record name for assertions. Mirrors
    /// `AppState.discoverExistingCloudState`'s zone layout: the Family lives
    /// under the same record name as its zone.
    private func makeOwnerDedupeFixture(creatorUserRecordName: String,
                                        gmSeed: OwnerGMSeed = .active) -> OwnerDedupeFixture
    {
        let zoneID = CKRecordZone.ID(zoneName: "ExistingOwnerZone", ownerName: "Owner1")
        let familyID = CKRecord.ID(recordName: zoneID.zoneName, zoneID: zoneID)
        let ownerID = CKRecord.ID(recordName: "existing-gm", zoneID: zoneID)
        let family = Family(
            name: "Existing Guild",
            createdBy: ownerID,
            id: familyID
        )
        var ownerProfile: Profile?
        var seededRecords: [any CloudKitRecord] = [family]
        switch gmSeed {
        case .active:
            ownerProfile = Profile(
                displayName: "Existing GM",
                avatarClass: .knight,
                role: .guildMaster,
                iCloudUserID: CKRecord.ID(recordName: Self.mockUserRecordName, zoneID: zoneID),
                family: CKRecord.Reference(recordID: familyID, action: .none),
                id: ownerID
            )
            seededRecords.append(ownerProfile!)
        case .inactive:
            // `Profile.init(displayName:...:)` defaults `isActive = true`, so
            // flip it off before seeding to drive the reactivation branch.
            var gm = Profile(
                displayName: "Existing GM",
                avatarClass: .knight,
                role: .guildMaster,
                iCloudUserID: CKRecord.ID(recordName: Self.mockUserRecordName, zoneID: zoneID),
                family: CKRecord.Reference(recordID: familyID, action: .none),
                id: ownerID
            )
            gm.isActive = false
            ownerProfile = gm
            seededRecords.append(gm)
        case .absent:
            // No GM profile seeded — the family exists with no Guild Master, so
            // the resolver mints a fresh GM from the onboarding profile in the
            // EXISTING family's zone (never as a duplicate Family).
            break
        }

        let cloudKit = ParentDedupeCloudKitService()
        // The server stamp is authoritative: `creatorUserRecordName` mirrors
        // `CKRecord.creatorUserRecordID`, so it is applied via the creator
        // registry rather than authored on the model.
        cloudKit.seedMockRecords(seededRecords, creatorUserRecordName: creatorUserRecordName)
        cloudKit.privateZones = [CKRecordZone(zoneID: zoneID)]
        return OwnerDedupeFixture(
            cloudKit: cloudKit,
            zoneID: zoneID,
            seededFamilyRecordName: familyID.recordName,
            ownerProfile: ownerProfile
        )
    }

    private func makeNewOwnerProfile(zoneID: CKRecordZone.ID) -> Profile {
        Profile(
            displayName: "New GM",
            avatarClass: .knight,
            role: .guildMaster,
            iCloudUserID: CKRecord.ID(recordName: Self.mockUserRecordName, zoneID: zoneID),
            family: CKRecord.Reference(recordID: CKRecord.ID(recordName: "pending"), action: .none)
        )
    }

    // MARK: - Branch 1: Existing Owner Family Reuse

    @Test
    func `createFamily reuses existing Family when creatorUserRecordName matches me`() async throws {
        // The default `gmSeed: .active` seeds an active Guild Master, so the
        // reuse path resolves the GM via the direct point-lookup hit (Branch 1
        // — no save, no overwrite).
        let fixture = makeOwnerDedupeFixture(creatorUserRecordName: Self.mockUserRecordName)
        let (familyService, _) = makeService(cloudKit: fixture.cloudKit)
        let newOwner = makeNewOwnerProfile(zoneID: fixture.zoneID)

        let result = try await familyService.createFamily(name: "New Guild", ownerProfile: newOwner)

        // The reused family is the SEEDED record, not a freshly-minted UUID.
        #expect(result.family.id.recordName == fixture.seededFamilyRecordName)
        // The reuse path performs no `Family.save(...)` — no duplicate minted.
        #expect(fixture.cloudKit.familySaveCount == 0)
        // No `ensureZoneExists` call at all on the reuse path: the candidate
        // zone is only ensured inside the brand-new-family branch, so the
        // existing family's zone is never orphaned on re-onboarding.
        #expect(fixture.cloudKit.ensuredPrivateZoneIDs.isEmpty)
    }

    // MARK: - Branch 2: No Matching Creator → Brand-New Family

    @Test
    func `createFamily creates new Family when no creatorUserRecordName matches`() async throws {
        // The seeded family belongs to a DIFFERENT creator, so the owner dedupe
        // must not claim it — a fresh family is minted instead.
        let fixture = makeOwnerDedupeFixture(creatorUserRecordName: "different-user")
        let (familyService, _) = makeService(cloudKit: fixture.cloudKit)
        let newOwner = makeNewOwnerProfile(zoneID: fixture.zoneID)

        let result = try await familyService.createFamily(name: "New Guild", ownerProfile: newOwner)

        // A brand-new family with a fresh UUID, distinct from the seeded record.
        #expect(result.family.id.recordName != fixture.seededFamilyRecordName)
        // Exactly one Family save for the freshly-minted family.
        #expect(fixture.cloudKit.familySaveCount == 1)
    }

    // MARK: - Branch 3: Unavailable iCloud Account

    @Test
    func `createFamily throws accountUnavailable when currentUserRecordID throws`() async throws {
        let cloudKit = ThrowingUserCloudKitService()
        let (familyService, _) = makeService(cloudKit: cloudKit)
        let newOwner = makeNewOwnerProfile(zoneID: CKRecordZone.ID(zoneName: "Zone", ownerName: "Owner"))

        do {
            _ = try await familyService.createFamily(name: "New Guild", ownerProfile: newOwner)
            #expect(Bool(false), "Expected accountUnavailable error")
        } catch let error as FamilyServiceError {
            #expect(error == FamilyServiceError.accountUnavailable)
        } catch {
            #expect(Bool(false), "Unexpected error type: \(error)")
        }
    }

    // MARK: - Branch 4: Fail-Closed on Transient Per-Zone Fetch Error

    @Test
    func `createFamily is fail-closed when per-zone Family fetch errors transiently`() async throws {
        // An existing owner family is seeded, but the per-zone Family
        // point-lookup fails transiently (e.g. flaky network). The dedupe must
        // NOT swallow that error (unlike the old `try?`) and fall through to
        // the brand-new-family branch — that would mint a duplicate Family +
        // Guild Master profile for the same iCloud account on re-onboarding.
        // Instead it rethrows so `createFamily` surfaces `creationFailed`.
        let fixture = makeOwnerDedupeFixture(creatorUserRecordName: Self.mockUserRecordName)
        // The per-zone Family fetch returns a transient error, not `notFound`.
        fixture.cloudKit.fetchError = CloudKitServiceError.networkUnavailable
        let (familyService, _) = makeService(cloudKit: fixture.cloudKit)
        let newOwner = makeNewOwnerProfile(zoneID: fixture.zoneID)

        do {
            _ = try await familyService.createFamily(name: "New Guild", ownerProfile: newOwner)
            #expect(Bool(false), "Expected creationFailed error")
        } catch let error as FamilyServiceError {
            #expect(error == FamilyServiceError.creationFailed)
        } catch {
            #expect(Bool(false), "Unexpected error type: \(error)")
        }

        // Fail-closed: no duplicate family was minted for the same account.
        #expect(fixture.cloudKit.familySaveCount == 0)
    }

    // MARK: - Branch 5: Inactive Guild Master Reactivation

    @Test
    func `createFamily reactivates inactive Guild Master profile instead of failing`() async throws {
        // The seeded family is owned by the acting iCloud user, but the Guild
        // Master profile is inactive (e.g. the parent previously left their own
        // family and is now re-onboarding). Mirrors the hero Branch 2 path:
        // the family is reused, the GM profile is reactivated (no rename, no
        // role overwrite — the parent-dedupe contract preserves the existing
        // identity), and no new Family is minted.
        let fixture = makeOwnerDedupeFixture(
            creatorUserRecordName: Self.mockUserRecordName,
            gmSeed: .inactive
        )
        let (familyService, _) = makeService(cloudKit: fixture.cloudKit)
        let newOwner = makeNewOwnerProfile(zoneID: fixture.zoneID)

        let result = try await familyService.createFamily(name: "Reactivated Guild", ownerProfile: newOwner)

        // The family is the seeded record (no duplicate minted).
        #expect(result.family.id.recordName == fixture.seededFamilyRecordName)
        #expect(fixture.cloudKit.familySaveCount == 0)
        // The returned profile is the seeded GM, reactivated — same record ID
        // (no identity mint), `isActive == true` (reactivation took effect),
        // role preserved (not overwritten from the onboarding ownerProfile),
        // display name preserved (not renamed — the parent-dedupe contract is
        // stricter than the hero one).
        #expect(result.profile.id.recordName == "existing-gm")
        #expect(result.profile.isActive == true)
        #expect(result.profile.role == .guildMaster)
        #expect(result.profile.displayName == "Existing GM")
        // Exactly one Profile save: the reactivation resave of the seeded GM.
        #expect(fixture.cloudKit.profileSaveCount == 1)
        #expect(fixture.cloudKit.savedProfiles.first?.isActive == true)
        // No ensureZoneExists call on the reuse path.
        #expect(fixture.cloudKit.ensuredPrivateZoneIDs.isEmpty)
    }

    // MARK: - Branch 6: Missing Guild Master → Fresh GM in EXISTING Family Zone

    @Test
    func `createFamily mints fresh Guild Master in existing family zone when none is found`() async throws {
        // The seeded family is owned by the acting iCloud user but has NO Guild
        // Master profile at all (e.g. the profile was hard-deleted from the
        // private database). The reuse path mints a fresh GM inside the
        // EXISTING family's zone from the onboarding profile values — never as
        // a duplicate Family, preserving one-identity-per-family at the
        // family-record level.
        let fixture = makeOwnerDedupeFixture(
            creatorUserRecordName: Self.mockUserRecordName,
            gmSeed: .absent
        )
        let (familyService, _) = makeService(cloudKit: fixture.cloudKit)
        let newOwner = makeNewOwnerProfile(zoneID: fixture.zoneID)

        let result = try await familyService.createFamily(name: "Repopulated Guild", ownerProfile: newOwner)

        // The family is the seeded record (no duplicate minted).
        #expect(result.family.id.recordName == fixture.seededFamilyRecordName)
        #expect(fixture.cloudKit.familySaveCount == 0)
        // The returned profile is the freshly-minted GM with the onboarding
        // values, the canonical Guild Master role, and the reused family's
        // reference — and it lives in the EXISTING zone (no fresh zone
        // ensured).
        #expect(result.profile.displayName == newOwner.displayName)
        #expect(result.profile.role == .guildMaster)
        #expect(result.profile.isActive == true)
        #expect(result.profile.family.recordID == fixture.zoneID.zoneName.asFamilyRecordID(fixture.zoneID))
        #expect(result.profile.id.recordName == newOwner.id.recordName)
        // Exactly one Profile save: the fresh GM mint.
        #expect(fixture.cloudKit.profileSaveCount == 1)
        // No ensureZoneExists call on the reuse path — the existing zone is
        // reused, never an orphaned empty zone.
        #expect(fixture.cloudKit.ensuredPrivateZoneIDs.isEmpty)
    }

    // MARK: - Branch 7: Resolve-Profile Raw Error → creationFailed Translation

    @Test
    func `createFamily translates raw resolve-profile query error to creationFailed`() async throws {
        // The dedupe succeeds (the family is reused), but the resolver's query
        // fallback throws a raw `CloudKitServiceError.networkUnavailable` —
        // the bug pattern finding 4 called out: a transport error must NOT
        // escape `createFamily` raw. The resolver wraps it as
        // `FamilyServiceError.creationFailed`; the caller surfaces the same.
        // No duplicate Family is minted and no orphaned zone is ensured.
        let fixture = makeOwnerDedupeFixture(
            creatorUserRecordName: Self.mockUserRecordName,
            gmSeed: .absent
        )
        // Inject the raw `CloudKitServiceError` into the resolver's Profile
        // query path. The seeded fixture omits a GM profile, so the direct
        // Profile point-lookup returns `notFound` (the resolver's documented
        // fall-through condition) and execution reaches the `query` fallback
        // where this error is thrown.
        fixture.cloudKit.profileQueryError = CloudKitServiceError.networkUnavailable
        let (familyService, _) = makeService(cloudKit: fixture.cloudKit)
        let newOwner = makeNewOwnerProfile(zoneID: fixture.zoneID)

        do {
            _ = try await familyService.createFamily(name: "New Guild", ownerProfile: newOwner)
            #expect(Bool(false), "Expected creationFailed error")
        } catch let error as FamilyServiceError {
            #expect(error == FamilyServiceError.creationFailed)
        } catch {
            #expect(Bool(false), "Unexpected error type: \(error)")
        }

        // The raw `CloudKitServiceError` must NOT have escalated to a duplicate
        // Family or a fresh zone — the resolver wraps it before the caller
        // observes it, and the caller's fail-closed path means the brand-new
        // family branch is unreachable.
        #expect(fixture.cloudKit.familySaveCount == 0)
        #expect(fixture.cloudKit.ensuredPrivateZoneIDs.isEmpty)
    }
}

/// `CKRecordZone.ID.zoneName` is the record name of the family stored inside
/// that zone — the family lives under the same record name as its zone in
/// `AppState.discoverExistingCloudState`'s layout, so the seeded fixture's
/// `familyID.recordName == zoneID.zoneName`. The helper is local to the test
/// file because nothing else in the production codebase expresses this zone
/// ↔ record-name equality directly.
private extension String {
    /// Returns a `CKRecord.ID` whose record name equals the receiver, scoped to
    /// the supplied zone. Used to assert that a freshly-minted Guild Master's
    /// `family` reference points at the SEEDED family's record name (not a
    /// freshly-minted UUID).
    func asFamilyRecordID(_ zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: self, zoneID: zoneID)
    }
}

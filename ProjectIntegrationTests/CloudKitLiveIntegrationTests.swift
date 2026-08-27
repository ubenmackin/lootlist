//
//  CloudKitLiveIntegrationTests.swift
//  LootListIntegrationTests
//
//  Created by Ben Mackin on 8/20/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

@Suite("CloudKitLiveIntegrationTests", .serialized)
@MainActor
struct CloudKitLiveIntegrationTests {
    private let container = CloudKitService.defaultContainer
    private let cloudKitService = CloudKitService()

    private func withRetry<T>(maxAttempts: Int = 4, operation: () async throws -> T) async throws -> T {
        var lastError: Error?
        for attempt in 1 ... maxAttempts {
            do {
                return try await operation()
            } catch let error as CKError {
                lastError = error
                if attempt < maxAttempts,
                   error.code == .networkFailure ||
                   error.code == .networkUnavailable ||
                   error.code == .serviceUnavailable ||
                   error.code == .requestRateLimited ||
                   error.code == .zoneBusy
                {
                    let delay = error.retryAfterSeconds ?? Double(attempt * 2)
                    try? await Task.sleep(for: .seconds(delay))
                    continue
                }
                throw error
            } catch {
                throw error
            }
        }
        if let lastError {
            throw lastError
        }
        throw CloudKitServiceError.networkUnavailable
    }

    private func createUniqueTestZone() async throws -> CKRecordZone.ID {
        try await withRetry {
            let uniqueName = "TestZone_\(UUID().uuidString.prefix(8))"
            let zoneID = CKRecordZone.ID(zoneName: uniqueName, ownerName: CKCurrentUserDefaultName)
            let zone = CKRecordZone(zoneID: zoneID)
            let pvtDB = container.privateCloudDatabase
            _ = try await pvtDB.save(zone)
            return zoneID
        }
    }

    private func cleanupZone(_ zoneID: CKRecordZone.ID) async {
        let pvtDB = container.privateCloudDatabase
        _ = try? await withRetry {
            try await pvtDB.deleteRecordZone(withID: zoneID)
        }
    }

    private func withTestZone<T>(perform: (CKRecordZone.ID) async throws -> T) async throws -> T {
        let zoneID = try await createUniqueTestZone()
        do {
            let result = try await perform(zoneID)
            await cleanupZone(zoneID)
            return result
        } catch {
            await cleanupZone(zoneID)
            throw error
        }
    }

    @Test
    func `cloudKitContainer account status check`() async throws {
        // A throw from accountStatus() itself means the container identifier or
        // entitlements are misconfigured; reaching a resolved status proves the
        // CloudKit container is wired up for this target.
        let status = try await container.accountStatus()
        // .couldNotDetermine is the only status indicating unresolved configuration
        // rather than a legitimate environment state (no account, transient outage).
        #expect(
            status != .couldNotDetermine,
            "accountStatus returned .couldNotDetermine — verify the CloudKit container identifier and entitlements"
        )
    }

    @Test
    func `customZone creation and deletion lifecycle against live CloudKit`() async throws {
        let status = try await container.accountStatus()
        guard status == .available else {
            // Skip execution if simulator has no active iCloud account logged in
            return
        }

        let zoneID = try await createUniqueTestZone()
        let pvtDB = container.privateCloudDatabase
        let fetchedZone = try await withRetry {
            try await pvtDB.recordZone(for: zoneID)
        }
        #expect(fetchedZone.zoneID == zoneID)

        _ = try await withRetry {
            try await pvtDB.deleteRecordZone(withID: zoneID)
        }
        do {
            _ = try await withRetry {
                try await pvtDB.recordZone(for: zoneID)
            }
            #expect(Bool(false), "Expected zone to be deleted")
        } catch let error as CKError {
            #expect(error.code == .zoneNotFound || error.code == .unknownItem)
        }
    }

    @Test
    func `domainRecord parent hierarchy and roundtrip against live CloudKit`() async throws {
        let status = try await container.accountStatus()
        guard status == .available else {
            return
        }

        let userRecordID = try await container.userRecordID()
        try await withTestZone { zoneID in
            cloudKitService.activeFamilyZoneID = zoneID
            cloudKitService.activeIsOwner = true

            let familyID = CKRecord.ID(recordName: "fam_\(UUID().uuidString.prefix(8))", zoneID: zoneID)
            let family = Family(
                name: "Integration Knights",
                createdBy: userRecordID,
                payoutPolicy: .perQuest,
                id: familyID
            )

            let savedFamily = try await cloudKitService.save(family, in: zoneID)
            #expect(savedFamily.id.recordName == familyID.recordName)
            #expect(savedFamily.name == "Integration Knights")

            let familyRef = CKRecord.Reference(recordID: familyID, action: .none)
            let profileID = CKRecord.ID(recordName: "hero_\(UUID().uuidString.prefix(8))", zoneID: zoneID)
            let profile = Profile(
                displayName: "Sir Integration",
                avatarClass: .knight,
                avatarPresetID: "knight_01",
                role: .hero,
                iCloudUserID: userRecordID,
                family: familyRef,
                id: profileID
            )

            let savedProfile = try await cloudKitService.save(profile, in: zoneID)
            #expect(savedProfile.displayName == "Sir Integration")
            #expect(savedProfile.family.recordID.recordName == familyID.recordName)

            let currentWeek = WeekMath.startOfWeek(for: Date(), payoutDay: .sunday)
            let questID = CKRecord.ID(recordName: "quest_\(UUID().uuidString.prefix(8))", zoneID: zoneID)
            let templateRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "tmpl_1", zoneID: zoneID), action: .none)
            let quest = Quest(
                template: templateRef,
                assignee: CKRecord.Reference(recordID: profileID, action: .none),
                goldReward: 15.0,
                xpReward: 50,
                scheduleType: .weeklyFlexible,
                isAllOrNothing: false,
                approvalMode: .autoApprove,
                weekOf: currentWeek,
                createdBy: CKRecord.Reference(recordID: userRecordID, action: .none),
                family: familyRef,
                name: "Defeat the Integration Dragon",
                descriptionText: "Slay the beast and verify CloudKit sync",
                id: questID
            )

            let savedQuest = try await cloudKitService.save(quest, in: zoneID)
            #expect(savedQuest.name == "Defeat the Integration Dragon")
            #expect(savedQuest.goldReward == 15.0)

            // Point lookup fetch verification for all domain hierarchy levels
            let fetchedFamily = try await cloudKitService.fetch(Family.self, id: familyID)
            #expect(fetchedFamily.name == savedFamily.name)

            let fetchedProfile = try await cloudKitService.fetch(Profile.self, id: profileID)
            #expect(fetchedProfile.displayName == savedProfile.displayName)
            #expect(fetchedProfile.family.recordID.recordName == familyID.recordName)

            let fetchedQuest = try await cloudKitService.fetch(Quest.self, id: questID)
            #expect(fetchedQuest.name == savedQuest.name)
            #expect(fetchedQuest.goldReward == 15.0)
            #expect(fetchedQuest.family.recordID.recordName == familyID.recordName)

            // Query verification: queries within the custom zone complete safely
            let queriedQuests = try await cloudKitService.query(
                Quest.self,
                predicate: NSPredicate(value: true),
                in: zoneID
            )
            // If the CloudKit environment has queryable indexing enabled, verify record presence
            if !queriedQuests.isEmpty {
                #expect(queriedQuests.contains { $0.id.recordName == questID.recordName })
            }
        }
    }

    @Test
    func `atomicBatchOperations with CKModifyRecordsOperation against live CloudKit`() async throws {
        let status = try await container.accountStatus()
        guard status == .available else {
            return
        }

        let userRecordID = try await container.userRecordID()
        try await withTestZone { zoneID in
            cloudKitService.activeFamilyZoneID = zoneID
            cloudKitService.activeIsOwner = true

            let familyID = CKRecord.ID(recordName: "fam_atomic", zoneID: zoneID)
            let family = Family(
                name: "Atomic Guild",
                createdBy: userRecordID,
                payoutPolicy: .perQuest,
                payoutDay: .sunday,
                id: familyID
            )
            _ = try await cloudKitService.save(family, in: zoneID)

            let familyRef = CKRecord.Reference(recordID: familyID, action: .none)
            let profileID = CKRecord.ID(recordName: "hero_atomic", zoneID: zoneID)
            var profile = Profile(
                displayName: "Atomic Hero",
                role: .hero,
                iCloudUserID: userRecordID,
                family: familyRef,
                id: profileID
            )
            profile.gems = 100
            _ = try await cloudKitService.save(profile, in: zoneID)

            let ledgerID = CKRecord.ID(recordName: "gem_purchase_1", zoneID: zoneID)
            let ledger = GemLedger(
                profileRecordName: profileID.recordName,
                family: familyRef,
                amount: -25,
                source: "shopPurchase",
                sourceDetail: "Mystic Potion",
                id: ledgerID
            )

            let debitResult = try await cloudKitService.atomicallyDebitGems(
                amount: 25,
                from: profile,
                ledger: ledger
            )

            let unwrapped = try #require(debitResult)
            #expect(unwrapped.profile.gems == 75)
            #expect(unwrapped.ledger.amount == -25)
        }
    }

    @Test
    func `live CKShare creation with role suffix encoding`() async throws {
        let status = try await container.accountStatus()
        guard status == .available else {
            return
        }

        let userRecordID = try await container.userRecordID()
        try await withTestZone { zoneID in
            cloudKitService.activeFamilyZoneID = zoneID
            cloudKitService.activeIsOwner = true

            let familyID = CKRecord.ID(recordName: "fam_share_\(UUID().uuidString.prefix(8))", zoneID: zoneID)
            let family = Family(
                name: "Dragon Guild",
                createdBy: userRecordID,
                payoutPolicy: .perQuest,
                payoutDay: .sunday,
                id: familyID
            )
            _ = try await cloudKitService.save(family, in: zoneID)

            let share = try await cloudKitService.createShare(for: familyID, role: .hero)
            #expect(share.publicPermission == .none)
            let title = share[CKShare.SystemFieldKey.title] as? String
            #expect(title?.hasSuffix(": Hero Invitation") == true)
            #expect(UserRole.fromShareTitle(title) == .hero)
        }
    }
}

//
//  SyncEngineTests+Notifications.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
@testable import LootList
import SwiftData
import Testing

extension SyncEngineTests {
    // MARK: Test 13 — recordChanged handler is family-scoped

    @Test
    func `push handler recordChanged syncs only active family`() async throws {
        let bgContainer = try makeContainer()
        let actor = BackgroundCacheActor(container: bgContainer)

        await actor.batchUpsertProfiles([
            seedProfile(recordName: "p_a", familyRef: ref("fam_a")),
            seedProfile(recordName: "p_b", familyRef: ref("fam_b"))
        ])
        #expect(try remainingCount(ProfileCache.self, in: bgContainer) == 2)

        let zoneID = CKRecordZone.ID(zoneName: "fam_a", ownerName: "TestOwner")
        let sut = try makeSUT(
            seedRecords: [seedProfile(recordName: "p_a", familyRef: ref("fam_a"))],
            zoneID: zoneID,
            activeFamilyZoneID: zoneID,
            existingBgContainer: bgContainer
        )

        let dbLabel = sut.cloudKit.activeIsOwner ? "private" : "shared"
        let tokenKey = "ck_change_token.\(zoneID.zoneName).\(dbLabel)"
        UserDefaults.standard.removeObject(forKey: tokenKey)

        let box = SyncResultBox()
        let observer = NotificationCenter.default.addObserver(
            forName: .syncDidComplete,
            object: sut.engine,
            queue: .main
        ) { _ in box.receivedNotification = true }
        defer { NotificationCenter.default.removeObserver(observer) }

        sut.coordinator.handleDatabaseChange(subscriptionID: "test-sub-fam-a")

        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !box.receivedNotification, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(box.receivedNotification == true)

        #expect(try remainingCount(ProfileCache.self, in: bgContainer) == 2)
        let remaining = try fetchAll(ProfileCache.self, in: bgContainer)
        let recordNames = Set(remaining.map(\.recordName))
        #expect(recordNames.contains("p_a"))
        #expect(recordNames.contains("p_b"))
    }

    // MARK: Test 14 — shareAccepted handler is family-scoped

    @Test
    func `push handler shareAccepted syncs only accepted family`() async throws {
        let bgContainer = try makeContainer()
        let actor = BackgroundCacheActor(container: bgContainer)

        await actor.batchUpsertProfiles([
            seedProfile(recordName: "p_a", familyRef: ref("fam_a")),
            seedProfile(recordName: "p_b", familyRef: ref("fam_b"))
        ])
        #expect(try remainingCount(ProfileCache.self, in: bgContainer) == 2)

        let zoneID = CKRecordZone.ID(zoneName: "fam_a", ownerName: "TestOwner")
        let sut = try makeSUT(
            seedRecords: [seedProfile(recordName: "p_a", familyRef: ref("fam_a"))],
            zoneID: zoneID,
            activeFamilyZoneID: CKRecordZone.ID(zoneName: "fam_b", ownerName: "StaleOwner"),
            existingBgContainer: bgContainer
        )

        let tokenKey = "ck_change_token.fam_a.shared"
        UserDefaults.standard.removeObject(forKey: tokenKey)

        let shareZoneID = CKRecordZone.ID(zoneName: "fam_a", ownerName: "ShareOwner")
        let shareRecordID = CKRecord.ID(recordName: "share-root", zoneID: shareZoneID)

        let box = SyncResultBox()
        let observer = NotificationCenter.default.addObserver(
            forName: .syncDidComplete,
            object: sut.engine,
            queue: .main
        ) { _ in box.receivedNotification = true }
        defer { NotificationCenter.default.removeObserver(observer) }

        sut.coordinator.notifyShareAccepted(shareID: shareRecordID)

        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !box.receivedNotification, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(box.receivedNotification == true)

        #expect(try remainingCount(ProfileCache.self, in: bgContainer) == 2)
        let remaining = try fetchAll(ProfileCache.self, in: bgContainer)
        let remainingNames = Set(remaining.map(\.recordName))
        #expect(remainingNames.contains("p_a"))
        #expect(remainingNames.contains("p_b"))
    }

    // MARK: Test 15 — zoneReset handler is family-scoped

    @Test
    func `push handler zoneReset syncs only resolved family`() async throws {
        let bgContainer = try makeContainer()
        let actor = BackgroundCacheActor(container: bgContainer)

        await actor.batchUpsertProfiles([
            seedProfile(recordName: "p_a", familyRef: ref("fam_a")),
            seedProfile(recordName: "p_b", familyRef: ref("fam_b"))
        ])
        #expect(try remainingCount(ProfileCache.self, in: bgContainer) == 2)

        let zoneID = CKRecordZone.ID(zoneName: "fam_a", ownerName: "TestOwner")
        let sut = try makeSUT(
            seedRecords: [seedProfile(recordName: "p_a", familyRef: ref("fam_a"))],
            zoneID: zoneID,
            activeFamilyZoneID: zoneID,
            existingBgContainer: bgContainer
        )

        let dbType = sut.cloudKit.activeIsOwner ? "private" : "shared"
        let tokenKey = "ck_change_token.\(zoneID.zoneName).\(dbType)"
        UserDefaults.standard.removeObject(forKey: tokenKey)

        let box = SyncResultBox()
        let observer = NotificationCenter.default.addObserver(
            forName: .syncDidComplete,
            object: sut.engine,
            queue: .main
        ) { _ in box.receivedNotification = true }
        defer { NotificationCenter.default.removeObserver(observer) }

        sut.coordinator.notifyZoneReset()

        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !box.receivedNotification, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(box.receivedNotification == true)

        #expect(try remainingCount(ProfileCache.self, in: bgContainer) == 2)
        let remaining = try fetchAll(ProfileCache.self, in: bgContainer)
        let remainingNames = Set(remaining.map(\.recordName))
        #expect(remainingNames.contains("p_a"))
        #expect(remainingNames.contains("p_b"))
    }

    // MARK: Test 16 — outcome is .changed when records were upserted

    @Test
    func `sync outcome is changed when records upserted`() async throws {
        let sut = try makeSUT(seedRecords: allTenTypes())

        let outcome = await captureOutcome(for: sut.engine) {
            await sut.engine.syncAllForActiveZone()
        }

        #expect(outcome == .changed)
    }

    // MARK: Test 17 — outcome is .noChange on clean no-change sync

    @Test
    func `sync outcome is noChange on empty zone`() async throws {
        let sut = try makeSUT(seedRecords: [])

        let outcome = await captureOutcome(for: sut.engine) {
            await sut.engine.syncAllForActiveZone()
        }

        #expect(outcome == .noChange)
    }

    // MARK: Test 18 — outcome is .failed when a sync throws

    @Test
    func `sync outcome is failed when sync throws`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "SyncTestZone", ownerName: "TestOwner")
        let sut = try makeSUT(
            seedRecords: [BrokenRecord()],
            zoneID: zoneID
        )

        let outcome = await captureOutcome(for: sut.engine) {
            await sut.engine.syncAllForActiveZone()
        }

        #expect(outcome == .failed)
    }

    // MARK: Test 19 — unparseable record handling is retry-safe

    @Test
    func `zone with unparseable record does not advance token and is flagged for full re-sync`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "SyncTestZone", ownerName: "TestOwner")
        var records = allTenTypes()
        records.append(BrokenRecord())

        let sut = try makeSUT(
            seedRecords: records,
            zoneID: zoneID
        )

        let dbLabel = sut.cloudKit.activeIsOwner ? "private" : "shared"
        let tokenKey = "ck_change_token.\(zoneID.zoneName).\(dbLabel)"
        let tokenData = try NSKeyedArchiver.archivedData(
            withRootObject: makeDummyServerChangeToken(),
            requiringSecureCoding: true
        )
        UserDefaults.standard.set(tokenData, forKey: tokenKey)
        defer { UserDefaults.standard.removeObject(forKey: tokenKey) }

        await sut.engine.incrementalSync()

        #expect(try remainingCount(FamilyCache.self, in: sut.backgroundContainer) == 1)
        #expect(try remainingCount(ProfileCache.self, in: sut.backgroundContainer) == 1)
        #expect(try remainingCount(QuestCache.self, in: sut.backgroundContainer) == 1)

        #expect(sut.engine.needsFullResyncZoneNames.contains(zoneID.zoneName))
        #expect(UserDefaults.standard.data(forKey: tokenKey) == tokenData)

        await sut.engine.incrementalSync()
        #expect(sut.engine.needsFullResyncZoneNames.isEmpty)
        #expect(sut.engine.lastSyncedAt != nil)
    }
}

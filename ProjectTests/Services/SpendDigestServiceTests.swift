//
//  SpendDigestServiceTests.swift
//  LootList
//
//  Created by Ben Mackin on 9/5/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing
import UserNotifications

@MainActor
struct SpendDigestServiceTests {
    private func makeZoneID() -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: "digest-zone", ownerName: "TestOwner")
    }

    private func makeFamily(_ zoneID: CKRecordZone.ID) -> Family {
        Family(
            name: "Digest Guild",
            createdBy: CKRecord.ID(recordName: "parent1", zoneID: zoneID),
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )
    }

    private func makeParent(_ zoneID: CKRecordZone.ID, family: Family) -> Profile {
        Profile(
            displayName: "Digest Parent",
            role: .guildMaster,
            iCloudUserID: CKRecord.ID(recordName: "parent1", zoneID: zoneID),
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: CKRecord.ID(recordName: "parent1", zoneID: zoneID)
        )
    }

    private func makeHero(_ zoneID: CKRecordZone.ID, family: Family, name: String, record: String) -> Profile {
        let userID = CKRecord.ID(recordName: record, zoneID: zoneID)
        return Profile(
            displayName: name,
            role: .hero,
            iCloudUserID: userID,
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: userID
        )
    }

    private func makeEntry(
        _ zoneID: CKRecordZone.ID,
        hero: Profile,
        family: Family,
        record: String,
        amount: Double,
        date: Date,
        source: String = LedgerSource.manual.rawValue,
        bucketKind: String? = BucketKind.spend.rawValue,
        fromBucket: String? = nil,
        toBucket: String? = nil
    ) -> LedgerEntry {
        LedgerEntry(
            profile: CKRecord.Reference(recordID: hero.id, action: .none),
            amount: amount,
            description: record,
            date: date,
            source: source,
            bucketKind: bucketKind,
            fromBucket: fromBucket,
            toBucket: toBucket,
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: CKRecord.ID(recordName: record, zoneID: zoneID)
        )
    }

    private func digestTime() -> Date {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .hour, value: 10, to: startOfToday) ?? Date()
    }

    @Test
    func `multiple spends roll up into one daily digest`() async throws {
        let defaults = UserDefaults.ephemeral()
        let zoneID = makeZoneID()
        let cache = try CacheService(inMemory: true, defaults: defaults)
        let app = AppState(defaults: defaults)
        let family = makeFamily(zoneID)
        let parent = makeParent(zoneID, family: family)
        let maya = makeHero(zoneID, family: family, name: "Maya", record: "maya")
        let leo = makeHero(zoneID, family: family, name: "Leo", record: "leo")
        app.family = family
        app.familyZoneID = zoneID
        app.isZoneOwner = true
        app.currentProfile = parent
        await cache.upsertProfile(parent)
        await cache.upsertProfile(maya)
        await cache.upsertProfile(leo)

        let now = digestTime()
        await cache.upsertLedgerEntry(makeEntry(zoneID, hero: maya, family: family, record: "maya-spend-1", amount: -2.50, date: now.addingTimeInterval(-3600)))
        await cache.upsertLedgerEntry(makeEntry(zoneID, hero: maya, family: family, record: "maya-spend-2", amount: -2.00, date: now.addingTimeInterval(-7200)))
        await cache.upsertLedgerEntry(makeEntry(zoneID, hero: leo, family: family, record: "leo-spend-1", amount: -2.00, date: now.addingTimeInterval(-10800)))
        // Noise excluded from the rollup: goal allocation, bucket transfer, and a stale spend outside the window.
        await cache.upsertLedgerEntry(makeEntry(
            zoneID,
            hero: maya,
            family: family,
            record: "maya-goal-1",
            amount: 5.00,
            date: now.addingTimeInterval(-3600),
            source: LedgerSource.goal.rawValue,
            bucketKind: BucketKind.shortTermSave.rawValue
        ))
        await cache.upsertLedgerEntry(makeEntry(
            zoneID,
            hero: maya,
            family: family,
            record: "maya-transfer-1",
            amount: -1.00,
            date: now.addingTimeInterval(-3600),
            source: LedgerSource.transfer.rawValue,
            bucketKind: BucketKind.shortTermSave.rawValue,
            fromBucket: BucketKind.spend.rawValue,
            toBucket: BucketKind.shortTermSave.rawValue
        ))
        await cache.upsertLedgerEntry(makeEntry(zoneID, hero: maya, family: family, record: "maya-stale-1", amount: -9.00, date: now.addingTimeInterval(-25 * 3600)))

        defaults.set(true, forKey: "masterNotificationsEnabled")
        defaults.set(true, forKey: "spendDailyDigestEnabled")
        let notifications = NotificationService(cloudKit: MockCloudKitService(), appState: app, cacheService: cache, defaults: defaults)
        let digest = SpendDigestService(cacheService: cache, appState: app, notificationService: notifications, defaults: defaults)

        let summary = try #require(digest.buildDigestSummary(now: now))
        #expect(summary.contains("Maya"))
        #expect(summary.contains("Leo"))
        #expect(summary.contains(CurrencyFormatter.string(4.50)))
        #expect(summary.contains(CurrencyFormatter.string(2.00)))
        #expect(summary.contains("2 spends"))
        #expect(summary.contains("1 spend"))
        #expect(!summary.contains(CurrencyFormatter.string(9.00)))

        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        defer { UNUserNotificationCenter.current().removeAllPendingNotificationRequests() }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])

        let first = await digest.maybeDeliverDailyDigest(now: now)
        #expect(first == true)
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        let digests = pending.filter { $0.identifier.hasPrefix("\(NotificationEventType.spendDailyDigest.rawValue):") }
        #expect(digests.count == 1)
        #expect(digests.first?.content.body == summary)
        #expect(pending.filter { $0.identifier.hasPrefix("\(NotificationEventType.spendingLogged.rawValue):") }.isEmpty)

        // Idempotent: the same family-day never sends twice.
        let second = await digest.maybeDeliverDailyDigest(now: now)
        #expect(second == false)
        let pendingAfter = await UNUserNotificationCenter.current().pendingNotificationRequests()
        #expect(pendingAfter.filter { $0.identifier.hasPrefix("\(NotificationEventType.spendDailyDigest.rawValue):") }.count == 1)
    }

    @Test
    func `ingested manual spends send no immediate notifications`() async throws {
        let defaults = UserDefaults.ephemeral()
        let zoneID = makeZoneID()
        let cache = try CacheService(inMemory: true, defaults: defaults)
        let app = AppState(defaults: defaults)
        let family = makeFamily(zoneID)
        let parent = makeParent(zoneID, family: family)
        let maya = makeHero(zoneID, family: family, name: "Maya", record: "maya")
        app.family = family
        app.familyZoneID = zoneID
        app.isZoneOwner = true
        app.currentProfile = parent

        // Per-spend prefs stay enabled so the test proves the no-op, not the gate.
        defaults.set(true, forKey: "masterNotificationsEnabled")
        defaults.set(true, forKey: "spendingLoggedNotificationsEnabled")
        let notifications = NotificationService(cloudKit: MockCloudKitService(), appState: app, cacheService: cache, defaults: defaults)
        let container = try #require(cache.container)
        let handler = CKSyncEngineDelegateHandler(
            backgroundCache: BackgroundCacheActor(container: container),
            conflictResolver: CKSyncConflictResolver(cacheService: cache, appState: app),
            cacheService: cache,
            appState: app,
            notificationService: notifications
        )

        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        defer { UNUserNotificationCenter.current().removeAllPendingNotificationRequests() }

        let now = Date()
        let records = [
            makeEntry(zoneID, hero: maya, family: family, record: "ingest-spend-1", amount: -3.00, date: now).toRecord(),
            makeEntry(zoneID, hero: maya, family: family, record: "ingest-spend-2", amount: -1.50, date: now).toRecord()
        ]
        await handler.handleIncomingRecordsDirectly(records)

        #expect(cache.fetchLedgerEntries(profileRecordName: "maya", family: "fam1").count == 2)
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        #expect(pending.filter { $0.identifier.hasPrefix("\(NotificationEventType.spendingLogged.rawValue):") }.isEmpty)
    }
}

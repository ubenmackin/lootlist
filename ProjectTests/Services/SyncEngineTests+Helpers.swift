//
//  SyncEngineTests+Helpers.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
@testable import LootList
import os
import SwiftData
import Testing

// MARK: - Broken Record

struct BrokenRecord: CloudKitRecord {
    static let recordType = "Family"

    init() {}

    init(record _: CKRecord) throws {
        // Intentionally never succeeds — only used as a seed record.
        throw CKDecodingError.missingField("BrokenRecord is not decodable")
    }

    func toRecord() -> CKRecord {
        CKRecord(
            recordType: Self.recordType,
            recordID: CKRecord.ID(recordName: "broken_seed")
        )
    }
}

// MARK: - Concurrency Boxes

/// Thread-safe box for notification-observer state across closure boundaries.
final class SyncResultBox: Sendable {
    private let lock = OSAllocatedUnfairLock<(receivedNotification: Bool, receivedErrors: [String]?)>(
        initialState: (false, nil)
    )

    var receivedNotification: Bool {
        get { lock.withLock { $0.receivedNotification } }
        set { lock.withLock { $0.receivedNotification = newValue } }
    }

    var receivedErrors: [String]? {
        get { lock.withLock { $0.receivedErrors } }
        set { lock.withLock { $0.receivedErrors = newValue } }
    }
}

/// Thread-safe box capturing the `SyncOutcome` posted with `.syncDidComplete`.
final class OutcomeBox: Sendable {
    private let lock = OSAllocatedUnfairLock<SyncOutcome?>(initialState: nil)

    var value: SyncOutcome? {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }
}

// MARK: - Test Helpers Extension

extension SyncEngineTests {
    func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(
            for: QuestCache.self,
            QuestTemplateCache.self,
            ProfileCache.self,
            QuestCompletionCache.self,
            FamilyCache.self,
            LedgerEntryCache.self,
            AllowancePeriodCache.self,
            AchievementCache.self,
            ProfileAchievementCache.self,
            NotificationPreferenceCache.self,
            configurations: config
        )
    }

    func ref(_ name: String) -> CKRecord.Reference {
        CKRecord.Reference(recordID: CKRecord.ID(recordName: name), action: .none)
    }

    func fetchAll<T: PersistentModel>(_: T.Type, in container: ModelContainer) throws -> [T] {
        try ModelContext(container).fetch(FetchDescriptor<T>())
    }

    func remainingCount<T: PersistentModel>(_: T.Type, in container: ModelContainer) throws -> Int {
        try ModelContext(container).fetch(FetchDescriptor<T>()).count
    }

    func makeDummyServerChangeToken() -> CKServerChangeToken {
        guard let tokenClass = NSClassFromString("CKServerChangeToken"),
              let token = class_createInstance(tokenClass, 0) as? CKServerChangeToken
        else {
            preconditionFailure("Failed to allocate CKServerChangeToken")
        }
        return token
    }

    struct SUT {
        let engine: SyncEngine
        let cloudKit: any CloudKitServiceProtocol
        let cacheService: CacheService
        let coordinator: AppSyncCoordinator
        let backgroundContainer: ModelContainer
        let backgroundCache: BackgroundCacheActor
    }

    func makeSUT(
        seedRecords: [any CloudKitRecord] = [],
        zoneID: CKRecordZone.ID = CKRecordZone.ID(zoneName: "SyncTestZone", ownerName: "TestOwner"),
        activeFamilyZoneID: CKRecordZone.ID? = nil,
        existingBgContainer: ModelContainer? = nil
    ) throws -> SUT {
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = activeFamilyZoneID ?? zoneID

        if !seedRecords.isEmpty {
            cloudKit.seedMockRecords(seedRecords)
        }

        let bgContainer = try existingBgContainer ?? makeContainer()
        let backgroundCache = BackgroundCacheActor(container: bgContainer)

        let cacheService = try CacheService(inMemory: true)
        let coordinator = AppSyncCoordinator()

        let engine = SyncEngine(
            cloudKit: cloudKit,
            cacheService: cacheService,
            backgroundCache: backgroundCache,
            syncCoordinator: coordinator
        )

        return SUT(
            engine: engine,
            cloudKit: cloudKit,
            cacheService: cacheService,
            coordinator: coordinator,
            backgroundContainer: bgContainer,
            backgroundCache: backgroundCache
        )
    }

    // MARK: - Seed Data Builders

    func seedFamily(
        _ name: String = "Dragons",
        recordName: String = "fam1"
    ) -> Family {
        Family(
            name: name,
            createdBy: CKRecord.ID(recordName: "user1"),
            id: CKRecord.ID(recordName: recordName)
        )
    }

    func seedProfile(
        recordName: String = "prof1",
        familyRef: CKRecord.Reference? = nil
    ) -> Profile {
        let family = familyRef ?? ref("fam1")
        return Profile(
            displayName: "Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "icloud1"),
            family: family,
            id: CKRecord.ID(recordName: recordName)
        )
    }

    func seedQuest(
        recordName: String = "quest1",
        familyRef: CKRecord.Reference? = nil
    ) -> Quest {
        let family = familyRef ?? ref("fam1")
        return Quest(
            template: ref("tpl1"),
            assignee: ref("prof1"),
            goldReward: 5.0,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            approvalMode: .autoApprove,
            weekOf: Date(),
            createdBy: ref("user1"),
            family: family,
            name: "Clean Room",
            id: CKRecord.ID(recordName: recordName)
        )
    }

    func seedTemplate(
        recordName: String = "tpl1",
        familyRef: CKRecord.Reference? = nil
    ) -> QuestTemplate {
        let family = familyRef ?? ref("fam1")
        return QuestTemplate(
            name: "Clean Room",
            description: "Tidy up",
            defaultGold: 5.0,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            approvalMode: .autoApprove,
            createdBy: ref("user1"),
            family: family,
            id: CKRecord.ID(recordName: recordName)
        )
    }

    func seedCompletion(
        recordName: String = "comp1",
        familyRef: CKRecord.Reference? = nil
    ) -> QuestCompletion {
        let family = familyRef ?? ref("fam1")
        return QuestCompletion(
            quest: ref("quest1"),
            completedBy: ref("prof1"),
            approvalMode: .parentVerify,
            completedDate: Date(),
            weekOf: Date(),
            family: family,
            id: CKRecord.ID(recordName: recordName)
        )
    }

    func seedLedger(
        recordName: String = "ledger1",
        familyRef: CKRecord.Reference? = nil
    ) -> LedgerEntry {
        let family = familyRef ?? ref("fam1")
        return LedgerEntry(
            profile: ref("prof1"),
            amount: 5.0,
            description: "Bonus",
            family: family,
            id: CKRecord.ID(recordName: recordName)
        )
    }

    func seedAllowance(
        recordName: String = "allow1",
        familyRef: CKRecord.Reference? = nil
    ) -> AllowancePeriod {
        let family = familyRef ?? ref("fam1")
        return AllowancePeriod(
            weekOf: Date(),
            profile: ref("prof1"),
            questsTotal: 5,
            family: family,
            id: CKRecord.ID(recordName: recordName)
        )
    }

    func seedAchievement(
        recordName: String = "ach1",
        familyRef: CKRecord.Reference? = nil
    ) -> Achievement {
        let family = familyRef ?? ref("fam1")
        return Achievement(
            name: "First Quest",
            description: "Complete one quest",
            iconSystemName: "star.fill",
            category: .quest,
            requirementType: .firstQuest,
            requirementValue: 1,
            family: family,
            id: CKRecord.ID(recordName: recordName)
        )
    }

    func seedProfileAchievement(
        recordName: String = "pa1",
        familyRef: CKRecord.Reference? = nil
    ) -> ProfileAchievement {
        let family = familyRef ?? ref("fam1")
        return ProfileAchievement(
            achievement: ref("ach1"),
            profile: ref("prof1"),
            family: family,
            id: CKRecord.ID(recordName: recordName)
        )
    }

    func seedNotificationPref(
        recordName: String = "notif1",
        familyRef: CKRecord.Reference? = nil
    ) -> NotificationPreference {
        let family = familyRef ?? ref("fam1")
        return NotificationPreference(
            profile: ref("prof1"),
            eventType: .questCompleted,
            enabled: true,
            family: family,
            id: CKRecord.ID(recordName: recordName)
        )
    }

    func allTenTypes(
        familyRef: CKRecord.Reference? = nil,
        familyRecordName: String = "fam1"
    ) -> [any CloudKitRecord] {
        [
            seedFamily(recordName: familyRecordName),
            seedProfile(familyRef: familyRef),
            seedQuest(familyRef: familyRef),
            seedTemplate(familyRef: familyRef),
            seedCompletion(familyRef: familyRef),
            seedLedger(familyRef: familyRef),
            seedAllowance(familyRef: familyRef),
            seedAchievement(familyRef: familyRef),
            seedProfileAchievement(familyRef: familyRef),
            seedNotificationPref(familyRef: familyRef)
        ]
    }

    func captureOutcome(
        for engine: SyncEngine,
        during operation: () async -> Void
    ) async -> SyncOutcome? {
        let box = OutcomeBox()
        let observer = NotificationCenter.default.addObserver(
            forName: .syncDidComplete,
            object: engine,
            queue: .main
        ) { notification in
            box.value = notification.userInfo?[SyncOutcome.userInfoKey] as? SyncOutcome
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        await operation()
        await Task.yield()
        return box.value
    }
}

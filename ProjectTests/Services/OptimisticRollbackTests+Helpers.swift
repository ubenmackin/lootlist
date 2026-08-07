//
//  OptimisticRollbackTests+Helpers.swift
//  LootList
//
//  Created by Ben Mackin on 8/05/26.
//

import CloudKit
import Foundation
@testable import LootList
import SwiftData

// MARK: - Mock Infrastructure

enum MockError: Error, Equatable {
    case saveFailed
}

/// Subclass of `CloudKitService` that always throws on `save`.
/// Used to exercise the standard rollback (non-concurrent-edit) path.
final class FailingCloudKitService: MockCloudKitService {
    init(zoneID: CKRecordZone.ID? = nil) {
        super.init()
        self.activeFamilyZoneID = zoneID
    }

    override func save<T: CloudKitRecord>(
        _: T,
        in _: CKRecordZone.ID? = nil,
        using _: CKDatabase? = nil
    ) async throws -> T {
        throw MockError.saveFailed
    }

    override func delete(
        _: CKRecord.ID,
        in _: CKRecordZone.ID? = nil,
        using _: CKDatabase? = nil
    ) async throws {
        throw MockError.saveFailed
    }
}

/// Subclass of `CloudKitService` that succeeds for the first N `save`
/// calls, then throws on subsequent saves.  Needed for multi-step
/// mutations (e.g., `assignQuickQuest`) where intermediate saves such
/// as `createTemplate` + `deactivateTemplate` must succeed before the
/// final quest save is made to fail.
final class FailingAfterNSavesCloudKitService: MockCloudKitService {
    private var saveCount = 0
    private let failAfterSaveCount: Int

    init(zoneID: CKRecordZone.ID, failAfterSaveCount: Int) {
        self.failAfterSaveCount = failAfterSaveCount
        super.init()
        self.activeFamilyZoneID = zoneID
    }

    override func save<T: CloudKitRecord>(
        _ model: T,
        in zoneID: CKRecordZone.ID? = nil,
        using db: CKDatabase? = nil
    ) async throws -> T {
        saveCount += 1
        if saveCount > failAfterSaveCount {
            throw MockError.saveFailed
        }
        return try await super.save(model, in: zoneID, using: db)
    }
}

/// Subclass of `CloudKitService` that fails every `save` with
/// `CloudKitServiceError.notFound` — the exact error CloudKitService wraps
/// `CKError.unknownItem` into when a record was deleted on the server
/// while a mutation was in flight. `fetch` fails the same way, matching
/// the real server state after a concurrent delete.
final class NotFoundCloudKitService: MockCloudKitService {
    init(zoneID: CKRecordZone.ID? = nil) {
        super.init()
        self.activeFamilyZoneID = zoneID
    }

    override func save<T: CloudKitRecord>(
        _: T,
        in _: CKRecordZone.ID? = nil,
        using _: CKDatabase? = nil
    ) async throws -> T {
        throw CloudKitServiceError.notFound("22")
    }

    override func fetch<T: CloudKitRecord>(
        _: T.Type,
        id _: CKRecord.ID,
        using _: CKDatabase? = nil
    ) async throws -> T {
        throw CloudKitServiceError.notFound("22")
    }
}

// MARK: - Test Helpers Extension

extension OptimisticRollbackTests {
    func makeZoneID() -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
    }

    func makeFamilyRef(_ zoneID: CKRecordZone.ID) -> CKRecord.Reference {
        CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID),
            action: .none
        )
    }

    func makeParent(_ zoneID: CKRecordZone.ID) -> Profile {
        let userID = CKRecord.ID(recordName: "parent1", zoneID: zoneID)
        return Profile(
            displayName: "Parent GM",
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .guildMaster,
            iCloudUserID: userID,
            family: makeFamilyRef(zoneID)
        )
    }

    func makeHero(_ zoneID: CKRecordZone.ID) -> Profile {
        let userID = CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        return Profile(
            displayName: "Child Hero",
            avatarClass: .mage,
            avatarPresetID: "mage_01",
            role: .hero,
            iCloudUserID: userID,
            family: makeFamilyRef(zoneID),
            id: userID
        )
    }

    func makeFamily(_ zoneID: CKRecordZone.ID) -> Family {
        Family(
            name: "Test Guild",
            createdBy: CKRecord.ID(recordName: "parent1", zoneID: zoneID),
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )
    }

    func makeOptimisticQuest(_ zoneID: CKRecordZone.ID) -> (quest: Quest, questID: CKRecord.ID) {
        let familyRef = makeFamilyRef(zoneID)
        let hero = makeHero(zoneID)
        let monday = WeekMath.mondayOfWeek(for: Date())
        let templateRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "tmpl1", zoneID: zoneID), action: .none
        )
        let questID = CKRecord.ID(recordName: "quest1", zoneID: zoneID)
        let quest = Quest(
            template: templateRef,
            assignee: CKRecord.Reference(recordID: hero.id, action: .none),
            goldReward: 10.0,
            xpReward: 20,
            scheduleType: .weeklyFlexible,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: monday,
            createdBy: familyRef,
            family: familyRef,
            name: "Original Quest",
            id: questID
        )
        return (quest, questID)
    }

    /// Reads a quest through a FRESH `ModelContext` so the assertion reflects
    /// the committed store state, not a possibly-stale registered object in
    /// the mainContext (cross-context propagation is not guaranteed).
    func fetchCachedQuest(
        _ container: ModelContainer,
        recordName: String,
        zoneID: CKRecordZone.ID
    ) throws -> Quest? {
        let ctx = ModelContext(container)
        let descriptor = FetchDescriptor<QuestCache>(
            predicate: #Predicate { $0.recordName == recordName }
        )
        return try ctx.fetch(descriptor).first?.toQuest(zoneID: zoneID)
    }
}

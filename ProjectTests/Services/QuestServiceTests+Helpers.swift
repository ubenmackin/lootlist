//
//  QuestServiceTests+Helpers.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
@testable import LootList
import Synchronization
import Testing

// MARK: - Save Gate State

struct SaveGateState {
    var continuations: [CheckedContinuation<Void, Never>] = []
    var isReleased = false
    var parkedCount = 0
}

// MARK: - Test Doubles

/// Counts CloudKit `query`/`fetch` calls and throws `networkUnavailable`
/// for both, so tests can assert a mutation path performs zero CloudKit
/// READS (the save path is left intact via the mock storage).
class NetworkCountingCloudKitService: MockCloudKitService {
    override init(zoneID: CKRecordZone.ID? = nil) {
        super.init()
        self.activeFamilyZoneID = zoneID
    }

    var readCallCount = 0

    override func query<T: CloudKitRecord>(
        _: T.Type,
        predicate _: NSPredicate,
        in _: CKRecordZone.ID? = nil,
        sortDescriptors _: [NSSortDescriptor]? = nil,
        using _: CKDatabase? = nil
    ) async throws -> [T] {
        readCallCount += 1
        throw CloudKitServiceError.networkUnavailable
    }

    override func fetch<T: CloudKitRecord>(
        _: T.Type,
        id _: CKRecord.ID,
        using _: CKDatabase? = nil
    ) async throws -> T {
        readCallCount += 1
        throw CloudKitServiceError.networkUnavailable
    }
}

/// Parks `save` calls until the test releases them, opening a deterministic
/// in-flight window for the double-submit guard. Also counts CloudKit reads.
final class GatedCloudKitService: NetworkCountingCloudKitService {
    private let gate = SaveGate()

    override func save<T: CloudKitRecord>(
        _ model: T,
        in zoneID: CKRecordZone.ID? = nil,
        using db: CKDatabase? = nil
    ) async throws -> T {
        await gate.park()
        return try await super.save(model, in: zoneID, using: db)
    }

    func waitForParked(count: Int = 1) async {
        await gate.waitForParked(count: count)
    }

    func releaseSaves() {
        gate.releaseAll()
    }
}

/// Holds parked `save` continuations behind a `Mutex` so a `@Sendable`
/// closure can park without touching main-actor state (Swift 6 safe).
final class SaveGate: Sendable {
    private let lock = Mutex<SaveGateState>(SaveGateState())

    func park() async {
        let shouldPark = lock.withLock { state -> Bool in
            state.parkedCount += 1
            return !state.isReleased
        }
        if shouldPark {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.withLock { state in
                    if state.isReleased {
                        continuation.resume()
                    } else {
                        state.continuations.append(continuation)
                    }
                }
            }
        }
    }

    func waitForParked(count targetCount: Int = 1) async {
        while true {
            let current = lock.withLock { $0.parkedCount }
            if current >= targetCount {
                return
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    func releaseAll() {
        let toResume = lock.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isReleased = true
            let all = state.continuations
            state.continuations.removeAll()
            return all
        }
        for continuation in toResume {
            continuation.resume()
        }
    }
}

/// CloudKitService test double that records `query` calls and parks callers for testing background behavior.
final class QueryParkingCloudKitService: MockCloudKitService {
    override init(zoneID: CKRecordZone.ID? = nil) {
        super.init()
        self.activeFamilyZoneID = zoneID
    }

    private let lock = Mutex<QueryGateState>(QueryGateState())
    private(set) var queryHitCount = 0

    private struct QueryGateState {
        var parked: [CheckedContinuation<Void, Never>] = []
        var released = false
    }

    override func query<T: CloudKitRecord>(
        _: T.Type,
        predicate _: NSPredicate,
        in _: CKRecordZone.ID? = nil,
        sortDescriptors _: [NSSortDescriptor]? = nil,
        using _: CKDatabase? = nil
    ) async throws -> [T] {
        queryHitCount += 1
        await park()
        return []
    }

    private func park() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.withLock { state in
                if state.released {
                    continuation.resume()
                } else {
                    state.parked.append(continuation)
                }
            }
        }
    }

    func releaseQueries() {
        let toResume = lock.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.released = true
            let all = state.parked
            state.parked.removeAll()
            return all
        }
        for continuation in toResume {
            continuation.resume()
        }
    }
}

// MARK: - Test Helpers Extension

extension QuestServiceTests {
    func makeTestData() -> (MockCloudKitService, Profile, Profile, Family) { // swiftlint:disable:this large_tuple
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)
        let userID = CKRecord.ID(recordName: "user1", zoneID: zoneID)

        let parent = Profile(
            displayName: "Parent GM",
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .guildMaster,
            iCloudUserID: userID,
            family: familyRef
        )

        let hero = Profile(
            displayName: "Child Hero",
            avatarClass: .mage,
            avatarPresetID: "mage_01",
            role: .hero,
            iCloudUserID: userID,
            family: familyRef
        )

        let family = Family(
            name: "Test Guild",
            createdBy: parent.id,
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )

        return (cloudKit, parent, hero, family)
    }

    @MainActor
    struct MarkCompleteScaffold {
        let zoneID: CKRecordZone.ID
        let cloudKit: any CloudKitServiceProtocol
        let cache: CacheService
        let questService: QuestService
        let appState: AppState
        let familyRef: CKRecord.Reference
        let parent: Profile
        let hero: Profile
        let quest: Quest
        let questRef: CKRecord.Reference

        init(
            approvalMode: ApprovalMode = .parentVerify,
            cloudKitOverride: (any CloudKitServiceProtocol)? = nil,
            goldReward: Double = 10.0,
            xpReward: Int = 20,
            targetCount: Int = 1,
            isAllOrNothing: Bool = false
        ) throws {
            zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
            let resolvedCloudKit = cloudKitOverride ?? MockCloudKitService()
            resolvedCloudKit.activeFamilyZoneID = zoneID
            cloudKit = resolvedCloudKit
            cache = try CacheService(inMemory: true)
            // The XP-credit ledger now lives on CloudKit records
            // (`Quest.xpBanked` + `QuestCompletion.xpCredited`), so the reward
            // path needs no injected ledger state — the shared CloudKit mock
            // IS the shared source of truth across simulated devices.
            questService = QuestService(
                cloudKit: resolvedCloudKit,
                xpService: XPService(cloudKit: resolvedCloudKit)
            )
            questService.cacheService = cache
            questService.xpService.cacheService = cache
            // Verify/reject resolve the acting profile from the authenticated
            // session. The scaffold's default acting profile is the hero, so a
            // `markComplete(quest:by:hero)` self-completion passes the identity
            familyRef = CKRecord.Reference(
                recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none
            )
            let parentID = CKRecord.ID(recordName: "parent1", zoneID: zoneID)
            parent = Profile(
                displayName: "Parent GM",
                avatarClass: .knight,
                avatarPresetID: "knight_01",
                role: .guildMaster,
                iCloudUserID: parentID,
                family: familyRef,
                id: parentID
            )

            appState = AppState(defaults: .ephemeral())
            appState.familyZoneID = zoneID
            appState.isZoneOwner = resolvedCloudKit.activeIsOwner
            appState.family = Family(
                name: "fam1",
                createdBy: parentID,
                id: familyRef.recordID
            )
            questService.appState = appState
            questService.xpService.appState = appState
            let heroID = CKRecord.ID(recordName: "hero1", zoneID: zoneID)
            hero = Profile(
                displayName: "Hero",
                avatarClass: .mage,
                avatarPresetID: "mage_01",
                role: .hero,
                iCloudUserID: heroID,
                family: familyRef,
                id: heroID
            )
            appState.currentProfile = hero

            let questID = CKRecord.ID(recordName: "quest1", zoneID: zoneID)
            let templateRef = CKRecord.Reference(
                recordID: CKRecord.ID(recordName: "tmpl1", zoneID: zoneID), action: .none
            )
            questRef = CKRecord.Reference(recordID: questID, action: .none)
            quest = Quest(
                template: templateRef,
                assignee: CKRecord.Reference(recordID: heroID, action: .none),
                goldReward: goldReward,
                xpReward: xpReward,
                scheduleType: .weeklyFlexible,
                targetCount: targetCount,
                isAllOrNothing: isAllOrNothing,
                approvalMode: approvalMode,
                weekOf: WeekMath.mondayOfWeek(for: Date()),
                createdBy: CKRecord.Reference(recordID: parentID, action: .none),
                family: familyRef,
                name: "Guard Quest",
                id: questID
            )
            cache.upsertProfile(parent)
            cache.upsertProfile(hero)
            cache.upsertQuest(quest)
            if let family = appState.family {
                cache.upsertFamily(family)
            }
            if let mock = resolvedCloudKit as? MockCloudKitService {
                mock.seedMockRecords([parent, hero, quest])
            }
        }

        /// Seeds records into the scaffold's mock store. Mock seeding is not a
        /// `CloudKitServiceProtocol` requirement, so tests route through this
        /// helper instead of calling the protocol existential directly.
        func seedMockRecords(_ models: [any CloudKitRecord]) {
            (cloudKit as? MockCloudKitService)?.seedMockRecords(models)
        }

        func completion(
            status: VerificationStatus,
            recordName: String = "log1"
        ) -> QuestCompletion {
            var log = QuestCompletion(
                quest: questRef,
                completedBy: CKRecord.Reference(recordID: hero.id, action: .none),
                approvalMode: .parentVerify,
                weekOf: quest.weekOf,
                family: familyRef,
                id: CKRecord.ID(recordName: recordName, zoneID: zoneID)
            )
            log.verificationStatus = status
            return log
        }
    }
}

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
    init(zoneID: CKRecordZone.ID? = nil) {
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

/// A CloudKitService double that rejects the Nth `Quest` record save with
/// `CloudKitServiceError.serverRecordChanged` — the exact error surface the
/// production `CloudKitService.save` wraps `CKError.serverRecordChanged` into.
/// Lets a test force the change-tag CAS retry path in `QuestService.applyReward`
/// deterministically: the first quest save (device A's bank) succeeds, the
/// second (device B's stale attempt) is rejected, and the retry must re-fetch
/// the authoritative quest and recompute the marginal to 0.
final class OneShotQuestConflictCloudKitService: MockCloudKitService {
    private var questSaveCount = 0
    private let conflictOnQuestSave: Int

    init(zoneID: CKRecordZone.ID, conflictOnQuestSave: Int = 2) {
        self.conflictOnQuestSave = conflictOnQuestSave
        super.init()
        self.activeFamilyZoneID = zoneID
    }

    override func save<T: CloudKitRecord>(
        _ model: T,
        in zoneID: CKRecordZone.ID? = nil,
        using db: CKDatabase? = nil
    ) async throws -> T {
        if T.recordType == Quest.recordType {
            questSaveCount += 1
            if questSaveCount == conflictOnQuestSave {
                throw CloudKitServiceError.serverRecordChanged
            }
        }
        return try await super.save(model, in: zoneID, using: db)
    }
}

/// A CloudKitService double that rejects EVERY `Quest` save with
/// `CloudKitServiceError.serverRecordChanged` — simulating sustained
/// contention where the CAS retry loop in `QuestService.bankXP` exhausts its
/// bounded attempts without ever settling. Used to prove that a completion
/// which loses the CAS race is NOT permanently marked settled
/// (`QuestCompletion.xpCredited` stays `nil` → re-grantable on a future run),
/// rather than being silently stamped with a `0` that suppresses re-grant.
final class AlwaysConflictQuestCloudKitService: MockCloudKitService {
    init(zoneID: CKRecordZone.ID? = nil) {
        super.init()
        self.activeFamilyZoneID = zoneID
    }

    override func save<T: CloudKitRecord>(
        _ model: T,
        in zoneID: CKRecordZone.ID? = nil,
        using db: CKDatabase? = nil
    ) async throws -> T {
        if T.recordType == Quest.recordType {
            throw CloudKitServiceError.serverRecordChanged
        }
        return try await super.save(model, in: zoneID, using: db)
    }
}

/// A CloudKitService double that records every `query` call synchronously
/// (incrementing a counter before doing anything else) and parks the caller
/// until released, without touching the network. Used to prove `markComplete`
/// does NOT spawn a fire-and-forget `Task { fetchQuestLogs(useCache: false) }`
/// after the save — services must not issue ad-hoc CloudKit refreshes.
/// The count is bumped on entry so a test can yield the runloop and assert it
/// stays 0; `releaseQueries` releases any (none, post-remediation) parked
/// caller so the test tears down cleanly.
final class QueryParkingCloudKitService: MockCloudKitService {
    init(zoneID: CKRecordZone.ID? = nil) {
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
            // guard without further setup; verify/reject callers must override
            // `appState.currentProfile` to the parent (or ranger) acting profile.
            appState = AppState()

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
                family: familyRef
            )
            questService.appState = appState
            questService.xpService.appState = appState
            // One hero record shared by every scaffold: `hero.id` must be the
            // deterministic "hero1" record — the same one `quest.assignee`
            // references below — NOT a fresh UUID per scaffold. Cross-device
            // tests seed a single shared mock and expect fetches of the hero
            // from every device's scaffold to resolve to that one record.
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
            // markComplete mints rewards to the caller-supplied `by` profile,
            // guarded by identity against the authenticated session, so the
            // scaffold's acting session defaults to the hero (the only
            // identity allowed to complete the scaffold's quest in tests that
            // exercise markComplete directly). Tests that exercise verify or
            // reject (parent-only) override `appState.currentProfile` to the
            // parent (or ranger) profile before calling those methods.
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
            resolvedCloudKit.seedMockRecords([parent, hero, quest])
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

//
//  FamilyServiceTests+Concurrency.swift
//  LootList
//
//  Created by Ben Mackin on 8/19/26.
//

import CloudKit
import Foundation
@testable import LootList
import Synchronization
import Testing

// MARK: - Test Doubles for Concurrency

final class QueryGate: Sendable {
    private struct State {
        var isOpen = false
        var parkedCount = 0
        var continuations: [CheckedContinuation<Void, Never>] = []
        var parkWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex<State>(State())

    func park() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let (shouldResumeImmediately, waitersToResume) = state.withLock { currentState -> (Bool, [CheckedContinuation<Void, Never>]) in
                if currentState.isOpen {
                    return (true, [])
                }
                currentState.parkedCount += 1
                currentState.continuations.append(continuation)
                let waiters = currentState.parkWaiters
                currentState.parkWaiters.removeAll()
                return (false, waiters)
            }
            for waiter in waitersToResume {
                waiter.resume()
            }
            if shouldResumeImmediately {
                continuation.resume()
            }
        }
    }

    func waitUntilParked(atLeast count: Int = 1) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let shouldResumeImmediately = state.withLock { currentState -> Bool in
                if currentState.parkedCount >= count || currentState.isOpen {
                    return true
                }
                currentState.parkWaiters.append(continuation)
                return false
            }
            if shouldResumeImmediately {
                continuation.resume()
            }
        }
    }

    func releaseAll() {
        let toResume = state.withLock { currentState -> [CheckedContinuation<Void, Never>] in
            currentState.isOpen = true
            let all = currentState.continuations
            currentState.continuations.removeAll()
            let waiters = currentState.parkWaiters
            currentState.parkWaiters.removeAll()
            return all + waiters
        }
        for continuation in toResume {
            continuation.resume()
        }
    }
}

final class GatedQueryCloudKitService: MockCloudKitService, @unchecked Sendable {
    override init(zoneID: CKRecordZone.ID? = nil) {
        super.init()
        self.activeFamilyZoneID = zoneID
    }

    private let gate = QueryGate()
    private let countLock = Mutex<Int>(0)

    var queryCallCount: Int {
        countLock.withLock { $0 }
    }

    override func query<T: CloudKitRecord>(
        _: T.Type,
        predicate: NSPredicate,
        in zoneID: CKRecordZone.ID? = nil,
        sortDescriptors: [NSSortDescriptor]? = nil,
        using db: CKDatabase? = nil
    ) async throws -> [T] {
        countLock.withLock { $0 += 1 }
        await gate.park()
        return try await super.query(T.self, predicate: predicate, in: zoneID, sortDescriptors: sortDescriptors, using: db)
    }

    func waitUntilParked(atLeast count: Int = 1) async {
        await gate.waitUntilParked(atLeast: count)
    }

    func releaseQueries() {
        gate.releaseAll()
    }
}

// MARK: - Concurrency Stress Harness: refreshInFlightKeys collapse

extension FamilyServiceTests {
    @Test @MainActor
    func `concurrent refreshProfilesFromCloudKit collapses to one query for ten callers`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = GatedQueryCloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let familyService = makeFamilyServiceWithCache(cloudKit: cloudKit, cache: cache)

        let familyRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none
        )
        let family = Family(
            name: "Test Guild",
            createdBy: CKRecord.ID(recordName: "owner1", zoneID: zoneID),
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )
        let ckHero = Profile(
            displayName: "CK Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "u1", zoneID: zoneID),
            family: familyRef,
            id: CKRecord.ID(recordName: "hero-ck", zoneID: zoneID)
        )
        cloudKit.seedMockRecords([ckHero])

        var tasks: [Task<Void, Never>] = []
        for _ in 0 ..< 10 {
            tasks.append(Task { @MainActor in
                await familyService.refreshProfilesFromCloudKit(for: family)
            })
        }

        // Wait until the first refresh is parked inside its CloudKit query holding the in-flight key.
        await cloudKit.waitUntilParked()

        #expect(cloudKit.queryCallCount == 1, "Concurrent refreshes for same family must collapse to one query")
        cloudKit.releaseQueries()
        for task in tasks {
            _ = await task.value
        }

        let profiles = cache.fetchProfiles(family: "fam1")
        #expect(profiles.count == 1)
        #expect(profiles.first?.recordName == "hero-ck")
    }

    @Test @MainActor
    func `mutex set atomic insertIfAbsent prevents duplicate refresh keys`() {
        let mutex = Mutex<Set<String>>([])
        let key = "profiles|fam1"
        let first = mutex.withLock { set -> Bool in
            if set.contains(key) {
                return false
            }
            set.insert(key)
            return true
        }
        var duplicates = 0
        for _ in 0 ..< 9 {
            let alreadyInFlight = mutex.withLock { set -> Bool in
                if set.contains(key) {
                    return true
                }
                set.insert(key)
                return false
            }
            if alreadyInFlight {
                duplicates += 1
            }
        }
        #expect(first == true)
        #expect(duplicates == 9, "Nine concurrent inserts must be detected as already in flight")
        mutex.withLock { _ = $0.remove(key) }
        #expect(mutex.withLock { $0.isEmpty })
    }
}

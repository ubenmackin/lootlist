//
//  JourneyServiceTests.swift
//  LootListTests
//
//  Created by Ben Mackin on 8/22/26.
//

import CloudKit
@testable import LootList
import Testing

@Suite("JourneyService")
@MainActor
struct JourneyServiceTests {
    // MARK: - Test Helpers

    private let dummyZone = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")

    private func makeProfile(level: Int, xp: Int) -> Profile {
        let familyRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "fam1", zoneID: dummyZone),
            action: .none
        )
        let userID = CKRecord.ID(recordName: "user1", zoneID: dummyZone)
        var profile = Profile(
            displayName: "TestHero",
            avatarClass: .knight,
            role: .hero,
            iCloudUserID: userID,
            family: familyRef,
            id: CKRecord.ID(recordName: "hero1", zoneID: dummyZone)
        )
        profile.xp = xp
        profile.level = level
        return profile
    }

    private func makeXPService() -> XPService {
        let cloudKit = MockCloudKitService()
        return XPService(cloudKit: cloudKit)
    }

    // MARK: - Journey State for Level 1

    @Test
    func `level 1 hero is in the Starting Meadow`() {
        let profile = makeProfile(level: 1, xp: 0)
        let xpService = makeXPService()
        let state = JourneyService.journeyState(for: profile, xpService: xpService)

        #expect(state.currentLevel == 1)
        #expect(state.currentZone == .startingMeadow)
        #expect(state.zonesUnlocked.count == 1)
        #expect(state.zonesUnlocked.first == .startingMeadow)
    }

    @Test
    func `level 1 hero has exactly one current milestone`() {
        let profile = makeProfile(level: 1, xp: 0)
        let xpService = makeXPService()
        let state = JourneyService.journeyState(for: profile, xpService: xpService)

        let currentMilestones = state.milestones.filter { $0.state == .current }
        #expect(currentMilestones.count == 1)
        #expect(currentMilestones.first?.level == 1)
    }

    // MARK: - Journey State for Mid-Level Hero

    @Test
    func `level 10 hero is in the Dense Forest`() {
        let xp = XPService.cumulativeXPForLevel(10) + 50
        let profile = makeProfile(level: 10, xp: xp)
        let xpService = makeXPService()
        let state = JourneyService.journeyState(for: profile, xpService: xpService)

        #expect(state.currentLevel == 10)
        #expect(state.currentZone == .denseForest)
        #expect(state.zonesUnlocked.count == 2) // Meadow + Forest
    }

    @Test
    func `level 10 hero has 10 milestones reached or current`() {
        let xp = XPService.cumulativeXPForLevel(10) + 50
        let profile = makeProfile(level: 10, xp: xp)
        let xpService = makeXPService()
        let state = JourneyService.journeyState(for: profile, xpService: xpService)

        let reachedOrCurrent = state.milestones.filter { $0.state != .future }
        #expect(reachedOrCurrent.count == 10)
    }

    // MARK: - Journey State for High-Level Hero

    @Test
    func `level 21 hero is in the Eternal Realm`() {
        let xp = XPService.cumulativeXPForLevel(21) + 100
        let profile = makeProfile(level: 21, xp: xp)
        let xpService = makeXPService()
        let state = JourneyService.journeyState(for: profile, xpService: xpService)

        #expect(state.currentLevel == 21)
        #expect(state.currentZone == .eternalRealm)
        #expect(state.zonesUnlocked.count == 5) // All zones
    }

    @Test
    func `level 25 hero has milestones beyond default display cap`() {
        let xp = XPService.cumulativeXPForLevel(25) + 100
        let profile = makeProfile(level: 25, xp: xp)
        let xpService = makeXPService()
        let state = JourneyService.journeyState(for: profile, xpService: xpService)

        // Should have milestones at least up to level 25
        let maxLevel = state.milestones.max(by: { $0.level < $1.level })?.level ?? 0
        #expect(maxLevel >= 25)
    }

    // MARK: - Milestone Properties

    @Test
    func `milestones are in sequential order by level`() {
        let profile = makeProfile(level: 15, xp: XPService.cumulativeXPForLevel(15))
        let xpService = makeXPService()
        let state = JourneyService.journeyState(for: profile, xpService: xpService)

        for index in 1 ..< state.milestones.count {
            #expect(state.milestones[index].level > state.milestones[index - 1].level,
                    "Milestones not in sequential order at index \(index)")
        }
    }

    @Test
    func `exactly one milestone has state .current`() {
        let profile = makeProfile(level: 12, xp: XPService.cumulativeXPForLevel(12) + 30)
        let xpService = makeXPService()
        let state = JourneyService.journeyState(for: profile, xpService: xpService)

        let currentCount = state.milestones.filter { $0.state == .current }.count
        #expect(currentCount == 1)
    }

    @Test
    func `XP requirements are monotonically increasing`() {
        let profile = makeProfile(level: 20, xp: XPService.cumulativeXPForLevel(20))
        let xpService = makeXPService()
        let state = JourneyService.journeyState(for: profile, xpService: xpService)

        for index in 1 ..< state.milestones.count {
            #expect(state.milestones[index].xpRequired >= state.milestones[index - 1].xpRequired,
                    "XP requirements not monotonic at level \(state.milestones[index].level)")
        }
    }

    @Test
    func `each milestone has a non-empty title`() {
        let profile = makeProfile(level: 8, xp: XPService.cumulativeXPForLevel(8))
        let xpService = makeXPService()
        let state = JourneyService.journeyState(for: profile, xpService: xpService)

        for milestone in state.milestones {
            #expect(!milestone.title.isEmpty, "Milestone at level \(milestone.level) has empty title")
        }
    }

    @Test
    func `each milestone zone matches its level`() {
        let profile = makeProfile(level: 18, xp: XPService.cumulativeXPForLevel(18))
        let xpService = makeXPService()
        let state = JourneyService.journeyState(for: profile, xpService: xpService)

        for milestone in state.milestones {
            let expectedZone = JourneyZone.zone(forLevel: milestone.level)
            #expect(milestone.zone == expectedZone,
                    "Milestone level \(milestone.level) zone \(milestone.zone) != expected \(expectedZone)")
        }
    }

    // MARK: - Progress Value

    @Test
    func `progress is between 0 and 1`() {
        let profile = makeProfile(level: 5, xp: XPService.cumulativeXPForLevel(5) + 30)
        let xpService = makeXPService()
        let state = JourneyService.journeyState(for: profile, xpService: xpService)

        #expect(state.progress >= 0.0)
        #expect(state.progress <= 1.0)
    }

    // MARK: - Level Acknowledgment & CloudKit Sync

    @Test
    func `acknowledgeJourneyLevel advances journeyMapLastSeenLevel when higher`() throws {
        var profile = makeProfile(level: 5, xp: 500)
        profile.journeyMapLastSeenLevel = 2

        let cache = try CacheService(inMemory: true)
        cache.upsertProfile(profile)

        JourneyService.acknowledgeJourneyLevel(
            5,
            profile: profile,
            appState: nil,
            cacheService: cache,
            syncCoordinator: nil
        )

        let cached = cache.fetchProfile(recordName: profile.id.recordName, family: profile.family.recordID.recordName)
        #expect(cached?.journeyMapLastSeenLevel == 5)
    }

    @Test
    func `acknowledgeJourneyLevel ignores lower or equal level`() throws {
        var profile = makeProfile(level: 5, xp: 500)
        profile.journeyMapLastSeenLevel = 5

        let cache = try CacheService(inMemory: true)
        cache.upsertProfile(profile)

        JourneyService.acknowledgeJourneyLevel(
            3,
            profile: profile,
            appState: nil,
            cacheService: cache,
            syncCoordinator: nil
        )

        let cached = cache.fetchProfile(recordName: profile.id.recordName, family: profile.family.recordID.recordName)
        #expect(cached?.journeyMapLastSeenLevel == 5)
    }

    @Test
    func `profile round trips journeyMapLastSeenLevel via CKRecord`() throws {
        var profile = makeProfile(level: 7, xp: 1200)
        profile.journeyMapLastSeenLevel = 7

        let record = profile.toRecord()
        let decoded = try Profile(record: record)

        #expect(decoded.journeyMapLastSeenLevel == 7)
    }
}

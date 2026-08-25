//
//  DailyLoginServiceTests.swift
//  LootListTests
//
//  Created by Antigravity on 8/23/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

@MainActor
struct DailyLoginServiceTests {
    private func makeZoneID(name: String = "DailyZone") -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: name, ownerName: "DailyOwner")
    }

    private func makeProfile(zoneID: CKRecordZone.ID, recordName: String = "hero1") -> Profile {
        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)
        let profileID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        return Profile(
            displayName: "Hero",
            avatarClass: .mage,
            avatarPresetID: "mage_01",
            role: .hero,
            iCloudUserID: profileID,
            family: familyRef,
            id: profileID
        )
    }

    private func makeFamily(zoneID: CKRecordZone.ID) -> Family {
        Family(
            name: "Daily Guild",
            createdBy: CKRecord.ID(recordName: "hero1", zoneID: zoneID),
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )
    }

    private struct TestFixture {
        let cloudKit: MockCloudKitService
        let cache: CacheService
        let appState: AppState
        let gemService: GemService
        let dailyService: DailyLoginService
        let sound: SoundManager
        let hero: Profile
        let family: Family
        let zoneID: CKRecordZone.ID
    }

    private func makeFixture(calendar: Calendar? = nil) throws -> TestFixture {
        let defaults = UserDefaults.ephemeral()
        let zoneID = makeZoneID()
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
        cloudKit.activeIsOwner = true
        let cache = try CacheService(inMemory: true, defaults: defaults)
        let appState = AppState(defaults: defaults)
        appState.cacheService = cache

        let family = makeFamily(zoneID: zoneID)
        var hero = makeProfile(zoneID: zoneID)
        hero.family = CKRecord.Reference(recordID: family.id, action: .none)
        cache.upsertFamily(family)
        cache.upsertProfile(hero)
        cloudKit.seedMockRecords([family, hero])
        appState.family = family
        appState.familyZoneID = zoneID
        appState.currentProfile = hero
        appState.isZoneOwner = true
        appState.authStatus = .authenticated

        let toast = ToastManager()
        let sound = SoundManager()
        let gemService = GemService(cloudKitService: cloudKit, cacheService: cache, toastManager: toast, appState: appState, soundManager: sound)
        let dailyService = DailyLoginService(cloudKitService: cloudKit, cacheService: cache, appState: appState, calendar: calendar)

        return TestFixture(
            cloudKit: cloudKit,
            cache: cache,
            appState: appState,
            gemService: gemService,
            dailyService: dailyService,
            sound: sound,
            hero: hero,
            family: family,
            zoneID: zoneID
        )
    }

    private func dateString(for date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = calendar.timeZone
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    @Test
    func `claimDailyReward successfully awards gems and transitions status to claimedToday`() async throws {
        let fixture = try makeFixture()
        let hero = fixture.hero
        let dailyService = fixture.dailyService
        let gemService = fixture.gemService
        let sound = fixture.sound
        let appState = fixture.appState
        let family = fixture.family

        let initialStatus = dailyService.checkDailyLoginStatus(heroProfileRecordName: hero.id.recordName)
        #expect(initialStatus == .available)

        let gemsAwarded = try await dailyService.claimDailyReward(for: hero, gemService: gemService, soundManager: sound)
        #expect(gemsAwarded == 5)

        let postStatus = dailyService.checkDailyLoginStatus(heroProfileRecordName: hero.id.recordName)
        #expect(postStatus == .claimedToday)

        let balance = try gemService.balance(for: hero.id.recordName, familyRecordName: family.id.recordName)
        #expect(balance == 5)

        #expect(appState.currentProfile?.dailyLoginLastClaimDay != nil)
        #expect(appState.currentProfile?.gems == 5)

        // Second claim attempt must return 0 and leave balance at 5.
        let secondClaim = try await dailyService.claimDailyReward(for: hero, gemService: gemService, soundManager: sound)
        #expect(secondClaim == 0)
        let secondBalance = try gemService.balance(for: hero.id.recordName, familyRecordName: family.id.recordName)
        #expect(secondBalance == 5)
    }

    @Test
    func `checkDailyLoginStatus recognizes existing gem ledger in cache when profile lastClaim is stale`() async throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let fixture = try makeFixture(calendar: cal)
        let hero = fixture.hero
        let cache = fixture.cache
        let dailyService = fixture.dailyService
        let gemService = fixture.gemService
        let sound = fixture.sound
        let zoneID = fixture.zoneID

        var updatedHero = hero
        updatedHero.dailyLoginLastClaimDay = nil // Profile has no claim date recorded.
        cache.upsertProfile(updatedHero)
        fixture.appState.currentProfile = updatedHero

        // Seed an existing ledger for today's daily login event in the cache.
        let today = dateString(for: Date(), calendar: cal)
        let ledgerID = GemLedger.deterministicRecordID(
            profileRecordName: hero.id.recordName,
            eventKey: "daily-\(today)",
            source: "dailyLogin",
            zoneID: zoneID
        )
        let existingLedger = GemLedger(
            profileRecordName: hero.id.recordName,
            family: hero.family,
            amount: 5,
            source: "dailyLogin",
            sourceDetail: "Day 1 reward",
            createdAt: Date(),
            id: ledgerID
        )
        cache.upsertGemLedger(existingLedger)

        // Even though profile.dailyLoginLastClaimDay is nil, the ledger created today proves it was claimed.
        let status = dailyService.checkDailyLoginStatus(heroProfileRecordName: hero.id.recordName)
        #expect(status == .claimedToday)

        // Calling claimDailyReward must return 0 and reconcile profile without duplicate minting.
        let gemsAwarded = try await dailyService.claimDailyReward(for: updatedHero, gemService: gemService, soundManager: sound)
        #expect(gemsAwarded == 0)
    }

    @Test
    func `checkDailyLoginStatus returns available on Day 2 after claiming on Day 1 yesterday`() async throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let fixture = try makeFixture(calendar: cal)
        let hero = fixture.hero
        let cache = fixture.cache
        let appState = fixture.appState
        let dailyService = fixture.dailyService
        let gemService = fixture.gemService
        let sound = fixture.sound

        let yesterday = try #require(cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date())))
        let yesterdayStr = dateString(for: yesterday, calendar: cal)

        var day1Hero = hero
        day1Hero.dailyLoginLastClaimDay = yesterdayStr
        day1Hero.dailyLoginCycleDay = 2
        day1Hero.dailyLoginStreakDays = 1
        day1Hero.gems = 5
        cache.upsertProfile(day1Hero)
        appState.currentProfile = day1Hero

        let status = dailyService.checkDailyLoginStatus(heroProfileRecordName: day1Hero.id.recordName)
        #expect(status == .available)

        // Claiming Day 2 reward awards 10 gems and advances streak to 2, cycle to 3
        let gemsAwarded = try await dailyService.claimDailyReward(for: day1Hero, gemService: gemService, soundManager: sound)
        #expect(gemsAwarded == 10)

        let postStatus = dailyService.checkDailyLoginStatus(heroProfileRecordName: day1Hero.id.recordName)
        #expect(postStatus == .claimedToday)
        #expect(appState.currentProfile?.dailyLoginCycleDay == 3)
        #expect(appState.currentProfile?.dailyLoginStreakDays == 2)
    }

    @Test
    func `checkDailyLoginStatus self-heals legacy UTC claim created on previous calendar day`() async throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let fixture = try makeFixture(calendar: cal)
        let hero = fixture.hero
        let cache = fixture.cache
        let appState = fixture.appState
        let dailyService = fixture.dailyService
        let gemService = fixture.gemService
        let sound = fixture.sound
        let zoneID = fixture.zoneID

        let today = dateString(for: Date(), calendar: cal)
        let yesterdayDate = try #require(cal.date(byAdding: .day, value: -1, to: Date()))

        // Seed a legacy ledger that has today's date key but was actually created yesterday
        let legacyLedgerID = GemLedger.deterministicRecordID(
            profileRecordName: hero.id.recordName,
            eventKey: "daily-\(today)",
            source: "dailyLogin",
            zoneID: zoneID
        )
        let legacyLedger = GemLedger(
            profileRecordName: hero.id.recordName,
            family: hero.family,
            amount: 5,
            source: "dailyLogin",
            sourceDetail: "Day 1 reward",
            createdAt: yesterdayDate,
            id: legacyLedgerID
        )
        cache.upsertGemLedger(legacyLedger)

        var day1Hero = hero
        day1Hero.dailyLoginLastClaimDay = today // Mismatched legacy claim date
        day1Hero.dailyLoginCycleDay = 2
        day1Hero.dailyLoginStreakDays = 1
        day1Hero.gems = 5
        cache.upsertProfile(day1Hero)
        appState.currentProfile = day1Hero

        // Self-healing detects the ledger createdAt was prior to today, returning .available
        let status = dailyService.checkDailyLoginStatus(heroProfileRecordName: day1Hero.id.recordName)
        #expect(status == .available)

        // Claiming successfully awards Day 2 gems without duplicate key collision
        let gemsAwarded = try await dailyService.claimDailyReward(for: day1Hero, gemService: gemService, soundManager: sound)
        #expect(gemsAwarded == 10)
        #expect(dailyService.checkDailyLoginStatus(heroProfileRecordName: day1Hero.id.recordName) == .claimedToday)
        #expect(appState.currentProfile?.dailyLoginCycleDay == 3)
        #expect(appState.currentProfile?.dailyLoginStreakDays == 2)

        // Subsequent claim attempt on the same day must return 0 and stay on Day 3
        let secondClaim = try await dailyService.claimDailyReward(for: day1Hero, gemService: gemService, soundManager: sound)
        #expect(secondClaim == 0)
        #expect(appState.currentProfile?.dailyLoginCycleDay == 3)
        #expect(appState.currentProfile?.dailyLoginStreakDays == 2)
    }

    @Test
    func `checkDailyLoginStatus returns streakBroken when a calendar day is skipped`() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let fixture = try makeFixture(calendar: cal)
        let hero = fixture.hero
        let cache = fixture.cache
        let appState = fixture.appState
        let dailyService = fixture.dailyService

        let twoDaysAgo = try #require(cal.date(byAdding: .day, value: -2, to: cal.startOfDay(for: Date())))
        let twoDaysAgoStr = dateString(for: twoDaysAgo, calendar: cal)

        var skippedHero = hero
        skippedHero.dailyLoginLastClaimDay = twoDaysAgoStr
        skippedHero.dailyLoginCycleDay = 3
        skippedHero.dailyLoginStreakDays = 2
        cache.upsertProfile(skippedHero)
        appState.currentProfile = skippedHero

        let status = dailyService.checkDailyLoginStatus(heroProfileRecordName: skippedHero.id.recordName)
        #expect(status == .streakBroken)
    }

    @Test
    func `claimDailyReward consumes streakShield on broken streak`() async throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let fixture = try makeFixture(calendar: cal)
        let hero = fixture.hero
        let cache = fixture.cache
        let appState = fixture.appState
        let dailyService = fixture.dailyService
        let gemService = fixture.gemService
        let sound = fixture.sound

        let twoDaysAgo = try #require(cal.date(byAdding: .day, value: -2, to: cal.startOfDay(for: Date())))
        let twoDaysAgoStr = dateString(for: twoDaysAgo, calendar: cal)

        var shieldedHero = hero
        shieldedHero.dailyLoginLastClaimDay = twoDaysAgoStr
        shieldedHero.dailyLoginCycleDay = 4
        shieldedHero.dailyLoginStreakDays = 3
        shieldedHero.streakShields = 1
        cache.upsertProfile(shieldedHero)
        appState.currentProfile = shieldedHero

        let status = dailyService.checkDailyLoginStatus(heroProfileRecordName: shieldedHero.id.recordName)
        #expect(status == .streakBroken)

        let gemsAwarded = try await dailyService.claimDailyReward(for: shieldedHero, gemService: gemService, soundManager: sound)
        #expect(gemsAwarded == 20) // Day 4 reward preserved by shield
        #expect(appState.currentProfile?.streakShields == 0) // Shield consumed
        #expect(appState.currentProfile?.dailyLoginCycleDay == 5)
        #expect(appState.currentProfile?.dailyLoginStreakDays == 4)
    }

    @Test
    func `claimDailyReward resets cycle and streak on broken streak when shields are 0`() async throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let fixture = try makeFixture(calendar: cal)
        let hero = fixture.hero
        let cache = fixture.cache
        let appState = fixture.appState
        let dailyService = fixture.dailyService
        let gemService = fixture.gemService
        let sound = fixture.sound

        let twoDaysAgo = try #require(cal.date(byAdding: .day, value: -2, to: cal.startOfDay(for: Date())))
        let twoDaysAgoStr = dateString(for: twoDaysAgo, calendar: cal)

        var unshieldedHero = hero
        unshieldedHero.dailyLoginLastClaimDay = twoDaysAgoStr
        unshieldedHero.dailyLoginCycleDay = 4
        unshieldedHero.dailyLoginStreakDays = 3
        unshieldedHero.streakShields = 0
        cache.upsertProfile(unshieldedHero)
        appState.currentProfile = unshieldedHero

        let status = dailyService.checkDailyLoginStatus(heroProfileRecordName: unshieldedHero.id.recordName)
        #expect(status == .streakBroken)

        let gemsAwarded = try await dailyService.claimDailyReward(for: unshieldedHero, gemService: gemService, soundManager: sound)
        #expect(gemsAwarded == 5) // Reset to Day 1 reward
        #expect(appState.currentProfile?.dailyLoginCycleDay == 2)
        #expect(appState.currentProfile?.dailyLoginStreakDays == 1)
    }

    @Test
    func `claimDailyReward wraps cycle from Day 7 to Day 1 and awards streak shield`() async throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let fixture = try makeFixture(calendar: cal)
        let hero = fixture.hero
        let cache = fixture.cache
        let appState = fixture.appState
        let dailyService = fixture.dailyService
        let gemService = fixture.gemService
        let sound = fixture.sound

        let yesterday = try #require(cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date())))
        let yesterdayStr = dateString(for: yesterday, calendar: cal)

        var day7Hero = hero
        day7Hero.dailyLoginLastClaimDay = yesterdayStr
        day7Hero.dailyLoginCycleDay = 7
        day7Hero.dailyLoginStreakDays = 6
        day7Hero.streakShields = 0
        cache.upsertProfile(day7Hero)
        appState.currentProfile = day7Hero

        let gemsAwarded = try await dailyService.claimDailyReward(for: day7Hero, gemService: gemService, soundManager: sound)
        #expect(gemsAwarded == 50) // Day 7 reward
        #expect(appState.currentProfile?.dailyLoginCycleDay == 1) // Wraps around to 1
        #expect(appState.currentProfile?.dailyLoginStreakDays == 7) // Reaches multiple of 7
        #expect(appState.currentProfile?.streakShields == 1) // Earned 1 streak shield
    }
}

//
//  TrophyRoomViewModelTests.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

@MainActor
struct TrophyRoomViewModelTests {
    @Test
    func `latestEarnedTrophyName resolves via canonical key for both legacy and current shapes`() {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
        let appState = AppState()
        let familyID = CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        let family = Family(name: "G", createdBy: CKRecord.ID(recordName: "parent1", zoneID: zoneID), id: familyID)
        let familyRef = CKRecord.Reference(recordID: familyID, action: .none)
        let heroID = CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        let hero = Profile(displayName: "H", role: .hero, iCloudUserID: CKRecord.ID(recordName: "u1", zoneID: zoneID), family: familyRef, id: heroID)
        appState.currentProfile = hero
        appState.family = family
        let vm = TrophyRoomViewModel(
            achievementService: AchievementService(cloudKit: cloudKit, appState: appState),
            xpService: XPService(cloudKit: cloudKit, appState: appState),
            appState: appState
        )
        let ach = Achievement(
            id: CKRecord.ID(recordName: "fam1-\(AchievementRequirement.firstQuest.rawValue)", zoneID: zoneID),
            name: "First Steps", description: "d", iconSystemName: "s",
            category: .quest, requirementType: .firstQuest, requirementValue: 1,
            family: familyRef
        )
        let cache = AchievementCache(from: ach)
        let legacy = ProfileAchievementCache(
            recordName: "pa-legacy", achievementRecordName: AchievementRequirement.firstQuest.rawValue,
            profileRecordName: hero.id.recordName, familyRecordName: family.id.recordName,
            earnedDate: Date(timeIntervalSince1970: 1000)
        )
        vm.rebuildLists(earned: [legacy], allAchievements: [cache])
        #expect(vm.latestEarnedTrophyName == "First Steps")
        let current = ProfileAchievementCache(
            recordName: "pa-cur", achievementRecordName: "fam1-\(AchievementRequirement.firstQuest.rawValue)",
            profileRecordName: hero.id.recordName, familyRecordName: family.id.recordName,
            earnedDate: Date(timeIntervalSince1970: 2000)
        )
        vm.rebuildLists(earned: [current], allAchievements: [cache])
        #expect(vm.latestEarnedTrophyName == "First Steps")
        vm.rebuildLists(earned: [legacy, current], allAchievements: [cache])
        #expect(vm.latestEarnedTrophyName == "First Steps")
    }
}

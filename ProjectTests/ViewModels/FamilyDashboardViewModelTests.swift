//
//  FamilyDashboardViewModelTests.swift
//  LootList
//
//  Created by Ben Mackin on 7/25/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

// MARK: - Mock

@MainActor
private final class MockFamilyProfileFetcher: FamilyProfileFetching {
    private(set) var fetchCallCount = 0

    func fetchAllProfilesForFamily(_: Family) async throws -> [Profile] {
        fetchCallCount += 1
        return []
    }
}

// MARK: - Tests

@MainActor
struct FamilyDashboardViewModelTests {
    // MARK: - Helpers

    private struct SUT {
        let vm: FamilyDashboardViewModel
        let fetcher: MockFamilyProfileFetcher
        let coordinator: AppSyncCoordinator
    }

    private func makeSUT(
        fetcher: MockFamilyProfileFetcher = MockFamilyProfileFetcher(),
        family: Family? = Family(
            name: "Test Family",
            createdBy: CKRecord.ID(recordName: "owner1")
        )
    ) -> SUT {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = CloudKitService(zoneID: zoneID)
        let xpService = XPService(cloudKit: cloudKit)
        let questService = QuestService(cloudKit: cloudKit, xpService: xpService)
        let treasury = TreasuryService(cloudKit: cloudKit)
        let achievementService = AchievementService(cloudKit: cloudKit)
        let appState = AppState()
        appState.family = family

        let vm = FamilyDashboardViewModel(
            questService: questService,
            treasury: treasury,
            achievementService: achievementService,
            familyService: fetcher,
            appState: appState
        )
        let coordinator = AppSyncCoordinator()
        return SUT(vm: vm, fetcher: fetcher, coordinator: coordinator)
    }

    // MARK: - Debounce tests

    @Test
    func `rapid recordChanged events trigger at most one fetch`() async {
        let sut = makeSUT()
        sut.vm.subscribeToSyncEvents(sut.coordinator)

        for index in 0 ..< 5 {
            sut.coordinator.handleDatabaseChange(subscriptionID: "test-sub-\(index)")
        }

        await Task.yield()
        try? await Task.sleep(for: .milliseconds(500))

        #expect(sut.fetcher.fetchCallCount <= 1)

        sut.vm.unsubscribeFromSyncEvents(sut.coordinator)
    }

    @Test
    func `recordChanged does nothing when no family is set`() async {
        let sut = makeSUT(family: nil)
        sut.vm.subscribeToSyncEvents(sut.coordinator)

        sut.coordinator.handleDatabaseChange(subscriptionID: "test-sub")

        await Task.yield()
        try? await Task.sleep(for: .milliseconds(500))

        #expect(sut.fetcher.fetchCallCount == 0)

        sut.vm.unsubscribeFromSyncEvents(sut.coordinator)
    }

    @Test
    func `no retry loop or display name heuristic exists`() {
        let sut = makeSUT()
        let mirror = Mirror(reflecting: sut.vm)
        let propertyNames = mirror.children.compactMap(\.label)

        #expect(!propertyNames.contains("lastHeroDisplayNames"))
        #expect(!propertyNames.contains("scheduleLatePropagationRetry"))
    }

    @Test
    func `zoneReset does not trigger debounced fetch`() async {
        let sut = makeSUT()
        sut.vm.subscribeToSyncEvents(sut.coordinator)

        sut.coordinator.notifyZoneReset()

        await Task.yield()
        // does not touch it, so fetchCallCount stays at 0.
        #expect(sut.fetcher.fetchCallCount == 0)

        sut.vm.unsubscribeFromSyncEvents(sut.coordinator)
    }

    @Test
    func `rebuildLists derives streak and trophies from cache arrays`() throws {
        let sut = makeSUT()
        let calendar = Calendar.iso8601UTC
        let today = calendar.startOfDay(for: Date())
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: today))
        let currentWeek = WeekMath.weekOf(date: Date())
        let familyName = "TestFamily"

        let hero = ProfileCache(
            recordName: "hero1",
            familyRecordName: familyName,
            displayName: "Test Hero",
            role: "hero",
            xpTotal: 100,
            avatarName: nil,
            customAvatarImageData: nil,
            isActive: true,
            level: 5,
            iCloudUserRecordName: "u1",
            avatarClass: nil,
            payoutPolicy: "standard"
        )

        let logToday = QuestCompletionCache(
            recordName: "log_today",
            questRecordName: "quest1",
            familyRecordName: familyName,
            completerRecordName: "hero1",
            completedDate: today,
            weekOf: currentWeek,
            verificationStatus: VerificationStatus.autoApproved.rawValue,
            approvalMode: ApprovalMode.autoApprove.rawValue,
            verifiedByRecordName: nil,
            verifiedDate: nil
        )
        let logYesterday = QuestCompletionCache(
            recordName: "log_yesterday",
            questRecordName: "quest2",
            familyRecordName: familyName,
            completerRecordName: "hero1",
            completedDate: yesterday,
            weekOf: currentWeek,
            verificationStatus: VerificationStatus.verified.rawValue,
            approvalMode: ApprovalMode.parentVerify.rawValue,
            verifiedByRecordName: "parent1",
            verifiedDate: yesterday
        )

        let trophy1 = ProfileAchievementCache(
            recordName: "trophy1",
            achievementRecordName: "ach1",
            profileRecordName: "hero1",
            familyRecordName: familyName,
            earnedDate: today
        )
        let trophy2 = ProfileAchievementCache(
            recordName: "trophy2",
            achievementRecordName: "ach2",
            profileRecordName: "hero1",
            familyRecordName: familyName,
            earnedDate: yesterday
        )

        sut.vm.rebuildLists(
            profiles: [hero],
            quests: [],
            logs: [logToday, logYesterday],
            ledgers: [],
            allowancePeriods: [],
            profileAchievements: [trophy1, trophy2],
            achievements: []
        )

        let summary = try #require(sut.vm.weekSummary?.heroSummaries.first)
        #expect(summary.currentStreak == 2)
        #expect(summary.trophiesEarned == 2)
    }
}

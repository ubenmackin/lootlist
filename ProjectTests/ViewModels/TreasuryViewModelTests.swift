//
//  TreasuryViewModelTests.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

@MainActor
struct TreasuryViewModelTests {
    @Test
    func `logging spending with empty description fails validation`() async throws {
        let state = makeAppState()
        let viewModel = try makeTreasuryViewModel(state)

        let success = await viewModel.logSpending(description: "   ", amount: 10.0)
        #expect(success == false)
        #expect(viewModel.errorMessage == "Describe your spending first.")
    }

    @Test
    func `logging spending with negative or zero amount fails validation`() async throws {
        let state = makeAppState()
        let viewModel = try makeTreasuryViewModel(state)

        let successNegative = await viewModel.logSpending(description: "Spellbook", amount: -5.0)
        #expect(successNegative == false)
        #expect(viewModel.errorMessage == "Enter a positive amount.")

        let successZero = await viewModel.logSpending(description: "Potion", amount: 0)
        #expect(successZero == false)
        #expect(viewModel.errorMessage == "Enter a positive amount.")
    }

    private struct TestAppState {
        let appState: AppState
        let zoneID: CKRecordZone.ID
        let profileName: String
    }

    private func makeAppState() -> TestAppState {
        makeAppState(familyPayoutDay: .sunday, profilePayoutDay: nil)
    }

    private func makeAppState(familyPayoutDay: PayoutDay, profilePayoutDay: PayoutDay? = nil) -> TestAppState {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let familyRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID),
            action: .none
        )
        let profile = Profile(
            displayName: "Test Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "u1", zoneID: zoneID),
            family: familyRef,
            payoutPolicy: .perQuest,
            payoutDay: profilePayoutDay,
            id: CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        )
        let appState = AppState()
        appState.currentProfile = profile
        appState.family = Family(
            name: "Test Family",
            createdBy: CKRecord.ID(recordName: "u1", zoneID: zoneID),
            payoutPolicy: .perQuest,
            payoutDay: familyPayoutDay,
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )
        appState.familyZoneID = zoneID
        return TestAppState(appState: appState, zoneID: zoneID, profileName: "hero1")
    }

    @Test
    func `rebuildLists reflects allowance period status flip without cloudkit fetch`() throws {
        let state = makeAppState()
        let viewModel = try makeTreasuryViewModel(state)

        let currentWeek = WeekMath.weekOf(date: Date())

        let pendingPeriod = AllowancePeriodCache(
            recordName: "per_1",
            profileRecordName: state.profileName,
            familyRecordName: "fam1",
            weekOf: currentWeek,
            status: PayoutStatus.payoutPending.rawValue,
            totalEarned: 25.0,
            questsCompleted: 3,
            questsTotal: 4,
            paidDate: nil,
            paidAmount: nil
        )

        viewModel.rebuildLists(
            logs: [], ledgers: [], quests: [],
            allowancePeriods: [pendingPeriod],
            scope: .thisWeek
        )

        #expect(viewModel.weeklyBreakdown?.payoutStatus == .payoutPending)
        #expect(viewModel.weeklyBreakdown?.paidAmount == nil)
        #expect(viewModel.allowancePeriod?.status == .payoutPending)

        let paidPeriod = AllowancePeriodCache(
            recordName: "per_1",
            profileRecordName: state.profileName,
            familyRecordName: "fam1",
            weekOf: currentWeek,
            status: PayoutStatus.paid.rawValue,
            totalEarned: 25.0,
            questsCompleted: 3,
            questsTotal: 4,
            paidDate: Date(),
            paidAmount: 25.0
        )

        viewModel.rebuildLists(
            logs: [], ledgers: [], quests: [],
            allowancePeriods: [paidPeriod],
            scope: .thisWeek
        )

        #expect(viewModel.weeklyBreakdown?.payoutStatus == .paid)
        #expect(viewModel.weeklyBreakdown?.paidAmount == 25.0)
        #expect(viewModel.allowancePeriod?.status == .paid)
        #expect(viewModel.allowancePeriod?.paidAmount == 25.0)
    }

    @Test
    func `rebuildLists scopes allowance period to current profile and week`() throws {
        let state = makeAppState()
        let viewModel = try makeTreasuryViewModel(state)

        let currentWeek = WeekMath.weekOf(date: Date())
        let lastWeek = WeekMath.weekOf(date: Date().addingTimeInterval(-7 * 24 * 3600))

        let otherProfilePeriod = AllowancePeriodCache(
            recordName: "per_other", profileRecordName: "other_hero",
            familyRecordName: "fam1", weekOf: currentWeek,
            status: PayoutStatus.paid.rawValue, totalEarned: 99,
            questsCompleted: 5, questsTotal: 5, paidDate: Date(), paidAmount: 99
        )
        let staleWeekPeriod = AllowancePeriodCache(
            recordName: "per_stale", profileRecordName: state.profileName,
            familyRecordName: "fam1", weekOf: lastWeek,
            status: PayoutStatus.paid.rawValue, totalEarned: 50,
            questsCompleted: 5, questsTotal: 5, paidDate: Date(), paidAmount: 50
        )
        let currentPeriod = AllowancePeriodCache(
            recordName: "per_current", profileRecordName: state.profileName,
            familyRecordName: "fam1", weekOf: currentWeek,
            status: PayoutStatus.active.rawValue, totalEarned: 10,
            questsCompleted: 1, questsTotal: 4
        )

        viewModel.rebuildLists(
            logs: [], ledgers: [], quests: [],
            allowancePeriods: [otherProfilePeriod, staleWeekPeriod, currentPeriod],
            scope: .thisWeek
        )

        #expect(viewModel.weeklyBreakdown?.payoutStatus == .active)
        #expect(viewModel.weeklyBreakdown?.paidAmount == nil)
        #expect(viewModel.allowancePeriod?.status == .active)
    }

    @Test
    func `rebuildLists filters spending log: this week scope`() throws {
        let state = makeAppState()
        let viewModel = try makeTreasuryViewModel(state)
        let fixtures = scopedLedgerFixtures()
        let (quest, log) = questAndLogFixtures(state: state)

        viewModel.rebuildLists(
            logs: [log], ledgers: fixtures, quests: [quest], allowancePeriods: [],
            scope: .thisWeek
        )

        let expected = fixtures
            .filter { CalendarScope.thisWeek.contains($0.date) }
            .sorted { $0.date > $1.date }
            .map(\.recordName)
        #expect(viewModel.spendingLog.map(\.id) == expected)
        #expect(expected.contains("l_today"))
        #expect(!expected.contains("l_year"))
    }

    @Test
    func `rebuildLists filters spending log: this month scope`() throws {
        let state = makeAppState()
        let viewModel = try makeTreasuryViewModel(state)
        let fixtures = scopedLedgerFixtures()
        let (quest, log) = questAndLogFixtures(state: state)

        viewModel.rebuildLists(
            logs: [log], ledgers: fixtures, quests: [quest], allowancePeriods: [],
            scope: .thisMonth
        )

        let expected = fixtures
            .filter { CalendarScope.thisMonth.contains($0.date) }
            .sorted { $0.date > $1.date }
            .map(\.recordName)
        #expect(viewModel.spendingLog.map(\.id) == expected)
        #expect(expected.contains("l_today"))
        #expect(!expected.contains("l_year"))
    }

    @Test
    func `rebuildLists filters spending log: this quarter scope`() throws {
        let state = makeAppState()
        let viewModel = try makeTreasuryViewModel(state)
        let fixtures = scopedLedgerFixtures()
        let (quest, log) = questAndLogFixtures(state: state)

        viewModel.rebuildLists(
            logs: [log], ledgers: fixtures, quests: [quest], allowancePeriods: [],
            scope: .thisQuarter
        )

        let expected = fixtures
            .filter { CalendarScope.thisQuarter.contains($0.date) }
            .sorted { $0.date > $1.date }
            .map(\.recordName)
        #expect(viewModel.spendingLog.map(\.id) == expected)
        #expect(expected.contains("l_today"))
        #expect(!expected.contains("l_year"))
    }

    @Test
    func `rebuildLists filters spending log: all time scope`() throws {
        let state = makeAppState()
        let viewModel = try makeTreasuryViewModel(state)
        let fixtures = scopedLedgerFixtures()
        let (quest, log) = questAndLogFixtures(state: state)

        viewModel.rebuildLists(
            logs: [log], ledgers: fixtures, quests: [quest], allowancePeriods: [],
            scope: .allTime
        )

        let expectedRecordNames = fixtures.map(\.recordName)
        #expect(viewModel.spendingLog.map(\.id).sorted() == expectedRecordNames.sorted())
        #expect(expectedRecordNames.count == 5)
    }

    @Test
    func `thisWeek contains friday-anchored cycle but sunday drops gap entries`() {
        let day: TimeInterval = 24 * 3600
        let fridayRange = CalendarScope.thisWeek.dateRange(payoutDay: .friday)
        let sundayRange = CalendarScope.thisWeek.dateRange(payoutDay: .sunday)
        let fridayStart = fridayRange.lowerBound
        let gapDay = !sundayRange.contains(fridayRange.lowerBound) ? fridayRange.lowerBound : fridayRange.upperBound

        #expect(gapDay >= fridayStart)
        #expect(CalendarScope.thisWeek.contains(gapDay, payoutDay: .friday))
        #expect(!CalendarScope.thisWeek.contains(gapDay, payoutDay: .sunday))

        #expect(CalendarScope.thisWeek.contains(fridayStart.addingTimeInterval(day), payoutDay: .friday))
        #expect(CalendarScope.thisWeek.contains(fridayStart.addingTimeInterval(3 * day), payoutDay: .friday))
        #expect(CalendarScope.thisWeek.contains(fridayStart.addingTimeInterval(6 * day), payoutDay: .friday))

        #expect(!CalendarScope.thisWeek.contains(fridayStart.addingTimeInterval(-day), payoutDay: .friday))
        #expect(!CalendarScope.thisWeek.contains(fridayStart.addingTimeInterval(-7 * day), payoutDay: .friday))
        #expect(!CalendarScope.thisWeek.contains(fridayStart.addingTimeInterval(-30 * day), payoutDay: .friday))
        #expect(!CalendarScope.thisWeek.contains(fridayStart.addingTimeInterval(-91 * day), payoutDay: .friday))
        #expect(!CalendarScope.thisWeek.contains(fridayStart.addingTimeInterval(-365 * day), payoutDay: .friday))
    }

    @Test
    func `dateRange and dateRangeSublabel anchor thisWeek on payoutDay but ignore it otherwise`() {
        let fridayStart = WeekMath.startOfWeek(for: Date(), payoutDay: .friday)
        let fridayRange = CalendarScope.thisWeek.dateRange(payoutDay: .friday)
        let sundayRange = CalendarScope.thisWeek.dateRange(payoutDay: .sunday)

        #expect(fridayRange.lowerBound == fridayStart)
        #expect(fridayRange.upperBound == fridayStart.addingTimeInterval(TimeInterval(AppConstants.Time.secondsInWeek - 1)))
        #expect(fridayRange != sundayRange)

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        #expect(
            CalendarScope.thisWeek.dateRangeSublabel(payoutDay: .friday)
                == "\(formatter.string(from: fridayRange.lowerBound)) – \(formatter.string(from: fridayRange.upperBound))"
        )

        #expect(CalendarScope.thisMonth.dateRange(payoutDay: .friday) == CalendarScope.thisMonth.dateRange(payoutDay: .sunday))
        #expect(CalendarScope.thisQuarter.dateRange(payoutDay: .friday) == CalendarScope.thisQuarter.dateRange(payoutDay: .sunday))
        let now = Date()
        let allTimeFriday = CalendarScope.allTime.dateRange(payoutDay: .friday)
        let allTimeSunday = CalendarScope.allTime.dateRange(payoutDay: .sunday)
        #expect(allTimeFriday.lowerBound == .distantPast)
        #expect(allTimeSunday.lowerBound == .distantPast)
        #expect(allTimeFriday.contains(now))
        #expect(allTimeSunday.contains(now))
        #expect(CalendarScope.thisMonth.dateRangeSublabel(payoutDay: .friday) == CalendarScope.thisMonth.dateRangeSublabel(payoutDay: .sunday))
        #expect(CalendarScope.thisQuarter.dateRangeSublabel(payoutDay: .friday) == CalendarScope.thisQuarter.dateRangeSublabel(payoutDay: .sunday))
        #expect(CalendarScope.allTime.dateRangeSublabel(payoutDay: .friday) == CalendarScope.allTime.dateRangeSublabel(payoutDay: .sunday))
    }

    @Test
    func `rebuildLists keeps early-cycle ledger in thisWeek for friday payout but drops it for sunday default`() throws {
        let fridayRange = CalendarScope.thisWeek.dateRange(payoutDay: .friday)
        let sundayRange = CalendarScope.thisWeek.dateRange(payoutDay: .sunday)
        let gapDate = !sundayRange.contains(fridayRange.lowerBound) ? fridayRange.lowerBound : fridayRange.upperBound

        let gapLedger = LedgerEntryCache(
            recordName: "l_gap", profileRecordName: "hero1", familyRecordName: "fam1",
            amount: -7, entryDescription: "Early Cycle", location: nil,
            date: gapDate, source: "manual"
        )
        let todayLedger = LedgerEntryCache(
            recordName: "l_today", profileRecordName: "hero1", familyRecordName: "fam1",
            amount: -1, entryDescription: "Today", location: nil,
            date: Date(), source: "manual"
        )

        let fridayState = makeAppState(familyPayoutDay: .friday)
        let fridayVM = try makeTreasuryViewModel(fridayState)
        fridayVM.rebuildLists(
            logs: [], ledgers: [gapLedger, todayLedger], quests: [],
            allowancePeriods: [], scope: .thisWeek
        )
        #expect(fridayVM.spendingLog.map(\.id).contains("l_gap"))

        let sundayState = makeAppState(familyPayoutDay: .sunday)
        let sundayVM = try makeTreasuryViewModel(sundayState)
        sundayVM.rebuildLists(
            logs: [], ledgers: [gapLedger, todayLedger], quests: [],
            allowancePeriods: [], scope: .thisWeek
        )
        #expect(!sundayVM.spendingLog.map(\.id).contains("l_gap"))
    }

    @Test
    func `rebuildLists per-profile payoutDay overrides family for thisWeek`() throws {
        let fridayRange = CalendarScope.thisWeek.dateRange(payoutDay: .friday)
        let sundayRange = CalendarScope.thisWeek.dateRange(payoutDay: .sunday)
        let gapDate = !sundayRange.contains(fridayRange.lowerBound) ? fridayRange.lowerBound : fridayRange.upperBound

        let gapLedger = LedgerEntryCache(
            recordName: "l_gap", profileRecordName: "hero1", familyRecordName: "fam1",
            amount: -7, entryDescription: "Early Cycle", location: nil,
            date: gapDate, source: "manual"
        )
        let todayLedger = LedgerEntryCache(
            recordName: "l_today", profileRecordName: "hero1", familyRecordName: "fam1",
            amount: -1, entryDescription: "Today", location: nil,
            date: Date(), source: "manual"
        )

        let overrideState = makeAppState(familyPayoutDay: .sunday, profilePayoutDay: .friday)
        let overrideVM = try makeTreasuryViewModel(overrideState)
        overrideVM.rebuildLists(
            logs: [], ledgers: [gapLedger, todayLedger], quests: [],
            allowancePeriods: [], scope: .thisWeek
        )
        #expect(overrideVM.spendingLog.map(\.id).contains("l_gap"))
    }

    @Test
    func `rebuildSpendingLog keeps early-cycle ledger for friday payout but drops it for sunday default`() throws {
        let fridayRange = CalendarScope.thisWeek.dateRange(payoutDay: .friday)
        let sundayRange = CalendarScope.thisWeek.dateRange(payoutDay: .sunday)
        let gapDate = !sundayRange.contains(fridayRange.lowerBound) ? fridayRange.lowerBound : fridayRange.upperBound

        let gapLedger = LedgerEntryCache(
            recordName: "l_gap", profileRecordName: "hero1", familyRecordName: "fam1",
            amount: -7, entryDescription: "Early Cycle", location: nil,
            date: gapDate, source: "manual"
        )
        let todayLedger = LedgerEntryCache(
            recordName: "l_today", profileRecordName: "hero1", familyRecordName: "fam1",
            amount: -1, entryDescription: "Today", location: nil,
            date: Date(), source: "manual"
        )

        let fridayState = makeAppState(familyPayoutDay: .friday)
        let fridayVM = try makeTreasuryViewModel(fridayState)
        fridayVM.rebuildSpendingLog(from: [gapLedger, todayLedger], scope: .thisWeek)
        #expect(fridayVM.spendingLog.map(\.id).contains("l_gap"))

        let sundayState = makeAppState(familyPayoutDay: .sunday)
        let sundayVM = try makeTreasuryViewModel(sundayState)
        sundayVM.rebuildSpendingLog(from: [gapLedger, todayLedger], scope: .thisWeek)
        #expect(!sundayVM.spendingLog.map(\.id).contains("l_gap"))
    }

    private func makeTreasuryViewModel(_ state: TestAppState, cacheService: CacheService? = nil) throws -> TreasuryViewModel {
        let cloudKit = MockCloudKitService(zoneID: state.zoneID)
        let cache = try cacheService ?? CacheService(inMemory: true)
        let treasury = TreasuryService(cloudKit: cloudKit, cacheService: cache, appState: state.appState)
        let spending = SpendingService(cloudKit: cloudKit, cacheService: cache, appState: state.appState)
        return TreasuryViewModel(
            treasury: treasury, spending: spending, appState: state.appState
        )
    }

    private func scopedLedgerFixtures() -> [LedgerEntryCache] {
        let day: TimeInterval = 24 * 3600
        let now = Date()
        return [
            LedgerEntryCache(
                recordName: "l_today", profileRecordName: "hero1", familyRecordName: "fam1",
                amount: -1, entryDescription: "Today", location: nil, date: now, source: "manual"
            ),
            LedgerEntryCache(
                recordName: "l_week", profileRecordName: "hero1", familyRecordName: "fam1",
                amount: -2, entryDescription: "Last Week", location: nil,
                date: now.addingTimeInterval(-7 * day), source: "manual"
            ),
            LedgerEntryCache(
                recordName: "l_month", profileRecordName: "hero1", familyRecordName: "fam1",
                amount: -3, entryDescription: "Last Month", location: nil,
                date: now.addingTimeInterval(-30 * day), source: "manual"
            ),
            LedgerEntryCache(
                recordName: "l_quarter", profileRecordName: "hero1", familyRecordName: "fam1",
                amount: -4, entryDescription: "Last Quarter", location: nil,
                date: now.addingTimeInterval(-91 * day), source: "manual"
            ),
            LedgerEntryCache(
                recordName: "l_year", profileRecordName: "hero1", familyRecordName: "fam1",
                amount: -5, entryDescription: "Last Year", location: nil,
                date: now.addingTimeInterval(-365 * day), source: "manual"
            )
        ]
    }

    private func questAndLogFixtures(state: TestAppState) -> (quest: QuestCache, log: QuestCompletionCache) {
        let currentWeek = WeekMath.weekOf(date: Date())
        let quest = QuestCache(
            recordName: "q1", familyRecordName: "fam1", assigneeRecordName: state.profileName,
            templateRecordName: "t1", weekOf: currentWeek, questName: "Sweep the Hall",
            isActive: true, goldReward: 10, xpReward: 10, rarity: QuestRarity.common.rawValue,
            scheduleType: QuestSchedule.weeklyFlexible.rawValue, targetCount: 1,
            isAllOrNothing: false, approvalMode: ApprovalMode.autoApprove.rawValue,
            descriptionText: nil, createdByRecordName: "u1"
        )
        let log = QuestCompletionCache(
            recordName: "c1", questRecordName: "q1", familyRecordName: "fam1",
            completerRecordName: state.profileName, completedDate: Date(), weekOf: currentWeek,
            verificationStatus: VerificationStatus.verified.rawValue,
            approvalMode: ApprovalMode.autoApprove.rawValue,
            verifiedByRecordName: nil, verifiedDate: nil
        )
        return (quest, log)
    }

    @Test
    func `previousLocations extracts unique sorted locations from ledgers`() throws {
        let state = makeAppState()
        let viewModel = try makeTreasuryViewModel(state)

        let ledger1 = LedgerEntryCache(
            recordName: "l1",
            profileRecordName: "h1",
            familyRecordName: "fam1",
            amount: -5.0,
            entryDescription: "Toys",
            location: "Home Goods",
            date: Date(),
            source: "manual"
        )
        let ledger2 = LedgerEntryCache(
            recordName: "l2",
            profileRecordName: "h1",
            familyRecordName: "fam1",
            amount: -10.0,
            entryDescription: "Crafts",
            location: "Hobby Lobby",
            date: Date(),
            source: "manual"
        )
        let ledger3 = LedgerEntryCache(
            recordName: "l3",
            profileRecordName: "h1",
            familyRecordName: "fam1",
            amount: -15.0,
            entryDescription: "Tools",
            location: "Home Depot",
            date: Date(),
            source: "manual"
        )
        let ledger4 = LedgerEntryCache(
            recordName: "l4",
            profileRecordName: "h1",
            familyRecordName: "fam1",
            amount: -2.0,
            entryDescription: "More Toys",
            location: "home goods",
            date: Date(),
            source: "manual"
        )

        let locations = viewModel.previousLocations(from: [ledger1, ledger2, ledger3, ledger4])
        #expect(locations == ["Hobby Lobby", "Home Depot", "Home Goods"])
    }

    @Test
    func `logging spending passes location to spending service`() async throws {
        let state = makeAppState()
        let cacheService = try CacheService(inMemory: true)
        let viewModel = try makeTreasuryViewModel(state, cacheService: cacheService)

        let success = await viewModel.logSpending(description: "Hammer", amount: 12.50, location: "Home Depot")
        #expect(success == true)
        let cached = cacheService.fetchLedgerEntries(profileRecordName: state.profileName, family: "fam1")
        #expect(cached.count == 1)
        #expect(cached.first?.location == "Home Depot")
        #expect(cached.first?.amount == -12.50)
    }

    @Test
    func `rebuildLists recognizes allowance period with hour offset or DST variance`() throws {
        let state = makeAppState()
        let viewModel = try makeTreasuryViewModel(state)

        let currentWeek = WeekMath.startOfWeek(for: Date(), payoutDay: .sunday)
        let periodWeekOfWithOffset = currentWeek.addingTimeInterval(8 * 3600)

        let allowance = AllowancePeriodCache(
            recordName: "period-1",
            profileRecordName: state.profileName,
            familyRecordName: "fam1",
            weekOf: periodWeekOfWithOffset,
            status: PayoutStatus.paid.rawValue,
            totalEarned: 50.0,
            questsCompleted: 2,
            questsTotal: 2,
            paidDate: Date(),
            paidAmount: 50.0
        )

        viewModel.rebuildLists(logs: [], ledgers: [], quests: [], allowancePeriods: [allowance], scope: .thisWeek)

        #expect(viewModel.allowancePeriod?.status == .paid)
        #expect(viewModel.weeklyBreakdown?.payoutStatus == .paid)
        #expect(viewModel.weeklyBreakdown?.paidAmount == 50.0)
        #expect(viewModel.pendingQuestGold == 0.0)
    }

    // MARK: - Bucket Balances & Transfer Preview

    /// Scaffold for the treasury bucket-transfer flow: a self-owned hero
    /// session over an in-memory cache with a buffered (engine-less) sync
    /// coordinator, so transfers never touch the network.
    @MainActor
    private struct TransferScaffold {
        let zoneID: CKRecordZone.ID
        let appState: AppState
        let buckets: BucketService
        let cache: CacheService
        let hero: Profile
        let family: Family
        private let profileRef: CKRecord.Reference
        private let familyRef: CKRecord.Reference

        init() throws {
            zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
            let mock = MockCloudKitService(zoneID: zoneID)
            cache = try CacheService(inMemory: true)
            appState = AppState()
            hero = Profile(
                displayName: "Test Hero",
                role: .hero,
                iCloudUserID: CKRecord.ID(recordName: "u1", zoneID: zoneID),
                family: CKRecord.Reference(
                    recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none
                ),
                id: CKRecord.ID(recordName: "hero1", zoneID: zoneID)
            )
            family = Family(
                name: "Test Family",
                createdBy: CKRecord.ID(recordName: "u1", zoneID: zoneID),
                payoutDay: .sunday,
                id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
            )
            appState.currentProfile = hero
            appState.family = family
            appState.familyZoneID = zoneID
            // The engine never initializes under TestEnvironment, so enqueued
            // saves buffer in memory instead of reaching CloudKit.
            let handler = CKSyncEngineDelegateHandler(conflictResolver: CKSyncConflictResolver())
            let coordinator = CKSyncEngineCoordinator(cloudKitService: mock, delegateHandler: handler, appState: appState)
            buckets = BucketService(cacheService: cache, syncCoordinator: coordinator, appState: appState)
            profileRef = CKRecord.Reference(recordID: hero.id, action: .none)
            familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        }

        func seed(_ name: String,
                  amount: Double,
                  source: String,
                  bucketKind: String?,
                  fromBucket: String? = nil,
                  toBucket: String? = nil)
        {
            cache.context?.insert(LedgerEntryCache(from: LedgerEntry(
                profile: profileRef,
                amount: amount,
                description: name,
                source: source,
                bucketKind: bucketKind,
                fromBucket: fromBucket,
                toBucket: toBucket,
                family: familyRef,
                id: CKRecord.ID(recordName: name, zoneID: zoneID)
            )))
            _ = cache.saveContext()
        }

        func entries() -> [LedgerEntryCache] {
            cache.fetchLedgerEntries(profileRecordName: hero.id.recordName, family: family.id.recordName)
        }
    }

    @Test
    func `treasury bucket balances credit transfers to destination and debit source`() throws {
        let scaffold = try TransferScaffold()
        scaffold.seed("l-spend-in", amount: 10.00, source: "quest", bucketKind: BucketKind.spend.rawValue)
        scaffold.seed(
            "l-transfer",
            amount: 3.00,
            source: "transfer",
            bucketKind: BucketKind.shortTermSave.rawValue,
            fromBucket: BucketKind.spend.rawValue,
            toBucket: BucketKind.shortTermSave.rawValue
        )

        let balances = scaffold.buckets.bucketBalances(profileRecordName: "hero1", familyRecordName: "fam1")

        #expect(balances[.spend] == 7.00)
        #expect(balances[.shortTermSave] == 3.00)
    }

    @Test
    func `transfer preview rejects same-bucket moves before touching balances`() async throws {
        let scaffold = try TransferScaffold()
        do {
            _ = try await scaffold.buckets.transfer(
                from: .spend, to: .spend, amount: 1.0,
                profile: scaffold.hero, family: scaffold.family,
                transferID: BucketService.deterministicTransferID(
                    dayBucket: WeekMath.dayBucket(for: Date()),
                    from: .spend,
                    to: .spend
                )
            )
            Issue.record("Same-bucket transfer must throw")
        } catch {
            #expect(error as? BucketServiceError == .sameBucket)
        }
    }

    @Test
    func `transfer preview rejects zero and negative amounts`() async throws {
        let scaffold = try TransferScaffold()
        for amount in [0.0, -5.0] {
            do {
                _ = try await scaffold.buckets.transfer(
                    from: .spend, to: .shortTermSave, amount: amount,
                    profile: scaffold.hero, family: scaffold.family,
                    transferID: BucketService.deterministicTransferID(
                        dayBucket: WeekMath.dayBucket(for: Date()),
                        from: .spend,
                        to: .shortTermSave
                    )
                )
                Issue.record("Amount \(amount) must throw")
            } catch {
                #expect(error as? BucketServiceError == .invalidAmount)
            }
        }
    }

    @Test
    func `transfer preview refuses moves on behalf of another profile`() async throws {
        let scaffold = try TransferScaffold()
        scaffold.appState.currentProfile = nil
        do {
            _ = try await scaffold.buckets.transfer(
                from: .spend, to: .shortTermSave, amount: 1.0,
                profile: scaffold.hero, family: scaffold.family,
                transferID: BucketService.deterministicTransferID(
                    dayBucket: WeekMath.dayBucket(for: Date()),
                    from: .spend,
                    to: .shortTermSave
                )
            )
            Issue.record("Cross-profile transfer must throw")
        } catch {
            #expect(error as? BucketServiceError == .unauthorized)
        }
    }

    @Test
    func `transfer preview reports exact insufficient funds from the source bucket`() async throws {
        let scaffold = try TransferScaffold()
        scaffold.seed("l-spend-in", amount: 2.00, source: "quest", bucketKind: BucketKind.spend.rawValue)
        let rowsBeforePreview = scaffold.entries().count

        do {
            _ = try await scaffold.buckets.transfer(
                from: .spend, to: .shortTermSave, amount: 5.00,
                profile: scaffold.hero, family: scaffold.family,
                transferID: BucketService.deterministicTransferID(
                    dayBucket: WeekMath.dayBucket(for: Date()),
                    from: .spend,
                    to: .shortTermSave
                )
            )
            Issue.record("Overdrafting transfer must throw")
        } catch {
            #expect(error as? BucketServiceError == .insufficientFunds(available: 2.00, requested: 5.00))
        }
        // A rejected preview is strictly read-only: the ledger keeps exactly
        // the seeded funding row and gains nothing from the failed attempt.
        #expect(scaffold.entries().count == rowsBeforePreview)
    }

    @Test
    func `confirmed transfer moves balances with deterministic id and replays idempotently`() async throws {
        let scaffold = try TransferScaffold()
        scaffold.seed("l-spend-in", amount: 10.00, source: "quest", bucketKind: BucketKind.spend.rawValue)

        let unixDay = WeekMath.dayBucket(for: Date())
        let transferID = "\(unixDay)-spend-shortTermSave"
        let entry = try await scaffold.buckets.transfer(
            from: .spend, to: .shortTermSave, amount: 4.00,
            profile: scaffold.hero, family: scaffold.family,
            transferID: transferID
        )

        // Deterministic ID per (profile, day, from, to): CloudKit dedupes a
        // same-day retry across devices when transferID is supplied.
        #expect(entry.id.recordName == "transfer-hero1-\(unixDay)-spend-shortTermSave")
        #expect(entry.source == "transfer")
        #expect(entry.bucketKind == BucketKind.shortTermSave.rawValue)
        #expect(entry.fromBucket == BucketKind.spend.rawValue)
        #expect(entry.toBucket == BucketKind.shortTermSave.rawValue)

        var balances = scaffold.buckets.bucketBalances(profileRecordName: "hero1", familyRecordName: "fam1")
        #expect(balances[.spend] == 6.00)
        #expect(balances[.shortTermSave] == 4.00)
        // Two rows total: the seeded funding entry plus exactly ONE transfer
        // ledger row — the debit side is carried by fromBucket attribution,
        // never by a second row.
        #expect(scaffold.entries().count == 2)

        // Same-day duplicate must be rejected via per-day/per-pair guard.
        await #expect(throws: BucketServiceError.duplicateTodayTransfer) {
            _ = try await scaffold.buckets.transfer(
                from: .spend, to: .shortTermSave, amount: 4.00,
                profile: scaffold.hero, family: scaffold.family,
                transferID: transferID
            )
        }
        #expect(scaffold.entries().count == 2)
        balances = scaffold.buckets.bucketBalances(profileRecordName: "hero1", familyRecordName: "fam1")
        #expect(balances[.spend] == 6.00)
        #expect(balances[.shortTermSave] == 4.00)
    }

    @Test
    func `transfers without transferID are append-only with distinct records`() async throws {
        let scaffold = try TransferScaffold()
        scaffold.seed("l-spend-in", amount: 10.00, source: "quest", bucketKind: BucketKind.spend.rawValue)

        let entry1 = try await scaffold.buckets.transfer(
            from: .spend, to: .shortTermSave, amount: 2.00,
            profile: scaffold.hero, family: scaffold.family,
            transferID: BucketService.deterministicTransferID(
                dayBucket: WeekMath.dayBucket(for: Date()),
                from: .spend,
                to: .shortTermSave
            )
        )
        // WHY: Second transfer uses a different pair so the per-day/per-pair guard does not fire — nonce path stays append-only.
        let entry2 = try await scaffold.buckets.transfer(
            from: .spend, to: .longTermSave, amount: 3.00,
            profile: scaffold.hero, family: scaffold.family,
            transferID: BucketService.deterministicTransferID(
                dayBucket: WeekMath.dayBucket(for: Date()),
                from: .spend,
                to: .longTermSave
            )
        )

        #expect(entry1.id.recordName != entry2.id.recordName)
        #expect(scaffold.entries().count == 3) // 1 seed + 2 transfers
        let balances = scaffold.buckets.bucketBalances(profileRecordName: "hero1", familyRecordName: "fam1")
        #expect(balances[.spend] == 5.00)
        #expect(balances[.shortTermSave] == 2.00)
        #expect(balances[.longTermSave] == 3.00)
    }
}

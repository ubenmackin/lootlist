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
final class MockSpendingService: SpendingService {
    var transactions: [LedgerEntry] = []
    var isAvailableValue: Bool = true
    var shouldFail: Bool = false

    func isAvailable() -> Bool {
        isAvailableValue
    }

    func fetchTransactions(for _: Profile, in _: DateInterval) async throws -> [LedgerEntry] {
        if shouldFail {
            throw SpendingServiceError.underlying("Mock error")
        }
        return transactions
    }

    func logManual(profile: Profile, family: Family, familyRecordName _: String, description: String, amount: Double, location: String? = nil,
                   date: Date = Date()) async throws -> LedgerEntry
    {
        if shouldFail {
            throw SpendingServiceError.underlying("Mock error")
        }
        let entry = LedgerEntry(
            profile: CKRecord.Reference(recordID: profile.id, action: .none),
            amount: -abs(amount),
            description: description,
            location: location,
            date: date,
            source: "manual",
            family: CKRecord.Reference(recordID: family.id, action: .none)
        )
        transactions.append(entry)
        return entry
    }
}

@MainActor
struct TreasuryViewModelTests {
    @Test
    func `logging spending with empty description fails validation`() async {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService(zoneID: zoneID)
        let treasury = TreasuryService(cloudKit: cloudKit)
        let spendingMock = MockSpendingService()
        let appState = AppState()

        let viewModel = TreasuryViewModel(treasury: treasury, spending: spendingMock, appState: appState)

        let success = await viewModel.logSpending(description: "   ", amount: 10.0)
        #expect(success == false)
        #expect(viewModel.errorMessage == "Describe your spending first.")
    }

    @Test
    func `logging spending with negative or zero amount fails validation`() async {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService(zoneID: zoneID)
        let treasury = TreasuryService(cloudKit: cloudKit)
        let spendingMock = MockSpendingService()
        let appState = AppState()

        let viewModel = TreasuryViewModel(treasury: treasury, spending: spendingMock, appState: appState)

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

    /// Builds an authenticated hero state with the given effective payout-day
    /// configuration. The profile's `payoutDay` (when non-nil) overrides the
    /// family's `payoutDay`, mirroring the resolution the view model uses
    /// (`profile.payoutDay ?? appState.family?.payoutDay ?? .sunday`).
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
    func `rebuildLists reflects allowance period status flip without cloudkit fetch`() {
        let state = makeAppState()
        let cloudKit = MockCloudKitService(zoneID: state.zoneID)
        let treasury = TreasuryService(cloudKit: cloudKit)
        let spendingMock = MockSpendingService()
        let viewModel = TreasuryViewModel(
            treasury: treasury, spending: spendingMock, appState: state.appState
        )

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
    func `rebuildLists scopes allowance period to current profile and week`() {
        let state = makeAppState()
        let cloudKit = MockCloudKitService(zoneID: state.zoneID)
        let treasury = TreasuryService(cloudKit: cloudKit)
        let spendingMock = MockSpendingService()
        let viewModel = TreasuryViewModel(
            treasury: treasury, spending: spendingMock, appState: state.appState
        )

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
    func `rebuildLists filters spending log: this week scope`() {
        let state = makeAppState()
        let viewModel = makeTreasuryViewModel(state)
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
    func `rebuildLists filters spending log: this month scope`() {
        let state = makeAppState()
        let viewModel = makeTreasuryViewModel(state)
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
    func `rebuildLists filters spending log: this quarter scope`() {
        let state = makeAppState()
        let viewModel = makeTreasuryViewModel(state)
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
    func `rebuildLists filters spending log: all time scope`() {
        let state = makeAppState()
        let viewModel = makeTreasuryViewModel(state)
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

    // MARK: - CalendarScope payout-day threading

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

        // A few days inside the friday-anchored week.
        #expect(CalendarScope.thisWeek.contains(fridayStart.addingTimeInterval(day), payoutDay: .friday))
        #expect(CalendarScope.thisWeek.contains(fridayStart.addingTimeInterval(3 * day), payoutDay: .friday))
        // The payout day itself is the inclusive upper bound of the cycle.
        #expect(CalendarScope.thisWeek.contains(fridayStart.addingTimeInterval(6 * day), payoutDay: .friday))

        // Entire 1-week / 1-month / 1-quarter / 1-year spans are excluded.
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

        // The remaining scopes are calendar-based and ignore the payout day.
        #expect(CalendarScope.thisMonth.dateRange(payoutDay: .friday) == CalendarScope.thisMonth.dateRange(payoutDay: .sunday))
        #expect(CalendarScope.thisQuarter.dateRange(payoutDay: .friday) == CalendarScope.thisQuarter.dateRange(payoutDay: .sunday))
        // `allTime` spans distantPast → now regardless of payout day; compare
        // the unbounded lower bound and membership instead of the live upper bound.
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
    func `rebuildLists keeps early-cycle ledger in thisWeek for friday payout but drops it for sunday default`() {
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

        // A friday-payout family keeps the early-cycle entry in `.thisWeek`.
        let fridayState = makeAppState(familyPayoutDay: .friday)
        let fridayVM = makeTreasuryViewModel(fridayState)
        fridayVM.rebuildLists(
            logs: [], ledgers: [gapLedger, todayLedger], quests: [],
            allowancePeriods: [], scope: .thisWeek
        )
        #expect(fridayVM.spendingLog.map(\.id).contains("l_gap"))

        // The default sunday payout drops the gap entry.
        let sundayState = makeAppState(familyPayoutDay: .sunday)
        let sundayVM = makeTreasuryViewModel(sundayState)
        sundayVM.rebuildLists(
            logs: [], ledgers: [gapLedger, todayLedger], quests: [],
            allowancePeriods: [], scope: .thisWeek
        )
        #expect(!sundayVM.spendingLog.map(\.id).contains("l_gap"))
    }

    @Test
    func `rebuildLists per-profile payoutDay overrides family for thisWeek`() {
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

        // Family defaults sunday but the per-profile override is friday:
        // the override wins and the early-cycle entry stays in `.thisWeek`.
        let overrideState = makeAppState(familyPayoutDay: .sunday, profilePayoutDay: .friday)
        let overrideVM = makeTreasuryViewModel(overrideState)
        overrideVM.rebuildLists(
            logs: [], ledgers: [gapLedger, todayLedger], quests: [],
            allowancePeriods: [], scope: .thisWeek
        )
        #expect(overrideVM.spendingLog.map(\.id).contains("l_gap"))
    }

    @Test
    func `rebuildSpendingLog keeps early-cycle ledger for friday payout but drops it for sunday default`() {
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
        let fridayVM = makeTreasuryViewModel(fridayState)
        fridayVM.rebuildSpendingLog(from: [gapLedger, todayLedger], scope: .thisWeek)
        #expect(fridayVM.spendingLog.map(\.id).contains("l_gap"))

        let sundayState = makeAppState(familyPayoutDay: .sunday)
        let sundayVM = makeTreasuryViewModel(sundayState)
        sundayVM.rebuildSpendingLog(from: [gapLedger, todayLedger], scope: .thisWeek)
        #expect(!sundayVM.spendingLog.map(\.id).contains("l_gap"))
    }

    // MARK: - CalendarScope fixtures

    private func makeTreasuryViewModel(_ state: TestAppState) -> TreasuryViewModel {
        let cloudKit = MockCloudKitService(zoneID: state.zoneID)
        let treasury = TreasuryService(cloudKit: cloudKit)
        let spendingMock = MockSpendingService()
        return TreasuryViewModel(
            treasury: treasury, spending: spendingMock, appState: state.appState
        )
    }

    /// Ledgers spanning 1 day, 1 week, 1 month, 1 quarter, and 1 year back
    /// from the current date, used to exercise every `CalendarScope` case.
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

    /// A current-week quest and approved completion log so the scope tests run
    /// the full `rebuildLists` pipeline (logs/ledgers/quests) rather than only
    /// the ledger-filtering path.
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
    func `previousLocations extracts unique sorted locations from ledgers`() {
        let state = makeAppState()
        let cloudKit = MockCloudKitService(zoneID: state.zoneID)
        let treasury = TreasuryService(cloudKit: cloudKit)
        let spendingMock = MockSpendingService()
        let viewModel = TreasuryViewModel(
            treasury: treasury, spending: spendingMock, appState: state.appState
        )

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
    func `logging spending passes location to spending service`() async {
        let state = makeAppState()
        let cloudKit = MockCloudKitService(zoneID: state.zoneID)
        let treasury = TreasuryService(cloudKit: cloudKit)
        let spendingMock = MockSpendingService()
        let viewModel = TreasuryViewModel(
            treasury: treasury, spending: spendingMock, appState: state.appState
        )

        let success = await viewModel.logSpending(description: "Hammer", amount: 12.50, location: "Home Depot")
        #expect(success == true)
        #expect(spendingMock.transactions.count == 1)
        #expect(spendingMock.transactions.first?.location == "Home Depot")
    }
}

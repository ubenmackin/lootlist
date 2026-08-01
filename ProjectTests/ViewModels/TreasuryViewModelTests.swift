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

    func logManual(profile: Profile, family: Family, description: String, amount: Double, date: Date) async throws -> LedgerEntry {
        if shouldFail {
            throw SpendingServiceError.underlying("Mock error")
        }
        let entry = LedgerEntry(
            profile: CKRecord.Reference(recordID: profile.id, action: .none),
            amount: -abs(amount),
            description: description,
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
        let cloudKit = CloudKitService(zoneID: zoneID)
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
        let cloudKit = CloudKitService(zoneID: zoneID)
        let treasury = TreasuryService(cloudKit: cloudKit)
        let spendingMock = MockSpendingService()
        let appState = AppState()

        let viewModel = TreasuryViewModel(treasury: treasury, spending: spendingMock, appState: appState)

        let successNegative = await viewModel.logSpending(description: "Spellbook", amount: -5.0)
        #expect(successNegative == false)
        #expect(viewModel.errorMessage == "Enter a positive gold amount.")

        let successZero = await viewModel.logSpending(description: "Potion", amount: 0)
        #expect(successZero == false)
        #expect(viewModel.errorMessage == "Enter a positive gold amount.")
    }

    private struct TestAppState {
        let appState: AppState
        let zoneID: CKRecordZone.ID
        let profileName: String
    }

    private func makeAppState() -> TestAppState {
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
            id: CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        )
        let appState = AppState()
        appState.currentProfile = profile
        appState.familyZoneID = zoneID
        return TestAppState(appState: appState, zoneID: zoneID, profileName: "hero1")
    }

    @Test
    func `rebuildLists reflects allowance period status flip without cloudkit fetch`() {
        let state = makeAppState()
        let cloudKit = CloudKitService(zoneID: state.zoneID)
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
            showAllTime: false
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
            showAllTime: false
        )

        #expect(viewModel.weeklyBreakdown?.payoutStatus == .paid)
        #expect(viewModel.weeklyBreakdown?.paidAmount == 25.0)
        #expect(viewModel.allowancePeriod?.status == .paid)
        #expect(viewModel.allowancePeriod?.paidAmount == 25.0)
    }

    @Test
    func `rebuildLists scopes allowance period to current profile and week`() {
        let state = makeAppState()
        let cloudKit = CloudKitService(zoneID: state.zoneID)
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
            showAllTime: false
        )

        #expect(viewModel.weeklyBreakdown?.payoutStatus == .active)
        #expect(viewModel.weeklyBreakdown?.paidAmount == nil)
        #expect(viewModel.allowancePeriod?.status == .active)
    }
}

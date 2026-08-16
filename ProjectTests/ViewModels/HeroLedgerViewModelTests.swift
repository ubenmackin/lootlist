//
//  HeroLedgerViewModelTests.swift
//  LootList
//
//  Created by Ben Mackin on 8/10/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

@MainActor
struct HeroLedgerViewModelTests {
    private func makeHero() -> (hero: ProfileCache, appState: AppState) {
        makeConfiguredHero(payoutDay: nil, familyPayoutDay: .sunday)
    }

    /// Builds a hero with the given payout-day resolution inputs, mirroring the
    /// view model's effective payout day
    /// (`heroProfile.payoutDayEnum ?? appState.family?.payoutDay ?? .sunday`):
    /// a non-nil per-profile `payoutDay` overrides the family's `payoutDay`.
    private func makeConfiguredHero(payoutDay: PayoutDay?, familyPayoutDay: PayoutDay) -> (hero: ProfileCache, appState: AppState) {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let hero = ProfileCache(
            recordName: "hero1",
            familyRecordName: "fam1",
            displayName: "Test Hero",
            role: UserRole.hero.rawValue,
            xpTotal: 0,
            avatarName: nil,
            isActive: true,
            level: 1,
            iCloudUserRecordName: "u1",
            avatarClass: nil,
            payoutPolicy: PayoutPolicy.perQuest.rawValue,
            payoutDay: payoutDay?.rawValue
        )
        let appState = AppState()
        appState.family = Family(
            name: "Test Family",
            createdBy: CKRecord.ID(recordName: "u1", zoneID: zoneID),
            payoutPolicy: .perQuest,
            payoutDay: familyPayoutDay,
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )
        return (hero, appState)
    }

    private func makeLedger(_ recordName: String, date: Date) -> LedgerEntryCache {
        LedgerEntryCache(
            recordName: recordName,
            profileRecordName: "hero1",
            familyRecordName: "fam1",
            amount: -1,
            entryDescription: recordName,
            location: nil,
            date: date,
            source: "manual"
        )
    }

    private func makeViewModel() -> HeroLedgerViewModel {
        let setup = makeHero()
        return HeroLedgerViewModel(
            heroProfile: setup.hero,
            spending: MockSpendingService(),
            appState: setup.appState
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

    @Test
    func `rebuildLedger filters rows: this week scope`() {
        let viewModel = makeViewModel()
        let fixtures = scopedLedgerFixtures()

        viewModel.rebuildLedger(ledgers: fixtures, quests: [], completions: [], scope: .thisWeek)

        let expected = fixtures
            .filter { CalendarScope.thisWeek.contains($0.date) }
            .sorted { $0.date > $1.date }
            .map(\.recordName)
        #expect(viewModel.ledgerRows.map(\.id) == expected)
        #expect(expected.contains("l_today"))
        #expect(!expected.contains("l_year"))
    }

    @Test
    func `rebuildLedger filters rows: this month scope`() {
        let viewModel = makeViewModel()
        let fixtures = scopedLedgerFixtures()

        viewModel.rebuildLedger(ledgers: fixtures, quests: [], completions: [], scope: .thisMonth)

        let expected = fixtures
            .filter { CalendarScope.thisMonth.contains($0.date) }
            .sorted { $0.date > $1.date }
            .map(\.recordName)
        #expect(viewModel.ledgerRows.map(\.id) == expected)
        #expect(expected.contains("l_today"))
        #expect(!expected.contains("l_year"))
    }

    @Test
    func `rebuildLedger filters rows: this quarter scope`() {
        let viewModel = makeViewModel()
        let fixtures = scopedLedgerFixtures()

        viewModel.rebuildLedger(ledgers: fixtures, quests: [], completions: [], scope: .thisQuarter)

        let expected = fixtures
            .filter { CalendarScope.thisQuarter.contains($0.date) }
            .sorted { $0.date > $1.date }
            .map(\.recordName)
        #expect(viewModel.ledgerRows.map(\.id) == expected)
        #expect(expected.contains("l_today"))
        #expect(!expected.contains("l_year"))
    }

    @Test
    func `rebuildLedger filters rows: all time scope`() {
        let viewModel = makeViewModel()
        let fixtures = scopedLedgerFixtures()

        viewModel.rebuildLedger(ledgers: fixtures, quests: [], completions: [], scope: .allTime)

        let expectedRecordNames = fixtures.map(\.recordName)
        #expect(viewModel.ledgerRows.map(\.id).sorted() == expectedRecordNames.sorted())
        #expect(expectedRecordNames.count == 5)
    }

    // MARK: - CalendarScope payout-day threading

    @Test
    func `rebuildLedger keeps friday-anchored early-cycle entries in thisWeek`() {
        let fridayRange = CalendarScope.thisWeek.dateRange(payoutDay: .friday)
        let sundayRange = CalendarScope.thisWeek.dateRange(payoutDay: .sunday)
        let gapDate = !sundayRange.contains(fridayRange.lowerBound) ? fridayRange.lowerBound : fridayRange.upperBound
        let gapLedger = makeLedger("l_gap", date: gapDate)

        // Per-profile payout day = friday keeps the early-cycle entry.
        let setup = makeConfiguredHero(payoutDay: .friday, familyPayoutDay: .sunday)
        let viewModel = HeroLedgerViewModel(
            heroProfile: setup.hero, spending: MockSpendingService(), appState: setup.appState
        )
        viewModel.rebuildLedger(ledgers: [gapLedger], quests: [], completions: [], scope: .thisWeek)
        #expect(viewModel.ledgerRows.map(\.id).contains("l_gap"))
    }

    @Test
    func `rebuildLedger drops friday-gap entries for sunday default`() {
        let fridayRange = CalendarScope.thisWeek.dateRange(payoutDay: .friday)
        let sundayRange = CalendarScope.thisWeek.dateRange(payoutDay: .sunday)
        let gapDate = !sundayRange.contains(fridayRange.lowerBound) ? fridayRange.lowerBound : fridayRange.upperBound
        let gapLedger = makeLedger("l_gap", date: gapDate)

        let setup = makeConfiguredHero(payoutDay: nil, familyPayoutDay: .sunday)
        let viewModel = HeroLedgerViewModel(
            heroProfile: setup.hero, spending: MockSpendingService(), appState: setup.appState
        )
        viewModel.rebuildLedger(ledgers: [gapLedger], quests: [], completions: [], scope: .thisWeek)
        #expect(!viewModel.ledgerRows.map(\.id).contains("l_gap"))
    }

    @Test
    func `rebuildLedger per-profile payoutDay overrides family for thisWeek`() {
        let fridayRange = CalendarScope.thisWeek.dateRange(payoutDay: .friday)
        let sundayRange = CalendarScope.thisWeek.dateRange(payoutDay: .sunday)
        let gapDate = !sundayRange.contains(fridayRange.lowerBound) ? fridayRange.lowerBound : fridayRange.upperBound
        let gapLedger = makeLedger("l_gap", date: gapDate)

        // Family sunday + hero override friday → override wins, entry kept.
        let overrideSetup = makeConfiguredHero(payoutDay: .friday, familyPayoutDay: .sunday)
        let overrideVM = HeroLedgerViewModel(
            heroProfile: overrideSetup.hero, spending: MockSpendingService(), appState: overrideSetup.appState
        )
        overrideVM.rebuildLedger(ledgers: [gapLedger], quests: [], completions: [], scope: .thisWeek)
        #expect(overrideVM.ledgerRows.map(\.id).contains("l_gap"))

        // Hero nil + family friday → family fallback, entry kept.
        let familySetup = makeConfiguredHero(payoutDay: nil, familyPayoutDay: .friday)
        let familyVM = HeroLedgerViewModel(
            heroProfile: familySetup.hero, spending: MockSpendingService(), appState: familySetup.appState
        )
        familyVM.rebuildLedger(ledgers: [gapLedger], quests: [], completions: [], scope: .thisWeek)
        #expect(familyVM.ledgerRows.map(\.id).contains("l_gap"))
    }

    @Test
    func `rebuildLedger scopes rows against friday payout day across all scopes`() {
        let day: TimeInterval = 24 * 3600
        let now = Date()
        let sundayStart = WeekMath.startOfWeek(for: now, payoutDay: .sunday)
        let setup = makeConfiguredHero(payoutDay: .friday, familyPayoutDay: .friday)
        let viewModel = HeroLedgerViewModel(
            heroProfile: setup.hero, spending: MockSpendingService(), appState: setup.appState
        )

        let fixtures = [
            makeLedger("l_gap", date: sundayStart.addingTimeInterval(-day)),
            makeLedger("l_today", date: now),
            makeLedger("l_week", date: now.addingTimeInterval(-7 * day)),
            makeLedger("l_month", date: now.addingTimeInterval(-30 * day)),
            makeLedger("l_quarter", date: now.addingTimeInterval(-91 * day)),
            makeLedger("l_year", date: now.addingTimeInterval(-365 * day))
        ]

        for scope in CalendarScope.allCases {
            viewModel.rebuildLedger(ledgers: fixtures, quests: [], completions: [], scope: scope)
            let expected = fixtures
                .filter { scope.contains($0.date, payoutDay: .friday) }
                .sorted { $0.date > $1.date }
                .map(\.recordName)
            #expect(viewModel.ledgerRows.map(\.id) == expected)
        }
    }

    @Test
    func `rebuildLedger non-week scopes ignore payout day`() {
        let day: TimeInterval = 24 * 3600
        let now = Date()
        let ledgers = [
            makeLedger("l_today", date: now),
            makeLedger("l_month", date: now.addingTimeInterval(-30 * day))
        ]

        let fridaySetup = makeConfiguredHero(payoutDay: .friday, familyPayoutDay: .friday)
        let fridayVM = HeroLedgerViewModel(
            heroProfile: fridaySetup.hero, spending: MockSpendingService(), appState: fridaySetup.appState
        )
        let sundaySetup = makeConfiguredHero(payoutDay: .sunday, familyPayoutDay: .sunday)
        let sundayVM = HeroLedgerViewModel(
            heroProfile: sundaySetup.hero, spending: MockSpendingService(), appState: sundaySetup.appState
        )

        for scope in [CalendarScope.thisMonth, .thisQuarter, .allTime] {
            fridayVM.rebuildLedger(ledgers: ledgers, quests: [], completions: [], scope: scope)
            let fridayRows = fridayVM.ledgerRows.map(\.id)
            sundayVM.rebuildLedger(ledgers: ledgers, quests: [], completions: [], scope: scope)
            let sundayRows = sundayVM.ledgerRows.map(\.id)
            #expect(fridayRows == sundayRows)
        }
    }
}

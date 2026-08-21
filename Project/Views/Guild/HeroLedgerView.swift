//
//  HeroLedgerView.swift
//  LootList
//
//  Created by Ben Mackin on 8/8/26.
//

import SwiftData
import SwiftUI

struct HeroLedgerView: View {
    let hero: ProfileCache
    let familyRecordName: String?
    private let spending: SpendingService

    @Environment(AppState.self) private var appState
    @Environment(ToastManager.self) private var toastManager: ToastManager?

    @State private var viewModel: HeroLedgerViewModel?
    @State private var isShowingDeposit: Bool = false
    @State private var isShowingWithdraw: Bool = false

    /// Persisted date-range scope for this hero's ledger screen.
    @AppStorage("heroLedger.calendarScope") private var scope: CalendarScope = .thisWeek

    @Query private var cachedLedgers: [LedgerEntryCache]
    @Query private var cachedQuests: [QuestCache]
    @Query private var cachedCompletions: [QuestCompletionCache]

    init(hero: ProfileCache, familyRecordName: String?, spending: SpendingService) {
        self.hero = hero
        self.familyRecordName = familyRecordName
        self.spending = spending

        let targetFamily = familyRecordName ?? ""
        let ledgerFilter = #Predicate<LedgerEntryCache> { $0.familyRecordName == targetFamily }
        let questFilter = #Predicate<QuestCache> { $0.familyRecordName == targetFamily && $0.isActive == true }
        let completionFilter = #Predicate<QuestCompletionCache> { $0.familyRecordName == targetFamily }

        _cachedLedgers = Query(
            filter: ledgerFilter,
            sort: \LedgerEntryCache.date,
            order: .reverse
        )
        _cachedQuests = Query(
            filter: questFilter,
            sort: \QuestCache.weekOf,
            order: .reverse
        )
        _cachedCompletions = Query(
            filter: completionFilter,
            sort: \QuestCompletionCache.completedDate,
            order: .reverse
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                BalanceCardView(
                    balance: viewModel?.balance,
                    weekOf: nil,
                    status: nil,
                    pendingPayoutAmount: viewModel?.pendingQuestGold
                )

                CalendarScopeFilterView(
                    scope: $scope,
                    payoutDay: hero.payoutDayEnum ?? appState.family?.payoutDay ?? .sunday
                )
                .padding(.horizontal)

                HStack(spacing: 12) {
                    depositButton
                    withdrawButton
                }
                .padding(.horizontal)

                ledgerList
            }
            .padding(.vertical)
        }
        .background(Color(.systemGroupedBackground))
        .task {
            if viewModel == nil {
                viewModel = HeroLedgerViewModel(heroProfile: hero, spending: spending, appState: appState)
            }
            rebuild()
        }
        .onChange(of: cachedLedgers) { _, _ in rebuild() }
        .onChange(of: cachedQuests) { _, _ in rebuild() }
        .onChange(of: cachedCompletions) { _, _ in rebuild() }
        .onChange(of: scope) { _, _ in rebuild() }
        .sheet(isPresented: $isShowingDeposit) {
            if let vm = viewModel {
                HeroTransactionView(mode: .deposit, viewModel: vm, heroName: hero.displayName)
            }
        }
        .sheet(isPresented: $isShowingWithdraw) {
            if let vm = viewModel {
                HeroTransactionView(mode: .withdraw, viewModel: vm, heroName: hero.displayName)
            }
        }
    }

    private func rebuild() {
        viewModel?.rebuildLedger(
            ledgers: cachedLedgers,
            quests: cachedQuests,
            completions: cachedCompletions,
            scope: scope
        )
    }

    private var depositButton: some View {
        Button {
            isShowingDeposit = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill")
                Text("Deposit")
                    .font(.subheadline.weight(.bold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .foregroundStyle(Color.green)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.green.opacity(0.4), lineWidth: 1)
            )
        }
    }

    private var withdrawButton: some View {
        Button {
            isShowingWithdraw = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "minus.circle.fill")
                Text("Withdraw")
                    .font(.subheadline.weight(.bold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .foregroundStyle(Color.orange)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.orange.opacity(0.4), lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private var ledgerList: some View {
        if let vm = viewModel {
            if vm.ledgerRows.isEmpty {
                EmptyStateView(
                    systemImage: "scroll.fill",
                    title: "Empty Scroll",
                    description: scope.emptyStateCopy,
                    topPadding: 32
                )
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(vm.ledgerRows) { entry in
                        heroLedgerEntryRow(entry)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func heroLedgerEntryRow(_ entry: SpendingLogRow) -> some View {
        VStack(spacing: 4) {
            HStack(alignment: .top, spacing: 12) {
                let iconInfo = LedgerRowStyle.sourceIcon(for: entry.source, fallbackTint: .primary)
                Image(systemName: iconInfo.name)
                    .font(.title2)
                    .foregroundStyle(iconInfo.color)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.description)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    if let location = entry.location, !location.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: "mappin.and.ellipse")
                                .font(.caption2)
                            Text(location)
                                .font(.caption.weight(.medium))
                        }
                        .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text(LedgerRowStyle.sourceLabel(for: entry.source))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(iconInfo.color)
                        Text("•")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(LedgerRowStyle.dateText(for: entry.date))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 12)

                Text(GoldFormat.signed(entry.amount))
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(entry.amount >= 0 ? Color.gold : .red)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
        }
    }
}

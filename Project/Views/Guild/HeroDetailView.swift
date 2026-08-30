//
//  HeroDetailView.swift
//  LootList
//
//  Created by Ben Mackin on 8/8/26.
//

import SwiftData
import SwiftUI

struct HeroDetailView: View {
    let hero: ProfileCache
    let familyRecordName: String?
    let spending: SpendingService

    @Environment(QuestService.self) private var questService
    @Environment(FamilyService.self) private var familyService
    @Environment(AppState.self) private var appState
    @Environment(AppSyncCoordinator.self) private var appSyncCoordinator

    @Query private var cachedLedgers: [LedgerEntryCache]

    enum ActiveDestination: Hashable, Identifiable {
        case quests
        case treasury
        case savingsGoals

        var id: Self {
            self
        }
    }

    @State private var activeDestination: ActiveDestination?
    @State private var showDepositSheet = false
    @State private var showWithdrawSheet = false
    @State private var showBucketSplitSheet = false
    @State private var showInterestMatchSheet = false

    init(hero: ProfileCache, familyRecordName: String?, spending: SpendingService) {
        self.hero = hero
        self.familyRecordName = familyRecordName
        self.spending = spending

        let targetFamily = familyRecordName ?? ""
        let targetProfile = hero.recordName
        // WHY: Predicate pushdown fetches only this hero's ledgers; avoids
        // loading entire family ledger set and prevents cross-profile leakage
        // — FamilyScopedCache scoping remains primary isolation layer.
        let ledgerFilter = #Predicate<LedgerEntryCache> { item in
            item.familyRecordName == targetFamily
                && item.profileRecordName == targetProfile
        }
        _cachedLedgers = Query(filter: ledgerFilter, sort: \LedgerEntryCache.date, order: .reverse)
    }

    private var availableBalance: Double {
        BucketService.ledgerBalance(for: cachedLedgers, profileRecordName: hero.recordName)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: DesignSystemConstants.Padding.large) {
                heroHeaderCard

                navigationCardsSection
            }
            .padding(.vertical, DesignSystemConstants.Padding.standard)
            .padding(.horizontal, DesignSystemConstants.Padding.standard)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(hero.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $activeDestination) { destination in
            switch destination {
            case .quests:
                QuestLogView(initialHero: hero, familyRecordName: familyRecordName)
                    .environment(questService)
                    .environment(familyService)
                    .environment(appState)
                    .environment(appSyncCoordinator)
            case .treasury:
                HeroLedgerView(hero: hero, familyRecordName: familyRecordName, spending: spending)
                    .environment(appState)
            case .savingsGoals:
                KidsSavingsGoalsView(
                    familyRecordName: familyRecordName,
                    focusedProfileRecordName: hero.recordName
                )
                .environment(appState)
            }
        }
        .sheet(isPresented: $showDepositSheet) {
            HeroTransactionView(
                mode: .deposit,
                viewModel: HeroLedgerViewModel(heroProfile: hero, spending: spending, appState: appState),
                heroName: hero.displayName
            )
        }
        .sheet(isPresented: $showWithdrawSheet) {
            HeroTransactionView(
                mode: .withdraw,
                viewModel: HeroLedgerViewModel(heroProfile: hero, spending: spending, appState: appState),
                heroName: hero.displayName
            )
        }
        .sheet(isPresented: $showBucketSplitSheet) {
            SavingsSplitView(familyRecordName: familyRecordName, profileRecordName: hero.recordName)
        }
        .sheet(isPresented: $showInterestMatchSheet) {
            HeroInterestMatchView(hero: hero, familyRecordName: familyRecordName)
        }
    }

    // MARK: - Header Card

    private var heroHeaderCard: some View {
        VStack(spacing: 16) {
            // Avatar & Name
            VStack(spacing: 8) {
                if let emoji = hero.avatarEmoji, !emoji.isEmpty {
                    Text(emoji)
                        .font(.system(size: 44))
                        .frame(width: 60, height: 60)
                        .background(Circle().fill(Color(.tertiarySystemGroupedBackground)))
                } else {
                    ProfileAvatarView(profileCache: hero)
                        .frame(width: 60, height: 60)
                }

                Text(hero.displayName)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)
            }

            // Balance
            VStack(spacing: 4) {
                Text(CurrencyFormatter.string(availableBalance))
                    .font(.system(size: 32, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color(DesignSystemConstants.Colors.primaryGreen))

                Text("Available Balance")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            // Deposit / Withdraw Buttons
            HStack(spacing: 12) {
                quickActionButton(
                    title: "Deposit",
                    icon: "plus.circle.fill",
                    color: Color(DesignSystemConstants.Colors.primaryGreen),
                    identifier: "heroDetail.depositButton"
                ) {
                    showDepositSheet = true
                }

                quickActionButton(
                    title: "Withdraw",
                    icon: "minus.circle.fill",
                    color: Color(DesignSystemConstants.Colors.pendingAmber),
                    identifier: "heroDetail.withdrawButton"
                ) {
                    showWithdrawSheet = true
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(DesignSystemConstants.Padding.large)
        .background(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.card, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.card, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }

    private func quickActionButton(
        title: String,
        icon: String,
        color: Color,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
                    .font(.subheadline.weight(.bold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.tertiarySystemGroupedBackground))
            )
            .foregroundStyle(color)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(color.opacity(0.35), lineWidth: 1)
            )
        }
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }

    // MARK: - Navigation Cards Section

    private var navigationCardsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("ACTIVITIES & SETTINGS")

            VStack(spacing: 10) {
                Button {
                    activeDestination = .quests
                } label: {
                    hubNavigationRow(
                        title: "Quests & Chores",
                        subtitle: "View chore completions and history",
                        systemImage: "checklist",
                        iconColor: Color(DesignSystemConstants.Colors.pendingAmber)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("heroDetail.questsNavCard")
                .accessibilityLabel("Quests & Chores")

                Button {
                    activeDestination = .treasury
                } label: {
                    hubNavigationRow(
                        title: "Treasury & Ledger",
                        subtitle: "Transaction history, balances & exports",
                        systemImage: "banknote.fill",
                        iconColor: Color(DesignSystemConstants.Colors.primaryGreen)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("heroDetail.treasuryNavCard")
                .accessibilityLabel("Treasury & Ledger")

                Button {
                    activeDestination = .savingsGoals
                } label: {
                    hubNavigationRow(
                        title: "Savings Goals",
                        subtitle: "View and manage savings targets",
                        systemImage: "target",
                        iconColor: Color(DesignSystemConstants.Colors.accentBlue)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("heroDetail.savingsGoalsNavCard")
                .accessibilityLabel("View savings goals for \(hero.displayName)")

                if familyRecordName != nil {
                    Button {
                        HapticsService.lightImpact()
                        showBucketSplitSheet = true
                    } label: {
                        hubNavigationRow(
                            title: "Bucket Split",
                            subtitle: "Configure Spend / Save / Give allocation",
                            systemImage: "chart.pie.fill",
                            iconColor: Color(DesignSystemConstants.Colors.accentBlue)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("heroDetail.bucketSplitRow")
                    .accessibilityLabel("Bucket Split")

                    Button {
                        HapticsService.lightImpact()
                        showInterestMatchSheet = true
                    } label: {
                        hubNavigationRow(
                            title: "Interest & Match",
                            subtitle: "Monthly savings interest & parent match",
                            systemImage: "chart.line.uptrend.xyaxis",
                            iconColor: Color(DesignSystemConstants.Colors.primaryGreen)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("heroDetail.interestMatchRow")
                    .accessibilityLabel("Interest & Match")
                }
            }
        }
    }

    private func hubNavigationRow(
        title: String,
        subtitle: String,
        systemImage: String,
        iconColor: Color
    ) -> some View {
        HStack(spacing: DesignSystemConstants.Padding.medium) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(iconColor)
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(iconColor.opacity(0.14))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
        }
        .padding(DesignSystemConstants.Padding.medium)
        .background(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.card, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.card, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }
}

//
//  HeroDetailInlineView.swift
//  LootList
//
//  Created by Ben Mackin on 9/01/26.
//

import SwiftUI

struct HeroDetailInlineView: View {
    let hero: ProfileCache
    let familyRecordName: String?
    let ledgers: [LedgerEntryCache]
    let spending: SpendingService
    let onDeposit: () -> Void
    let onWithdraw: () -> Void

    @Environment(AppState.self) private var appState

    private var heroLedgers: [LedgerEntryCache] {
        ledgers.filter { $0.profileRecordName == hero.recordName }
            .sorted { $0.date > $1.date }
    }

    private var recentEntries: [LedgerEntryCache] {
        Array(heroLedgers.prefix(5))
    }

    private var balances: [BucketKind: Double] {
        var result: [BucketKind: Double] = [:]
        for entry in heroLedgers {
            BucketService.applyBucketAttribution(entry, to: &result)
        }
        return result
    }

    private var availableBalance: Double {
        heroLedgers.reduce(0) { $0 + $1.amount }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: DesignSystemConstants.Padding.standard) {
                headerCard
                bucketTiles
                quickActions
                recentLedgerSection
                navigationCards
            }
            // WHY: 400 caps inline detail column so ledger rows don't stretch on 11"; centered within inspector.
            .frame(maxWidth: DesignSystemConstants.Layout.inlineDetailWidth, alignment: .center)
            .padding(.horizontal, DesignSystemConstants.Padding.standard)
            .padding(.vertical, DesignSystemConstants.Padding.standard)
        }
        .background(Color(DesignSystemConstants.Colors.background).ignoresSafeArea())
        .navigationTitle(hero.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var headerCard: some View {
        VStack(spacing: DesignSystemConstants.Padding.medium) {
            if let emoji = hero.avatarEmoji, !emoji.isEmpty {
                Text(emoji)
                    .font(.system(size: 44))
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(Color(DesignSystemConstants.Colors.cardSurface)))
            } else {
                ProfileAvatarView(profileCache: hero)
                    .frame(width: 64, height: 64)
            }
            Text(hero.displayName)
                .font(.title3.weight(.bold))
            VStack(spacing: 2) {
                Text(CurrencyFormatter.string(availableBalance))
                    .font(.title2.weight(.heavy).monospacedDigit())
                    .foregroundStyle(Color(DesignSystemConstants.Colors.primaryGreen))
                Text("Available Balance")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(DesignSystemConstants.Padding.standard)
        .background(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.card, style: .continuous)
                .fill(Color(DesignSystemConstants.Colors.cardSurface))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.card, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }

    private var bucketTiles: some View {
        HStack(spacing: DesignSystemConstants.Padding.small) {
            bucketTile(kind: .spend)
            bucketTile(kind: .shortTermSave)
            bucketTile(kind: .longTermSave)
        }
    }

    private func bucketTile(kind: BucketKind) -> some View {
        VStack(spacing: 4) {
            Text(kind.shortName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(CurrencyFormatter.string(balances[kind] ?? 0))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.small, style: .continuous)
                .fill(Color(DesignSystemConstants.Colors.cardSurface))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.small, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }

    private var quickActions: some View {
        HStack(spacing: DesignSystemConstants.Padding.medium) {
            DashboardQuickActionButton(
                title: "Deposit",
                icon: "plus.circle.fill",
                color: Color(DesignSystemConstants.Colors.primaryGreen),
                identifier: "heroInline.depositButton"
            ) {
                onDeposit()
            }

            DashboardQuickActionButton(
                title: "Withdraw",
                icon: "minus.circle.fill",
                color: Color(DesignSystemConstants.Colors.pendingAmber),
                identifier: "heroInline.withdrawButton"
            ) {
                onWithdraw()
            }
        }
    }

    private var recentLedgerSection: some View {
        VStack(alignment: .leading, spacing: DesignSystemConstants.Padding.small) {
            SectionHeader("RECENT ACTIVITY")
            if recentEntries.isEmpty {
                Text("No ledger activity yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, DesignSystemConstants.Padding.small)
            } else {
                VStack(spacing: DesignSystemConstants.Padding.small) {
                    ForEach(recentEntries, id: \.recordName) { entry in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.entryDescription)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                Text(entry.date, format: .dateTime.month().day())
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(CurrencyFormatter.signed(entry.amount))
                                .font(.caption.weight(.bold).monospacedDigit())
                                .foregroundStyle(entry.amount >= 0 ? Color(DesignSystemConstants.Colors.primaryGreen) : Color(DesignSystemConstants.Colors.dangerRed))
                        }
                        .padding(DesignSystemConstants.Padding.small)
                        .background(
                            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.small, style: .continuous)
                                .fill(Color(DesignSystemConstants.Colors.cardSurface))
                        )
                    }
                }
            }
        }
        .padding(DesignSystemConstants.Padding.medium)
        .background(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.card, style: .continuous)
                .fill(Color(DesignSystemConstants.Colors.cardSurface))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.card, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }

    private var navigationCards: some View {
        VStack(spacing: DesignSystemConstants.Padding.small) {
            NavigationLink {
                HeroLedgerView(hero: hero, familyRecordName: familyRecordName, spending: spending)
                    .environment(appState)
            } label: {
                inlineRow(title: "Treasury & Ledger", subtitle: "Full history & exports", systemImage: "banknote.fill", color: Color(DesignSystemConstants.Colors.primaryGreen))
            }
            .buttonStyle(.plain)
            NavigationLink {
                QuestLogView(initialHero: hero, familyRecordName: familyRecordName)
            } label: {
                inlineRow(title: "Quests & Chores", subtitle: "Completions and history", systemImage: "checklist", color: Color(DesignSystemConstants.Colors.pendingAmber))
            }
            .buttonStyle(.plain)
        }
    }

    private func inlineRow(title: String, subtitle: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: DesignSystemConstants.Padding.medium) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .frame(width: 36, height: 36)
                .background(Circle().fill(color.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.secondary)
        }
        .padding(DesignSystemConstants.Padding.medium)
        .background(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.card, style: .continuous)
                .fill(Color(DesignSystemConstants.Colors.cardSurface))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.card, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }
}

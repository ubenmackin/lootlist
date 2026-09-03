//
//  ChildHubBalanceSection.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import SwiftUI

/// Balance hero with bucket tiles plus weekly progress ring. Extracted from
/// ChildHubView to keep the hub composed of ~80-line sections with no logic
/// change; all derived figures come from ChildHubViewModel.
struct ChildHubBalanceSection: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let viewModel: ChildHubViewModel
    let firstName: String?
    let displayName: String?
    let onSplitTapped: () -> Void

    var body: some View {
        if horizontalSizeClass == .regular {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 260), spacing: DesignSystemConstants.Padding.standard)],
                spacing: DesignSystemConstants.Padding.standard
            ) {
                balanceHeroCard
                weeklyProgressCard
            }
        } else {
            VStack(spacing: DesignSystemConstants.Padding.standard) {
                balanceHeroCard
                weeklyProgressCard
            }
        }
    }

    private var balanceHeroCard: some View {
        VStack(alignment: .leading, spacing: DesignSystemConstants.Padding.medium) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    greeting
                    Text("AVAILABLE BALANCE")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                Spacer()
                Button {
                    HapticsService.lightImpact()
                    onSplitTapped()
                } label: {
                    Text("3-Jar Split")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.white.opacity(0.2)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Configure 3-Jar Split")
                .accessibilityIdentifier("hub.splitPillButton")
            }

            Text(CurrencyFormatter.string(viewModel.availableBalance))
                .font(.system(size: 40, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)

            Divider().overlay(Color.white.opacity(0.35))

            HStack(spacing: DesignSystemConstants.Padding.small) {
                BucketTileView(emoji: nil, title: "SPEND", amountText: CurrencyFormatter.string(viewModel.bucketBalance(.spend)), accessibilityID: "hub.bucketTile-spend")
                BucketTileView(
                    emoji: nil,
                    title: "SHORT SAVE",
                    amountText: CurrencyFormatter.string(viewModel.bucketBalance(.shortTermSave)),
                    accessibilityID: "hub.bucketTile-shortSave"
                )
                BucketTileView(
                    emoji: nil,
                    title: "LONG SAVE",
                    amountText: CurrencyFormatter.string(viewModel.bucketBalance(.longTermSave)),
                    accessibilityID: "hub.bucketTile-longSave"
                )
            }
        }
        .padding(DesignSystemConstants.Padding.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.header, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(DesignSystemConstants.Colors.accentBlue), Color(DesignSystemConstants.Colors.accentBlue).opacity(0.85)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Available balance \(CurrencyFormatter.string(viewModel.availableBalance))")
        .accessibilityIdentifier("hub.balanceCard")
    }

    @ViewBuilder
    private var greeting: some View {
        if let firstName, !firstName.isEmpty {
            Text("Hey \(firstName)! 👋").font(.headline).foregroundStyle(.white)
        } else if let displayName, !displayName.isEmpty {
            Text("Hey \(displayName)! 👋").font(.headline).foregroundStyle(.white)
        } else {
            Text("Hey there! 👋").font(.headline).foregroundStyle(.white)
        }
    }

    private var weeklyProgressCard: some View {
        HStack(alignment: .center, spacing: DesignSystemConstants.Padding.standard) {
            VStack(alignment: .leading, spacing: 4) {
                Text("WEEKLY PROGRESS").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                Text("\(viewModel.weeklyCompleted) / \(viewModel.weeklyGoal) Completed").font(.title2.weight(.bold)).foregroundStyle(.primary)
                Text(viewModel.streakHint).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            ProgressRingView(progress: viewModel.weeklyProgress, tint: Color(DesignSystemConstants.Colors.accentBlue), identifier: "hub.weeklyProgressRing")
                .frame(width: 72, height: 72)
        }
        .padding(DesignSystemConstants.Padding.standard)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.card, style: .continuous)
            .fill(Color(DesignSystemConstants.Colors.cardSurface))
    }
}

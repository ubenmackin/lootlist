//
//  ChildHubHeaderView.swift
//  LootList
//
//  Created by Ben Mackin on 9/8/26.
//

import SwiftData
import SwiftUI

/// Hub header extracted from ChildHubView so the hub composes focused
/// sections with no logic change; all derived figures arrive as inputs.
struct ChildHubHeaderView: View {
    let currentProfileRow: ProfileCache?
    let firstName: String?
    let isSyncingPlaceholder: Bool
    let isProfileNotFoundPlaceholder: Bool
    let onRetry: () -> Void

    var body: some View {
        if isSyncingPlaceholder {
            VStack(spacing: 8) {
                ProgressView()
                Text("Syncing your family...")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Syncing your family")
            .accessibilityIdentifier("hub.syncingPlaceholder")
        } else if isProfileNotFoundPlaceholder {
            VStack(spacing: 8) {
                Text("Profile not found — pull to refresh")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    onRetry()
                } label: {
                    Text("Retry")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.accentColor))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Retry sync")
                .accessibilityIdentifier("hub.retryButton")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Profile not found — pull to refresh")
            .accessibilityIdentifier("hub.profileNotFoundPlaceholder")
        } else if let row = currentProfileRow {
            HStack(spacing: DesignSystemConstants.Padding.medium) {
                Text(row.avatarEmoji ?? "🦸")
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color(DesignSystemConstants.Colors.primaryGreen).opacity(0.15)))
                    .overlay(Circle().strokeBorder(Color(DesignSystemConstants.Colors.primaryGreen).opacity(0.3), lineWidth: 1))

                if let firstName {
                    Text("\(firstName)'s Hub")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                } else {
                    Text("\(row.displayName)'s Hub")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                Spacer()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(firstName ?? row.displayName)'s Hub")
            .accessibilityIdentifier("hub.headerTitle")
        } else {
            HStack(spacing: DesignSystemConstants.Padding.medium) {
                Text("🦸")
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color(DesignSystemConstants.Colors.primaryGreen).opacity(0.15)))
                    .overlay(Circle().strokeBorder(Color(DesignSystemConstants.Colors.primaryGreen).opacity(0.3), lineWidth: 1))

                Text("Your Hub")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Your Hub")
            .accessibilityIdentifier("hub.headerTitle")
        }
    }
}

/// Syncing placeholder card extracted from ChildHubView hub content.
struct ChildHubSyncingCardView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Syncing your family...")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .padding(DesignSystemConstants.Padding.large)
        .background(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.header, style: .continuous)
                .fill(Color(DesignSystemConstants.Colors.cardSurface))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.header, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Syncing your family")
        .accessibilityIdentifier("hub.syncingBalanceCard")
    }
}

/// Profile-not-found card extracted from ChildHubView hub content.
struct ChildHubProfileNotFoundCardView: View {
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Profile not found — pull to refresh")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                onRetry()
            } label: {
                Text("Retry")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.accentColor))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Retry sync")
            .accessibilityIdentifier("hub.retryButtonCard")
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .padding(DesignSystemConstants.Padding.large)
        .background(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.header, style: .continuous)
                .fill(Color(DesignSystemConstants.Colors.cardSurface))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.header, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Profile not found — pull to refresh")
        .accessibilityIdentifier("hub.profileNotFoundCard")
    }
}

/// Pinned log-a-purchase CTA extracted from ChildHubView safe-area inset.
struct ChildHubActionBarView: View {
    let onLogPurchase: () -> Void

    var body: some View {
        Button {
            HapticsService.lightImpact()
            onLogPurchase()
        } label: {
            Label("Log a Purchase / Spend", systemImage: "cart.fill")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.button, style: .continuous)
                        .fill(Color(DesignSystemConstants.Colors.primaryGreen))
                )
        }
        .accessibilityHint("Opens the spending log form")
        .accessibilityIdentifier("hub.logPurchaseButton")
    }
}

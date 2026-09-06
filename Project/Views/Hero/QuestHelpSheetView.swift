//
//  QuestHelpSheetView.swift
//  LootList
//
//  Created by Ben Mackin on 9/5/26.
//

import SwiftUI

struct QuestHelpSheetView: View {
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DesignSystemConstants.Padding.standard) {
                    howToSection
                    whatHappensSection
                    wheresMoneySection
                }
                .padding(.horizontal, DesignSystemConstants.Padding.standard)
                .padding(.vertical, DesignSystemConstants.Padding.medium)
            }
            .background(Color(DesignSystemConstants.Colors.background))
            .scrollContentBackground(.hidden)
            .navigationTitle("How Quests Work")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("questHelp.closeButton")
                }
            }
        }
    }

    private var howToSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("How to finish a quest", systemImage: "circle")
                .font(.headline)
                .foregroundStyle(.primary)

            Text(FlavorTextProvider.questHelpHowTo)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Illustration of the circle button on a quest card.
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(DesignSystemConstants.Colors.cardSurface))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
                    .frame(height: 52)
                    .overlay {
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color(DesignSystemConstants.Colors.primaryGreen).opacity(0.2))
                            Text("Example Quest")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Image(systemName: "circle")
                                .font(.title3)
                                .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
                        }
                        .padding(.horizontal, 12)
                    }
                Image(systemName: "hand.tap.fill")
                    .font(.title3)
                    .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.08))
            )
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(DesignSystemConstants.Colors.cardSurface))
        )
    }

    private var whatHappensSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What happens next?")
                .font(.headline)

            HStack(spacing: 12) {
                approvalPill(
                    systemImage: "checkmark.seal.fill",
                    title: "Instant 🎉",
                    detail: "You earn it right away!",
                    tint: Color(DesignSystemConstants.Colors.primaryGreen)
                )
                approvalPill(
                    systemImage: "hourglass.circle.fill",
                    title: "Parent checks 👀",
                    detail: "You’ll see ⏳ Awaiting Review until your Guild Master taps Approve. You can Unsubmit if you tapped by mistake.",
                    tint: Color(DesignSystemConstants.Colors.accentBlue)
                )
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(DesignSystemConstants.Colors.cardSurface))
        )
    }

    private func approvalPill(systemImage: String, title: String, detail: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.subheadline.bold())
                    .foregroundStyle(tint)
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(tint.opacity(0.12))
        )
    }

    private var wheresMoneySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Where’s my money?", systemImage: "banknote")
                .font(.headline)
            Text("Quest cash splits into your buckets. Check Money → ledger. Streaks build when you finish daily quests.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(DesignSystemConstants.Colors.cardSurface))
        )
    }
}

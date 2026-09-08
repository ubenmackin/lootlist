//
//  HeroHomePlayerCardView.swift
//  LootList
//
//  Created by Ben Mackin on 9/8/26.
//

import SwiftData
import SwiftUI

/// Integrated player card extracted from HeroHomeView so the home composes
/// focused sections with no logic change; all derived figures arrive as inputs.
struct HeroHomePlayerCardView: View {
    let row: ProfileCache
    let progress: LevelProgress
    let earned: Double
    let streak: Int
    let shields: Int
    let completed: Int
    let total: Int
    let familyName: String?

    var body: some View {
        VStack(spacing: 12) {
            topRow

            Divider()
                .overlay(Color.secondary.opacity(0.15))

            statsRow
        }
        .padding(DesignSystemConstants.Padding.standard)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.card, style: .continuous)
                .fill(Color(DesignSystemConstants.Colors.cardSurface))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.card, style: .continuous)
                .strokeBorder(Color(DesignSystemConstants.Colors.pendingAmber).opacity(0.30), lineWidth: 1)
        )
    }

    private var topRow: some View {
        HStack(spacing: 12) {
            ProfileAvatarView(profileCache: row)
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(row.displayName)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    // Legacy RPG chrome hidden when FeatureFlags.rpgImmersive is false.
                    if FeatureFlags.rpgImmersive {
                        Text("Lv. \(progress.currentLevel)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(Color(DesignSystemConstants.Colors.accentBlue))
                            )
                    }

                    Spacer(minLength: 0)

                    if let familyName, !familyName.isEmpty {
                        familyNamePill(familyName)
                    }
                }

                progressBar(value: progress.progress)
            }
        }
    }

    private func progressBar(value: Double) -> some View {
        GeometryReader { geo in
            let rawWidth = geo.size.width
            let trackWidth: CGFloat = (rawWidth.isFinite && rawWidth > 0) ? rawWidth : 0
            let rawProgress = CGFloat(value)
            let safeProgress: CGFloat = (rawProgress.isFinite && rawProgress > 0) ? min(rawProgress, 1) : 0
            let fillWidth = trackWidth * safeProgress
            let safeFillWidth: CGFloat = (fillWidth.isFinite && fillWidth > 0) ? fillWidth : 0
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(DesignSystemConstants.Colors.background))

                Capsule()
                    .fill(LinearGradient(
                        colors: [Color(DesignSystemConstants.Colors.accentBlue), Color(DesignSystemConstants.Colors.accentBlue)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .frame(width: safeFillWidth)
                    .animation(.spring(response: 0.6, dampingFraction: 0.8), value: value)
            }
        }
        .frame(height: 6)
    }

    private var statsRow: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "banknote.fill")
                    .font(.subheadline)
                    .foregroundStyle(Color(DesignSystemConstants.Colors.primaryGreen))
                VStack(alignment: .leading, spacing: 1) {
                    Text("This Week")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(CurrencyFormatter.string(earned))
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                }
            }

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "flame.fill")
                    .font(.subheadline)
                    .foregroundStyle(Color(DesignSystemConstants.Colors.pendingAmber))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Streak")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Text("\(streak)d")
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)
                        if shields > 0 {
                            Text("🛡️\(shields)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
                        }
                    }
                }
            }

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "checklist")
                    .font(.subheadline)
                    .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Quests")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(completed)/\(total)")
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                }
            }
        }
    }

    private func familyNamePill(_ name: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "shield.fill")
                .font(.caption2)
            Text(name)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(Color(DesignSystemConstants.Colors.accentBlue).opacity(0.12))
        )
        .overlay(
            Capsule()
                .strokeBorder(Color(DesignSystemConstants.Colors.accentBlue).opacity(0.35), lineWidth: 1)
        )
        .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
    }
}

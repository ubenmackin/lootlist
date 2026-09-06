//
//  BucketEducationBannerView.swift
//  LootList
//
//  Created by Ben Mackin on 9/5/26.
//

import SwiftData
import SwiftUI

/// Reusable education card teaching the 3-bucket model inline where allowance decisions happen.
/// Interactive banner variant: dismissible, live split %, and Set My Buckets sheet.
/// WHY distinct from BucketExplainer: this owns dismissal + queries + navigation;
/// BucketExplainer is the static copy-only explainer for compact help surfaces.
struct BucketEducationBannerView: View {
    @Environment(AppState.self) private var appState

    @Binding var hasDismissed: Bool

    @Query private var profileRows: [ProfileCache]

    @State private var isShowingSplit: Bool = false

    private let familyRecordName: String?
    private let profileRecordName: String?

    init(hasDismissed: Binding<Bool>, familyRecordName: String? = nil, profileRecordName: String? = nil) {
        self._hasDismissed = hasDismissed
        self.familyRecordName = familyRecordName
        self.profileRecordName = profileRecordName

        let targetFamily = familyRecordName ?? ""
        // WHY: predicate pushdown — filter by family+profile at store; fail-closed to 0 rows when empty.
        // WHY single source: dismissal binding owned by parent to avoid dual AppStorage wrappers for same key.
        if let effectiveProfile = profileRecordName.sanitizedNilIfEmpty {
            let targetProfile = effectiveProfile
            let filter = #Predicate<ProfileCache> {
                $0.familyRecordName == targetFamily && $0.recordName == targetProfile
            }
            _profileRows = Query(filter: filter, sort: \ProfileCache.displayName)
        } else {
            let filter = #Predicate<ProfileCache> { $0.familyRecordName == targetFamily }
            _profileRows = Query(filter: filter, sort: \ProfileCache.displayName)
        }
    }

    /// Resolved hero row — requires an explicit profile match, fail-closed.
    private var currentProfileRow: ProfileCache? {
        ProfileRowResolver.resolve(
            rows: profileRows,
            targetRecordName: profileRecordName ?? appState.currentProfile?.id.recordName
        )
    }

    private var spendPercent: Int {
        currentProfileRow?.splitPercentSpend ?? 100
    }

    private var shortPercent: Int {
        currentProfileRow?.splitPercentShort ?? 0
    }

    private var longPercent: Int {
        currentProfileRow?.splitPercentLong ?? 0
    }

    var body: some View {
        // WHY parent-owned dismissal: the parent holds the scoped binding so one key never gets dual wrappers;
        // the banner stays default-visible while the split is 100/0/0 so new heroes learn the model inline.
        if !hasDismissed {
            VStack(alignment: .leading, spacing: 12) {
                headerRow

                Text(BucketExplainer.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("bucketBanner.subtitle")

                bucketColumns

                Button {
                    isShowingSplit = true
                } label: {
                    Text("Set My Buckets")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(DesignSystemConstants.Colors.primaryGreen))
                .accessibilityIdentifier("bucketBanner.setBucketsButton")
            }
            .padding(DesignSystemConstants.Padding.medium)
            .background(
                RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.card, style: .continuous)
                    .fill(Color(DesignSystemConstants.Colors.cardSurface))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.card, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("bucketBanner.card")
            .sheet(isPresented: $isShowingSplit) {
                SavingsSplitView(
                    familyRecordName: familyRecordName,
                    profileRecordName: profileRecordName ?? appState.currentProfile?.id.recordName
                )
            }
        }
    }

    private var headerRow: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(BucketExplainer.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("bucketBanner.title")
            }
            Spacer()
            Button {
                hasDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
            .accessibilityIdentifier("bucketBanner.dismissButton")
        }
    }

    private var bucketColumns: some View {
        HStack(spacing: 8) {
            BucketColumnView(
                emoji: "🛒",
                title: "Spend",
                percent: spendPercent,
                tint: Color(DesignSystemConstants.Colors.primaryGreen),
                accessibilityID: "bucketBanner.spendColumn"
            )
            BucketColumnView(
                emoji: "🐿️",
                title: "Short",
                percent: shortPercent,
                tint: Color(DesignSystemConstants.Colors.accentBlue),
                accessibilityID: "bucketBanner.shortColumn"
            )
            BucketColumnView(
                emoji: "🏦",
                title: "Long",
                percent: longPercent,
                tint: Color(DesignSystemConstants.Colors.pendingAmber),
                accessibilityID: "bucketBanner.longColumn"
            )
        }
    }
}

//
//  ChildLedgerView.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import SwiftData
import SwiftUI

/// Read-only transaction history for a child profile, grouped by date into daily sections.
struct ChildLedgerView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppLifecycleCoordinator.self) private var lifecycleCoordinator: AppLifecycleCoordinator?

    private let familyRecordName: String?
    private let profileRecordName: String?

    @State private var isShowingTransfer: Bool = false
    @State private var isShowingSplit: Bool = false

    @Query private var allLedgers: [LedgerEntryCache]

    init(familyRecordName: String? = nil, profileRecordName: String? = nil) {
        self.familyRecordName = familyRecordName
        self.profileRecordName = profileRecordName

        // WHY: Predicate pushdown fetches only this hero's ledgers; avoids loading entire
        // family ledger set and reduces main-thread filtering for heroes with 1k+ rows.
        let targetFamily = familyRecordName ?? ""
        let targetProfile = profileRecordName ?? ""
        let ledgerFilter = #Predicate<LedgerEntryCache> {
            $0.familyRecordName == targetFamily && $0.profileRecordName == targetProfile
        }
        _allLedgers = Query(
            filter: ledgerFilter,
            sort: \LedgerEntryCache.date,
            order: .reverse
        )
    }

    // MARK: - Filtered Entries

    /// Entries already profile-scoped via predicate pushdown.
    private var childEntries: [LedgerEntryCache] {
        allLedgers
    }

    /// Ledger entries grouped by date bucket, preserving reverse-chronological
    /// order within each bucket.
    private var dateBuckets: [(title: String, entries: [LedgerEntryCache])] {
        // WHY: Day and week boundaries ride WeekMath's shared UTC bucket and the
        // hero's payout-day-aware cycle, matching the rest of the app.
        let payoutDay = appState.resolvedPayoutDay
        let today = Date()
        let thisWeekStart = WeekMath.startOfWeek(for: today, payoutDay: payoutDay)

        var todayEntries: [LedgerEntryCache] = []
        var yesterdayEntries: [LedgerEntryCache] = []
        var thisWeekEntries: [LedgerEntryCache] = []
        var olderEntries: [LedgerEntryCache] = []

        for entry in childEntries {
            if WeekMath.isToday(entry.date) {
                todayEntries.append(entry)
            } else if WeekMath.isYesterday(entry.date) {
                yesterdayEntries.append(entry)
            } else if WeekMath.startOfWeek(for: entry.date, payoutDay: payoutDay) == thisWeekStart {
                thisWeekEntries.append(entry)
            } else {
                olderEntries.append(entry)
            }
        }

        var buckets: [(title: String, entries: [LedgerEntryCache])] = []
        if !todayEntries.isEmpty {
            buckets.append(("Today", todayEntries))
        }
        if !yesterdayEntries.isEmpty {
            buckets.append(("Yesterday", yesterdayEntries))
        }
        if !thisWeekEntries.isEmpty {
            buckets.append(("This Week", thisWeekEntries))
        }
        if !olderEntries.isEmpty {
            buckets.append(("Older", olderEntries))
        }
        return buckets
    }

    private var isEmpty: Bool {
        childEntries.isEmpty
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DesignSystemConstants.Padding.standard) {
                    bucketSplitCard

                    if isEmpty {
                        emptyState
                    } else {
                        ForEach(dateBuckets, id: \.title) { bucket in
                            bucketSection(title: bucket.title, entries: bucket.entries)
                        }
                    }
                }
                .padding(.horizontal, DesignSystemConstants.Padding.standard)
                .padding(.top, DesignSystemConstants.Padding.small)
                .padding(.bottom, DesignSystemConstants.Padding.large)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                moveMoneyBar
                    .padding(.horizontal, DesignSystemConstants.Padding.standard)
                    .padding(.vertical, DesignSystemConstants.Padding.small)
                    .background(Color(.systemGroupedBackground))
            }
            .sheet(isPresented: $isShowingTransfer) {
                BucketTransferView(familyRecordName: familyRecordName)
            }
            .sheet(isPresented: $isShowingSplit) {
                SavingsSplitView(
                    familyRecordName: familyRecordName,
                    profileRecordName: appState.currentProfile?.id.recordName
                )
            }
            .navigationTitle("MONEY")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable {
                await lifecycleCoordinator?.performManualSync()
            }
        }
    }

    // MARK: - Bucket Split Entry

    private var bucketSplitCard: some View {
        BucketSplitEntryRow(accessibilityIdentifier: "ledger.bucketSplitRow") {
            isShowingSplit = true
        }
    }

    // MARK: - Bucket Section

    private func bucketSection(title: String, entries: [LedgerEntryCache]) -> some View {
        VStack(alignment: .leading, spacing: DesignSystemConstants.Padding.small) {
            SectionHeader(title)

            ForEach(entries, id: \.recordName) { entry in
                ledgerRow(for: entry)
            }
        }
    }

    // MARK: - Ledger Row

    private func ledgerRow(for entry: LedgerEntryCache) -> some View {
        let isCredit = entry.amount >= 0

        return HStack(spacing: DesignSystemConstants.Padding.medium) {
            // Source icon.
            Image(systemName: iconName(for: entry.source))
                .font(.body)
                .foregroundStyle(iconColor(for: entry.source))
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(iconColor(for: entry.source).opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.entryDescription)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    if let bucket = entry.bucketKindEnum {
                        HStack(spacing: 3) {
                            Image(systemName: bucket.iconSystemName)
                                .font(.system(size: 9))
                            Text(bucket.shortName)
                                .font(.caption2.weight(.semibold))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color(DesignSystemConstants.Colors.accentBlue).opacity(0.12))
                        )
                        .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))

                        Text("•")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // Subtitle: formatted relative date or short date for older
                    // entries.
                    Text(formattedDate(entry.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text(formattedAmount(entry.amount, isCredit: isCredit))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(
                    isCredit
                        ? Color(DesignSystemConstants.Colors.primaryGreen)
                        : Color(DesignSystemConstants.Colors.dangerRed)
                )
        }
        .padding(DesignSystemConstants.Padding.medium)
        .background(
            RoundedRectangle(
                cornerRadius: DesignSystemConstants.CornerRadius.small,
                style: .continuous
            )
            .fill(Color(DesignSystemConstants.Colors.cardSurface))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(entry.entryDescription): \(CurrencyFormatter.string(entry.amount))"
        )
        .accessibilityIdentifier("ledger.row-\(entry.recordName)")
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "dollarsign.circle")
                .font(.system(size: 56))
                .foregroundStyle(Color(DesignSystemConstants.Colors.primaryGreen))

            Text("No Transactions Yet")
                .font(.title2.weight(.bold))
                .foregroundStyle(.primary)

            Text(
                "No transactions yet — complete your first quest to see earnings here!"
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, DesignSystemConstants.Padding.large)

            Spacer()
        }
        .padding(.top, 64)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("ledger.emptyState")
    }

    // MARK: - Move Money CTA

    private var moveMoneyBar: some View {
        Button {
            HapticsService.lightImpact()
            isShowingTransfer = true
        } label: {
            Label("Move Money", systemImage: "arrow.left.arrow.right")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.button, style: .continuous)
                        .fill(Color(DesignSystemConstants.Colors.accentBlue))
                )
        }
        .accessibilityHint("Move money between your buckets")
        .accessibilityIdentifier("ledger.moveMoneyButton")
    }

    // MARK: - Helpers

    /// Maps a ledger source string to its semantic SF Symbol name.
    private func iconName(for source: String) -> String {
        switch source {
        case "quest": "checkmark.seal.fill"
        case "interest": "percent"
        case "match": "heart.fill"
        case "transfer": "arrow.left.arrow.right"
        case "manual": "cart.fill"
        default:
            // Import-tagged sources and unknown entries use a generic receipt
            // icon.
            "doc.text.fill"
        }
    }

    /// Maps a ledger source string to a semantic tint color.
    private func iconColor(for source: String) -> Color {
        switch source {
        case "quest":
            Color(DesignSystemConstants.Colors.primaryGreen)
        case "interest":
            Color(DesignSystemConstants.Colors.accentBlue)
        case "match":
            Color(DesignSystemConstants.Colors.primaryGreen)
        case "transfer":
            Color(DesignSystemConstants.Colors.pendingAmber)
        case "manual":
            Color(DesignSystemConstants.Colors.dangerRed)
        default:
            Color.secondary
        }
    }

    /// Returns a signed amount string: "+$X.XX" for credits, "-$X.XX" for debits,
    /// absolute-value for zero.
    private func formattedAmount(_ amount: Double, isCredit: Bool) -> String {
        if amount == 0 {
            return CurrencyFormatter.string(0.0)
        }
        let prefix = isCredit ? "+" : ""
        return prefix + CurrencyFormatter.string(amount)
    }

    /// Returns a human-readable date label. Today/Yesterday buckets show the
    /// time; older entries show the abbreviated date.
    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()

        if WeekMath.isToday(date) || WeekMath.isYesterday(date) {
            formatter.timeStyle = .short
            formatter.dateStyle = .none
        } else {
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
        }
        return formatter.string(from: date)
    }
}

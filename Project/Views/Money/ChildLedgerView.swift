//
//  ChildLedgerView.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import CloudKit
import SwiftData
import SwiftUI

/// Read-only transaction history for a child profile, grouped by date into
/// Today / Yesterday / This Week / Older sections. Each row shows a semantic
/// source icon, the entry description, the amount (green for credits, red for
/// debits), and a formatted date.
struct ChildLedgerView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppLifecycleCoordinator.self) private var lifecycleCoordinator: AppLifecycleCoordinator?

    private let familyRecordName: String?

    @Query private var allLedgers: [LedgerEntryCache]

    init(familyRecordName: String? = nil) {
        self.familyRecordName = familyRecordName

        let targetFamily = familyRecordName ?? ""
        let ledgerFilter = #Predicate<LedgerEntryCache> {
            $0.familyRecordName == targetFamily
        }
        _allLedgers = Query(
            filter: ledgerFilter,
            sort: \LedgerEntryCache.date,
            order: .reverse
        )
    }

    // MARK: - Filtered Entries

    /// Entries that belong to the current child profile.
    private var childEntries: [LedgerEntryCache] {
        guard let profileName = appState.currentProfile?.id.recordName else { return [] }
        return allLedgers.filter { $0.profileRecordName == profileName }
    }

    /// Ledger entries grouped by date bucket, preserving reverse-chronological
    /// order within each bucket.
    private var dateBuckets: [(title: String, entries: [LedgerEntryCache])] {
        let calendar = Calendar.current
        let today = Date()

        var todayEntries: [LedgerEntryCache] = []
        var yesterdayEntries: [LedgerEntryCache] = []
        var thisWeekEntries: [LedgerEntryCache] = []
        var olderEntries: [LedgerEntryCache] = []

        for entry in childEntries {
            if calendar.isDateInToday(entry.date) {
                todayEntries.append(entry)
            } else if calendar.isDateInYesterday(entry.date) {
                yesterdayEntries.append(entry)
            } else if calendar.isDate(entry.date, equalTo: today, toGranularity: .weekOfYear) {
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
                if isEmpty {
                    emptyState
                } else {
                    VStack(spacing: DesignSystemConstants.Padding.standard) {
                        ForEach(dateBuckets, id: \.title) { bucket in
                            bucketSection(title: bucket.title, entries: bucket.entries)
                        }
                    }
                    .padding(.horizontal, DesignSystemConstants.Padding.standard)
                    .padding(.top, DesignSystemConstants.Padding.small)
                    .padding(.bottom, DesignSystemConstants.Padding.large)
                }
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("MONEY")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable {
                await lifecycleCoordinator?.performManualSync()
            }
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

                // Subtitle: formatted relative date or short date for older
                // entries.
                Text(formattedDate(entry.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 64)

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
        .frame(maxWidth: .infinity)
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
            Color.pink
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
            return CurrencyFormatter.string(0)
        }
        let prefix = isCredit ? "+" : ""
        return prefix + CurrencyFormatter.string(amount)
    }

    /// Returns a human-readable date label. Today/Yesterday buckets show the
    /// time; older entries show the abbreviated date.
    private func formattedDate(_ date: Date) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()

        if calendar.isDateInToday(date) || calendar.isDateInYesterday(date) {
            formatter.timeStyle = .short
            formatter.dateStyle = .none
        } else {
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
        }
        return formatter.string(from: date)
    }
}

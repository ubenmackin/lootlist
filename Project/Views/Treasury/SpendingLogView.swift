import SwiftUI

struct SpendingLogView: View {
    @Bindable var viewModel: TreasuryViewModel

    @State private var showAllTime: Bool = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                filterToggle

                if viewModel.spendingLog.isEmpty {
                    emptyState
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(viewModel.spendingLog) { entry in
                            LedgerEntryRow(entry: entry)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: showAllTime) { _, newValue in
            Task { await viewModel.loadSpendingLog(showAllTime: newValue) }
        }
        .task {
            if viewModel.spendingLog.isEmpty {
                await viewModel.loadSpendingLog(showAllTime: showAllTime)
            }
        }
    }

    private var filterToggle: some View {
        HStack {
            Label(showAllTime ? "All Time" : "This Week",
                  systemImage: showAllTime ? "calendar" : "clock")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Toggle("", isOn: $showAllTime)
                .labelsHidden()
                .tint(.gold)
        }
        .padding(.horizontal)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "scroll.fill")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Empty Scroll of Spending")
                .font(.headline)
            Text(showAllTime
                ? "No entries yet — log your first spend to begin your chronicle."
                : "No spending logged this week.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .padding(.top, 64)
    }

    private var navigationTitle: String {
        showAllTime ? "Scroll of Spending — All Time" : "Scroll of Spending"
    }
}

struct LedgerEntryRow: View {
    let entry: LedgerEntry

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: entry.amount >= 0
                    ? GoldFormat.coinSystemName
                    : "arrow.down.circle.fill")
                    .font(.title2)
                    .foregroundStyle(entry.amount >= 0 ? Color.gold : .red)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.description)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    Text(dateText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.description), \(GoldFormat.signed(entry.amount)), \(dateText)")
    }

    private var dateText: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: entry.date)
    }
}

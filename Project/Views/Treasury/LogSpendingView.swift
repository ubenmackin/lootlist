//
//  LogSpendingView.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import SwiftData
import SwiftUI

struct LogSpendingView: View {
    @Bindable var viewModel: TreasuryViewModel

    @Environment(ToastManager.self) private var toastManager
    @Environment(\.dismiss) private var dismiss

    @Query private var cachedLedgers: [LedgerEntryCache]

    @State private var description: String = ""
    @State private var location: String = ""
    @State private var amountText: String = ""
    @FocusState private var isAmountFocused: Bool
    @State private var date: Date = .init()
    @State private var isSaving: Bool = false

    init(viewModel: TreasuryViewModel, familyRecordName: String? = nil) {
        self.viewModel = viewModel
        let targetFamily = familyRecordName ?? ""
        let filter = #Predicate<LedgerEntryCache> { $0.familyRecordName == targetFamily }
        _cachedLedgers = Query(filter: filter, sort: \LedgerEntryCache.date, order: .reverse)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What did you buy?",
                              text: $description,
                              axis: .vertical)
                        .lineLimit(2 ... 6)
                } header: {
                    Text("Chronicle Entry")
                } footer: {
                    Text("Tell the tale of where your money went — a short memory like \"Snack at the market.\"")
                }

                Section {
                    HStack {
                        Image(systemName: "mappin.and.ellipse")
                            .foregroundStyle(.secondary)
                        TextField("Location or Store (Optional)", text: $location)
                            .autocorrectionDisabled(false)
                    }

                    if !matchingLocations.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(matchingLocations, id: \.self) { item in
                                    Button {
                                        location = item
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "clock.arrow.circlepath")
                                                .font(.caption2)
                                            Text(item)
                                                .font(.subheadline)
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(Color(.tertiarySystemFill), in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                } header: {
                    Text("Location / Store")
                } footer: {
                    Text("Optionally log where you spent your money (e.g. \"Home Depot\").")
                }

                Section {
                    HStack {
                        Image(systemName: "banknote")
                            .foregroundStyle(Color.gold)
                        TextField("2.50", text: $amountText)
                            .keyboardType(.decimalPad)
                            .focused($isAmountFocused)
                            .font(.body.monospacedDigit())
                    }
                } header: {
                    Text("Amount")
                } footer: {
                    Text("Enter a positive number — this becomes a debit against your balance.")
                }

                Section("When") {
                    DatePicker("Date",
                               selection: $date,
                               displayedComponents: [.date, .hourAndMinute])
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Scroll of Spending")
            .navigationBarTitleDisplayMode(.inline)
            // Icon-only toolbar prevents title truncation; accessibilityLabel preserves affordance.
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Label("Cancel", systemImage: "xmark")
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityLabel("Cancel")
                    .accessibilityIdentifier("logSpending.cancelButton")
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: save) {
                        if isSaving {
                            ProgressView()
                        } else {
                            Label("Add to Scroll", systemImage: "plus")
                                .labelStyle(.iconOnly)
                        }
                    }
                    .accessibilityLabel("Add to Scroll")
                    .accessibilityIdentifier("logSpending.confirmButton")
                    .tint(Color(DesignSystemConstants.Colors.primaryGreen))
                    .disabled(isSaving)
                }
            }
            .decimalPadDoneToolbar(isFocused: $isAmountFocused)
            .interactiveDismissDisabled(isSaving)
            .toastOverlay()
        }
    }

    private var matchingLocations: [String] {
        let allLocations = viewModel.previousLocations(from: cachedLedgers)
        let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return allLocations
        }
        return allLocations.filter { loc in
            loc.lowercased().hasPrefix(trimmed.lowercased()) && loc.localizedCaseInsensitiveCompare(trimmed) != .orderedSame
        }
    }

    private func save() {
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDescription.isEmpty else {
            toastManager.show(message: "Please enter a description of what you bought.", type: .warning)
            return
        }
        guard let amount = Double(amountText), amount.isFinite, amount > 0 else {
            toastManager.show(message: "Please enter a valid positive amount.", type: .warning)
            return
        }
        isSaving = true
        Task {
            let success = await viewModel.logSpending(
                description: trimmedDescription,
                amount: amount,
                location: location,
                date: date
            )
            isSaving = false
            if success {
                dismiss()
            } else {
                toastManager.show(message: viewModel.errorMessage ?? "Failed to log spending.", type: .error)
            }
        }
    }
}

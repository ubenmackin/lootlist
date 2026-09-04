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
    @State private var showOverdrawConfirm: Bool = false

    private let familyRecordName: String?
    private let profileRecordName: String?

    init(
        viewModel: TreasuryViewModel,
        familyRecordName: String? = nil,
        profileRecordName: String? = nil
    ) {
        self.viewModel = viewModel
        self.familyRecordName = familyRecordName
        self.profileRecordName = profileRecordName
        let targetFamily = familyRecordName ?? ""
        let targetProfile = profileRecordName ?? ""
        // WHY predicate pushdown: the sheet only needs this hero's rows to price the Spend warning.
        if targetProfile.isEmpty {
            let filter = #Predicate<LedgerEntryCache> { $0.familyRecordName == targetFamily }
            _cachedLedgers = Query(filter: filter, sort: \LedgerEntryCache.date, order: .reverse)
        } else {
            let filter = #Predicate<LedgerEntryCache> { $0.familyRecordName == targetFamily && $0.profileRecordName == targetProfile }
            _cachedLedgers = Query(filter: filter, sort: \LedgerEntryCache.date, order: .reverse)
        }
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
                        .frame(height: 36)
                    }
                } header: {
                    Text("Location / Store")
                } footer: {
                    Text("Optionally log where you spent your money (e.g. \"Home Depot\").")
                }

                Section {
                    HStack {
                        Image(systemName: "banknote")
                            .foregroundStyle(Color(DesignSystemConstants.Colors.gold))
                        TextField("2.50", text: $amountText)
                            .keyboardType(.decimalPad)
                            .focused($isAmountFocused)
                            .font(.body.monospacedDigit())
                    }
                } header: {
                    Text("Amount")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Enter a positive number — this becomes a debit against your balance.")
                        Text("Available in Spend: \(CurrencyFormatter.string(spendBalance))")
                        if isOverdrawn, let amount = parsedAmount {
                            Label {
                                Text(
                                    "This spending of \(CurrencyFormatter.string(amount)) exceeds "
                                        + "the Spend balance of \(CurrencyFormatter.string(spendBalance)). "
                                        + "Spend will go negative if you continue."
                                )
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill")
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color(DesignSystemConstants.Colors.dangerRed))
                            .accessibilityIdentifier("logSpending.overdrawWarning")
                        }
                    }
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
                    Button {
                        tappedSave()
                    } label: {
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
            .alert("Spend Will Go Negative", isPresented: $showOverdrawConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Log Anyway", role: .destructive) {
                    executeSave()
                }
                .accessibilityIdentifier("logSpending.overdrawConfirmButton")
            } message: {
                if let amount = parsedAmount {
                    Text("Logging \(CurrencyFormatter.string(amount)) exceeds the Spend balance of \(CurrencyFormatter.string(spendBalance)). Continue anyway?")
                }
            }
            .toastOverlay()
        }
    }

    private var parsedAmount: Double? {
        guard let value = CurrencyFormatter.decimalDouble(from: amountText), value.isFinite, value > 0 else { return nil }
        return value
    }

    private var spendBalance: Double {
        viewModel.currentSpendBalance(from: cachedLedgers)
    }

    /// WHY permit override: a purchase may intentionally take Spend negative, so warn inline plus confirm instead of blocking.
    private var isOverdrawn: Bool {
        guard isScopeResolved, let amount = parsedAmount else { return false }
        return amount > spendBalance
    }

    /// WHY fail-closed scope: an unresolved family fetches zero rows, so suppress the warning rather than flag every amount.
    private var isScopeResolved: Bool {
        guard let family = familyRecordName, !family.isEmpty else { return false }
        return true
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

    private func tappedSave() {
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDescription.isEmpty else {
            toastManager.show(message: "Please enter a description of what you bought.", type: .warning)
            return
        }
        guard parsedAmount != nil else {
            toastManager.show(message: "Please enter a valid positive amount.", type: .warning)
            return
        }
        if isOverdrawn {
            showOverdrawConfirm = true
        } else {
            executeSave()
        }
    }

    private func executeSave() {
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDescription.isEmpty else {
            toastManager.show(message: "Please enter a description of what you bought.", type: .warning)
            return
        }
        guard let amount = parsedAmount else {
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

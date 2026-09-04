//
//  HeroTransactionView.swift
//  LootList
//
//  Created by Ben Mackin on 8/13/26.
//

import SwiftData
import SwiftUI

enum HeroTransactionMode: Sendable {
    case deposit
    case withdraw

    var titlePrefix: String {
        switch self {
        case .deposit: "Deposit to"
        case .withdraw: "Withdraw from"
        }
    }

    var reasonPlaceholder: String {
        switch self {
        case .deposit: "Birthday check from Grandpa"
        case .withdraw: "Cash for camp event."
        }
    }

    var reasonFooter: String {
        switch self {
        case .deposit: "Describe why the money is being deposited."
        case .withdraw: "Describe why the money is being withdrawn — like \"Cash for camp event.\""
        }
    }

    var amountFooter: String {
        switch self {
        case .deposit: "Enter a positive number — this will be added to the balance."
        case .withdraw: "Enter a positive number — this will be deducted from the balance."
        }
    }

    var buttonTitle: String {
        switch self {
        case .deposit: "Add Deposit"
        case .withdraw: "Confirm Withdrawal"
        }
    }

    var actionIconName: String {
        switch self {
        case .deposit: "plus"
        case .withdraw: "minus"
        }
    }

    var iconTintColor: Color {
        switch self {
        case .deposit: Color.gold
        case .withdraw: Color(DesignSystemConstants.Colors.pendingAmber)
        }
    }

    var confirmButtonTintColor: Color? {
        switch self {
        case .deposit: nil
        case .withdraw: Color(DesignSystemConstants.Colors.pendingAmber)
        }
    }
}

struct HeroTransactionView: View {
    let mode: HeroTransactionMode
    @Bindable var viewModel: HeroLedgerViewModel
    let heroName: String

    @Environment(ToastManager.self) private var toastManager
    @Environment(\.dismiss) private var dismiss

    @Query private var cachedLedgers: [LedgerEntryCache]

    @State private var description: String = ""
    @State private var amountText: String = ""
    @State private var date: Date = .init()
    @State private var showOverdrawConfirm: Bool = false
    @FocusState private var isAmountFocused: Bool

    init(mode: HeroTransactionMode, viewModel: HeroLedgerViewModel, heroName: String) {
        self.mode = mode
        self.viewModel = viewModel
        self.heroName = heroName
        // WHY predicate pushdown: the sheet only needs this hero's rows to price the Spend warning.
        let targetFamily = viewModel.heroProfile.familyRecordName
        let targetProfile = viewModel.heroProfile.recordName
        let filter = #Predicate<LedgerEntryCache> { $0.familyRecordName == targetFamily && $0.profileRecordName == targetProfile }
        _cachedLedgers = Query(filter: filter, sort: \LedgerEntryCache.date, order: .reverse)
    }

    private var parsedAmount: Double? {
        guard let value = Self.parseAmount(amountText), value.isFinite, value > 0 else { return nil }
        return value
    }

    private var spendBalance: Double {
        viewModel.currentSpendBalance(from: cachedLedgers)
    }

    /// WHY permit override: a withdrawal may intentionally take Spend negative, so warn inline plus confirm instead of blocking.
    private var isOverdrawn: Bool {
        guard mode == .withdraw, let amount = parsedAmount else { return false }
        return amount > spendBalance
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(mode.reasonPlaceholder, text: $description, axis: .vertical)
                        .lineLimit(2 ... 6)
                } header: {
                    Text("Reason")
                } footer: {
                    Text(mode.reasonFooter)
                }

                Section {
                    HStack {
                        Image(systemName: "banknote")
                            .foregroundStyle(mode.iconTintColor)
                        TextField("2.50", text: $amountText)
                            .keyboardType(.decimalPad)
                            .focused($isAmountFocused)
                            .font(.body.monospacedDigit())
                    }
                } header: {
                    Text("Amount")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(mode.amountFooter)
                        if mode == .withdraw {
                            Text("Available in Spend: \(CurrencyFormatter.string(spendBalance))")
                            if isOverdrawn, let amount = parsedAmount {
                                Label {
                                    Text(
                                        "This withdrawal of \(CurrencyFormatter.string(amount)) exceeds "
                                            + "the Spend balance of \(CurrencyFormatter.string(spendBalance)). "
                                            + "Spend will go negative if you continue."
                                    )
                                } icon: {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                }
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color(DesignSystemConstants.Colors.dangerRed))
                                .accessibilityIdentifier("transaction.overdrawWarning")
                            }
                        }
                    }
                }

                Section("When") {
                    DatePicker(
                        "Date",
                        selection: $date,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                }
            }
            .formStyle(.grouped)
            .navigationTitle("\(mode.titlePrefix) \(heroName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                    }
                    .accessibilityLabel("Cancel")
                    .accessibilityIdentifier("transaction.cancelButton")
                    .disabled(viewModel.isLoading)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        tappedConfirm()
                    } label: {
                        if viewModel.isLoading {
                            ProgressView()
                        } else {
                            Image(systemName: mode.actionIconName)
                                .font(.body.weight(.semibold))
                        }
                    }
                    .accessibilityLabel(mode.buttonTitle)
                    .accessibilityIdentifier(mode == .deposit ? "transaction.depositButton" : "transaction.withdrawButton")
                    .disabled(viewModel.isLoading)
                    .modifier(OptionalForegroundModifier(color: mode.confirmButtonTintColor))
                }
            }
            .decimalPadDoneToolbar(isFocused: $isAmountFocused)
            .interactiveDismissDisabled(viewModel.isLoading)
            .alert("Spend Will Go Negative", isPresented: $showOverdrawConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Withdraw Anyway", role: .destructive) {
                    save()
                }
                .accessibilityIdentifier("transaction.overdrawConfirmButton")
            } message: {
                if let amount = parsedAmount {
                    Text("Withdrawing \(CurrencyFormatter.string(amount)) exceeds the Spend balance of \(CurrencyFormatter.string(spendBalance)). Continue anyway?")
                }
            }
            .toastOverlay()
        }
    }

    private func tappedConfirm() {
        if isOverdrawn {
            showOverdrawConfirm = true
        } else {
            save()
        }
    }

    private func save() {
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDescription.isEmpty else {
            toastManager.show(
                message: "Please enter a reason for the \(mode == .deposit ? "deposit" : "withdrawal").",
                type: .warning
            )
            return
        }
        // Locale-aware parsing — handles comma decimal separators.
        guard let amount = Self.parseAmount(amountText), amount.isFinite, amount > 0 else {
            toastManager.show(message: "Please enter a valid positive amount.", type: .warning)
            return
        }
        Task {
            let success = (mode == .deposit)
                ? await viewModel.deposit(description: trimmedDescription, amount: amount, date: date)
                : await viewModel.withdraw(description: trimmedDescription, amount: amount, date: date)
            if success {
                toastManager.show(
                    message: mode == .deposit ? "Deposit added!" : "Withdrawal saved!",
                    type: .success
                )
                dismiss()
            } else if let error = viewModel.errorMessage {
                toastManager.show(message: error, type: .error)
            }
        }
    }

    // MARK: - Parsing

    /// Parses amount using the current locale, falling back to dot-normalized Double.
    static func parseAmount(_ text: String) -> Double? {
        CurrencyFormatter.decimalDouble(from: text)
    }
}

private struct OptionalForegroundModifier: ViewModifier {
    let color: Color?

    func body(content: Content) -> some View {
        if let color {
            content.foregroundStyle(color)
        } else {
            content
        }
    }
}

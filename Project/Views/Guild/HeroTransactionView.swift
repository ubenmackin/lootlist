//
//  HeroTransactionView.swift
//  LootList
//
//  Created by Ben Mackin on 8/13/26.
//

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

    @State private var description: String = ""
    @State private var amountText: String = ""
    @State private var date: Date = .init()
    @FocusState private var isAmountFocused: Bool

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
                    Text(mode.amountFooter)
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
                    Button(action: save) {
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
            .toastOverlay()
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
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let formatter = NumberFormatter()
        formatter.locale = Locale.current
        formatter.numberStyle = .decimal
        if let number = formatter.number(from: trimmed) {
            return number.doubleValue
        }
        // Fallback for pasted values with comma separator.
        let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
        return Double(normalized)
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

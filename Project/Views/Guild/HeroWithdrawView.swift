//
//  HeroWithdrawView.swift
//  LootList
//
//  Created by Ben Mackin on 8/8/26.
//

import SwiftUI

struct HeroWithdrawView: View {
    @Bindable var viewModel: HeroLedgerViewModel
    let heroName: String

    @Environment(ToastManager.self) private var toastManager
    @Environment(\.dismiss) private var dismiss

    @State private var description: String = ""
    @State private var amountText: String = ""
    @State private var date: Date = .init()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Cash for camp event.", text: $description, axis: .vertical)
                        .lineLimit(2 ... 6)
                } header: {
                    Text("Reason")
                } footer: {
                    Text("Describe why the money is being withdrawn — like \"Cash for camp event.\"")
                }

                Section {
                    HStack {
                        Image(systemName: "banknote")
                            .foregroundStyle(Color.orange)
                        TextField("2.50", text: $amountText)
                            .keyboardType(.decimalPad)
                            .font(.body.monospacedDigit())
                    }
                } header: {
                    Text("Amount")
                } footer: {
                    Text("Enter a positive number — this will be deducted from the balance.")
                }

                Section("When") {
                    DatePicker("Date",
                               selection: $date,
                               displayedComponents: [.date, .hourAndMinute])
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Withdraw from \(heroName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(viewModel.isLoading)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: save) {
                        if viewModel.isLoading {
                            ProgressView()
                        } else {
                            Text("Confirm Withdrawal")
                        }
                    }
                    .disabled(viewModel.isLoading)
                    .foregroundStyle(Color.orange)
                }
            }
            .interactiveDismissDisabled(viewModel.isLoading)
            .toastOverlay()
        }
    }

    private func save() {
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDescription.isEmpty else {
            toastManager.show(message: "Please enter a reason for the withdrawal.", type: .warning)
            return
        }
        guard let amount = Double(amountText), amount.isFinite, amount > 0 else {
            toastManager.show(message: "Please enter a valid positive amount.", type: .warning)
            return
        }
        Task {
            let success = await viewModel.withdraw(
                description: trimmedDescription,
                amount: amount,
                date: date
            )
            if success {
                dismiss()
            } else if let error = viewModel.errorMessage {
                toastManager.show(message: error, type: .error)
            }
        }
    }
}

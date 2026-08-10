//
//  HeroDepositView.swift
//  LootList
//
//  Created by Ben Mackin on 8/8/26.
//

import SwiftUI

struct HeroDepositView: View {
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
                    TextField("Birthday check from Grandpa", text: $description, axis: .vertical)
                        .lineLimit(2 ... 6)
                } header: {
                    Text("Reason")
                } footer: {
                    Text("Describe why the money is being deposited.")
                }

                Section {
                    HStack {
                        Image(systemName: "banknote")
                            .foregroundStyle(Color.gold)
                        TextField("2.50", text: $amountText)
                            .keyboardType(.decimalPad)
                            .font(.body.monospacedDigit())
                    }
                } header: {
                    Text("Amount")
                } footer: {
                    Text("Enter a positive number — this will be added to the balance.")
                }

                Section("When") {
                    DatePicker("Date",
                               selection: $date,
                               displayedComponents: [.date, .hourAndMinute])
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Deposit to \(heroName)")
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
                            Text("Add Deposit")
                        }
                    }
                    .disabled(viewModel.isLoading)
                }
            }
            .interactiveDismissDisabled(viewModel.isLoading)
            .toastOverlay()
        }
    }

    private func save() {
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDescription.isEmpty else {
            toastManager.show(message: "Please enter a reason for the deposit.", type: .warning)
            return
        }
        guard let amount = Double(amountText), amount.isFinite, amount > 0 else {
            toastManager.show(message: "Please enter a valid positive amount.", type: .warning)
            return
        }
        Task {
            let success = await viewModel.deposit(
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

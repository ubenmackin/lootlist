import SwiftUI

struct LogSpendingView: View {
    @Bindable var viewModel: TreasuryViewModel

    @Environment(\.dismiss) private var dismiss

    @State private var description: String = ""

    @State private var amountText: String = ""

    @State private var date: Date = .init()

    @State private var isSaving: Bool = false

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
                    Text("Tell the tale of where your gold went — a short memory like \"Snack at the market.\"")
                }

                Section {
                    HStack {
                        Image(systemName: GoldFormat.coinSystemName)
                            .foregroundStyle(Color.gold)
                        TextField("2.50", text: $amountText)
                            .keyboardType(.decimalPad)
                            .font(.body.monospacedDigit())
                    }
                } header: {
                    Text("Gold Amount")
                } footer: {
                    Text("Enter a positive number — this becomes a debit against your balance.")
                }

                Section("When") {
                    DatePicker("Date",
                               selection: $date,
                               displayedComponents: [.date, .hourAndMinute])
                }

                if let error = viewModel.errorMessage, !error.isEmpty {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.subheadline)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Scroll of Spending")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: save) {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text("Add to Scroll")
                        }
                    }
                    .disabled(!canSave || isSaving)
                }
            }
            .interactiveDismissDisabled(isSaving)
        }
    }

    private var canSave: Bool {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let amount = Double(amountText), amount.isFinite, amount > 0 else {
            return false
        }
        return true
    }

    private func save() {
        guard let amount = Double(amountText), amount.isFinite, amount > 0 else {
            return
        }
        isSaving = true
        Task {
            let success = await viewModel.logSpending(
                description: description,
                amount: amount,
                date: date
            )
            isSaving = false
            if success {
                dismiss()
            }
        }
    }
}

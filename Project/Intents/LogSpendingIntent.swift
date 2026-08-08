//
//  LogSpendingIntent.swift
//  LootList
//
//  Created by Ben Mackin on 8/6/26.
//

import AppIntents
import Foundation
import SwiftData

struct LogSpendingIntent: AppIntent, Sendable {
    static let title: LocalizedStringResource = "Log Spending"
    static let description = IntentDescription("Logs spending or a transaction on your scroll.")

    @Parameter(title: "Amount")
    var amount: Double

    @Parameter(title: "What did you buy?")
    var itemDescription: String

    @Parameter(title: "Location or Store")
    var location: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let dep = AppDependencies.shared,
              let profile = dep.appState.currentProfile,
              let family = dep.appState.family
        else {
            return .result(dialog: "LootList isn't running. Open the app first.")
        }

        guard amount.isFinite, amount > 0 else {
            return .result(dialog: "Please specify a valid spending amount.")
        }

        let fullDescription: String = if let location = location?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty {
            "\(itemDescription) at \(location)"
        } else {
            itemDescription
        }

        do {
            _ = try await dep.spendingService.logManual(
                profile: profile,
                family: family,
                familyRecordName: family.id.recordName,
                description: fullDescription,
                amount: amount,
                date: Date()
            )
            let formattedAmount = CurrencyFormatter.string(amount)
            return .result(dialog: "Logged spending of \(formattedAmount) for \(fullDescription).")
        } catch let err as SpendingServiceError {
            return .result(dialog: IntentDialog(stringLiteral: err.errorDescription ?? "Could not log spending."))
        } catch {
            return .result(dialog: "Could not log spending: \(error.localizedDescription)")
        }
    }
}

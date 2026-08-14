//
//  LogSpendingIntent.swift
//  LootList
//
//  Created by Ben Mackin on 8/6/26.
//

import AppIntents
import Foundation
import os
import SwiftData

struct LogSpendingIntent: AppIntent, Sendable {
    static let title: LocalizedStringResource = "Log Spending"
    static let description = IntentDescription("Logs spending or a transaction on your scroll.")

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "LogSpendingIntent")

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

        let trimmedLocation = location?.trimmingCharacters(in: .whitespacesAndNewlines)
        let locationValue = (trimmedLocation?.isEmpty == false) ? trimmedLocation : nil

        do {
            _ = try await dep.spendingService.logManual(
                profile: profile,
                family: family,
                familyRecordName: family.id.recordName,
                description: itemDescription,
                amount: amount,
                location: locationValue,
                date: Date()
            )
            let formattedAmount = CurrencyFormatter.string(amount)
            let descStr = if let locationValue {
                "\(itemDescription) at \(locationValue)"
            } else {
                itemDescription
            }
            return .result(dialog: "Logged spending of \(formattedAmount) for \(descStr).")
        } catch let err as SpendingServiceError {
            return .result(dialog: IntentDialog(stringLiteral: err.errorDescription ?? "Could not log spending."))
        } catch {
            logger.error("Failed to log spending: \(error, privacy: .private)")
            return .result(dialog: "Could not log your spending. Please try again.")
        }
    }
}

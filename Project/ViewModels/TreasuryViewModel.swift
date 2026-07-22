import Foundation
import CloudKit
import Observation

@MainActor
@Observable
final class TreasuryViewModel {

    private let treasury: TreasuryService

    private let spending: any SpendingService

    private let appState: AppState

    private(set) var balance: Double?

    private(set) var weeklyBreakdown: TreasuryService.WeeklyBreakdown?

    private(set) var allowancePeriod: AllowancePeriod?

    private(set) var spendingLog: [LedgerEntry] = []

    private(set) var isLoading: Bool = false

    private(set) var errorMessage: String?

    init(treasury: TreasuryService,
         spending: any SpendingService,
         appState: AppState) {
        self.treasury = treasury
        self.spending = spending
        self.appState = appState
    }

    func refresh() async {
        guard let profile = appState.currentProfile,
              let family = appState.family else {
            errorMessage = "No hero profile loaded."
            return
        }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            balance = try await treasury.currentBalance(for: profile)
            weeklyBreakdown = try await treasury.weeklyBreakdown(
                profile: profile, weekOf: Date()
            )
            allowancePeriod = try await treasury.getOrCreateAllowancePeriod(
                profile: profile, weekOf: Date(), family: family
            )
            await loadSpendingLog(showAllTime: false)
        } catch {
            errorMessage = "\(error)"
        }
    }

    func loadSpendingLog(showAllTime: Bool) async {
        guard let profile = appState.currentProfile else {
            errorMessage = "No hero profile loaded."
            return
        }
        let range: DateInterval = showAllTime
            ? DateInterval(start: .distantPast, end: .distantFuture)
            : TreasuryService.weekRange(
                starting: TreasuryService.mondayOfWeek(for: Date())
              )
        do {
            spendingLog = try await spending.fetchTransactions(
                for: profile, in: range
            )
        } catch {
            errorMessage = "\(error)"
        }
    }

    @discardableResult
    func logSpending(description: String,
                     amount: Double,
                     date: Date = Date()) async -> Bool {
        let trimmed = description.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty else {
            errorMessage = "Describe your spending first."
            return false
        }
        guard amount.isFinite, amount > 0 else {
            errorMessage = "Enter a positive gold amount."
            return false
        }
        guard let profile = appState.currentProfile,
              let family = appState.family else {
            errorMessage = "No hero profile loaded."
            return false
        }

        do {
            _ = try await spending.logManual(
                profile: profile,
                family: family,
                description: trimmed,
                amount: amount,
                date: date
            )
            errorMessage = nil
            await refresh()
            return true
        } catch {
            errorMessage = "\(error)"
            return false
        }
    }

    var canLogManually: Bool { spending.isAvailable() }

    func reset() {
        balance = nil
        weeklyBreakdown = nil
        allowancePeriod = nil
        spendingLog = []
        errorMessage = nil
        isLoading = false
    }
}

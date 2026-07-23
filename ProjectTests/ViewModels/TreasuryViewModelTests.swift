import Foundation
import Testing
import CloudKit
@testable import LootList

final class MockSpendingService: SpendingService, @unchecked Sendable {
    var transactions: [LedgerEntry] = []
    var isAvailableValue: Bool = true
    var shouldFail: Bool = false

    func isAvailable() -> Bool {
        isAvailableValue
    }

    func fetchTransactions(for profile: Profile, in dateRange: DateInterval) async throws -> [LedgerEntry] {
        if shouldFail {
            throw SpendingServiceError.underlying("Mock error")
        }
        return transactions
    }

    func logManual(profile: Profile, family: Family, description: String, amount: Double, date: Date) async throws -> LedgerEntry {
        if shouldFail {
            throw SpendingServiceError.underlying("Mock error")
        }
        let entry = LedgerEntry(
            profile: CKRecord.Reference(recordID: profile.id, action: .none),
            amount: -abs(amount),
            description: description,
            date: date,
            source: "manual",
            family: CKRecord.Reference(recordID: family.id, action: .none)
        )
        transactions.append(entry)
        return entry
    }
}

@MainActor
struct TreasuryViewModelTests {

    @Test("Logging spending with empty description fails validation")
    func testLogSpendingEmptyDescription() async {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = CloudKitService(zoneID: zoneID)
        let treasury = TreasuryService(cloudKit: cloudKit)
        let spendingMock = MockSpendingService()
        let appState = AppState()

        let viewModel = TreasuryViewModel(treasury: treasury, spending: spendingMock, appState: appState)

        let success = await viewModel.logSpending(description: "   ", amount: 10.0)
        #expect(success == false)
        #expect(viewModel.errorMessage == "Describe your spending first.")
    }

    @Test("Logging spending with negative or zero amount fails validation")
    func testLogSpendingInvalidAmount() async {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = CloudKitService(zoneID: zoneID)
        let treasury = TreasuryService(cloudKit: cloudKit)
        let spendingMock = MockSpendingService()
        let appState = AppState()

        let viewModel = TreasuryViewModel(treasury: treasury, spending: spendingMock, appState: appState)

        let successNegative = await viewModel.logSpending(description: "Spellbook", amount: -5.0)
        #expect(successNegative == false)
        #expect(viewModel.errorMessage == "Enter a positive gold amount.")

        let successZero = await viewModel.logSpending(description: "Potion", amount: 0)
        #expect(successZero == false)
        #expect(viewModel.errorMessage == "Enter a positive gold amount.")
    }
}

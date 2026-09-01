//
//  LedgerImportViewModel.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import Foundation
import Observation
import os

@MainActor
@Observable
final class LedgerImportViewModel {
    private let importService: LedgerImportService
    private let appState: AppState
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "LedgerImport")

    private(set) var stagedRows: [StagedImportRow] = []
    private(set) var errorMessage: String?
    private(set) var isFinalizing: Bool = false

    /// Flips once finalization succeeds so the presenting sheet can dismiss.
    private(set) var didComplete: Bool = false

    /// WHY @Query count feedback: LedgerImportView observes LedgerEntryCache
    /// directly so the post-import count updates the moment finalize's
    /// deterministic `import-` rows land in cache, without waiting for a
    /// parent list refresh or manual fetch.
    private(set) var importedCount: Int = 0

    let familyRecordName: String?

    init(importService: LedgerImportService, appState: AppState, familyRecordName: String?) {
        self.importService = importService
        self.appState = appState
        self.familyRecordName = familyRecordName ?? appState.family?.id.recordName
    }

    // MARK: - Derived state

    var includedRows: [StagedImportRow] {
        stagedRows.filter { !$0.isExcluded }
    }

    var blockedRowCount: Int {
        LedgerImportService.blockingRows(in: stagedRows).count
    }

    var totalAmount: Double {
        includedRows.compactMap(\.amount).reduce(0, +)
    }

    /// Finalization stays blocked until every included row has a child
    /// assignment and fully parseable fields — unassigned rows never guess.
    var canFinalize: Bool {
        !includedRows.isEmpty && blockedRowCount == 0 && !isFinalizing
    }

    // MARK: - Staging

    func stage(csvText: String) {
        let rows = importService.stage(csvText: csvText)
        stagedRows = autoAssign(children: childProfiles, to: rows)
        if rows.isEmpty {
            errorMessage = "No transactions found in that file."
        }
    }

    func clearStaging() {
        stagedRows = []
        errorMessage = nil
    }

    func assign(rowID: String, to profileCache: ProfileCache?) {
        mutateRow(rowID) { row in
            row.assignedProfileRecordName = profileCache?.recordName
        }
    }

    func setExcluded(rowID: String, _ excluded: Bool) {
        mutateRow(rowID) { row in
            row.isExcluded = excluded
        }
    }

    func updateDescription(rowID: String, text: String) {
        mutateRow(rowID) { row in
            row.descriptionText = text
        }
    }

    func updateMerchant(rowID: String, text: String) {
        mutateRow(rowID) { row in
            row.merchant = text
        }
    }

    /// Re-parses on every keystroke so a fix clears the inline issue flag
    /// the moment the text becomes readable.
    func updateAmount(rowID: String, text: String) {
        mutateRow(rowID) { row in
            row.amountText = text
            row.amount = LedgerCSVParser.parseAmount(text)
            refreshIssue(on: &row)
        }
    }

    func updateDate(rowID: String, text: String) {
        mutateRow(rowID) { row in
            row.dateText = text
            row.date = LedgerCSVParser.parseDate(text)
            refreshIssue(on: &row)
        }
    }

    // MARK: - Finalization

    func finalize() async -> Bool {
        guard canFinalize else { return false }
        guard let family = appState.family else {
            errorMessage = "No family loaded."
            return false
        }

        isFinalizing = true
        defer { isFinalizing = false }

        do {
            let summary = try await importService.finalize(stagedRows, family: family)
            logger.info("Import confirmed: \(summary.importedCount) imported, \(summary.skippedDuplicates) duplicates skipped")
            didComplete = true
            // WHY trigger sync after upsert: cache write gives instant UI via
            // @Query, but CloudKit still needs the pending save. Rely on the
            // view's LedgerEntryCache @Query to refresh the count.
            await importService.syncCoordinator.sendPendingChanges()
            return true
        } catch {
            logger.error("Import finalization failed: \(error, privacy: .private)")
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Could not import transactions."
            return false
        }
    }

    /// Called from LedgerImportView's `onChange(of: importedLedgers)` so the
    /// ViewModel rebuild observes cache changes without a parent-list refresh.
    func updateImportedCount(_ count: Int) {
        importedCount = count
    }

    func updateImportedCount(from ledgers: [LedgerEntryCache]) {
        importedCount = ledgers.count
    }

    func loadingFailed(_ message: String) {
        stagedRows = []
        errorMessage = message
    }

    // MARK: - Child profiles

    /// Assignment options are actual child profiles only — parents and
    /// Rangers are never valid "Purchased By" targets.
    var childProfiles: [ProfileCache] {
        guard let familyRecordName else { return [] }
        return (appState.cacheService?.fetchProfiles(family: familyRecordName) ?? [])
            .filter { $0.roleEnum == .hero && $0.isActive }
    }

    /// Pre-selects assignments by matching the raw "Purchased By" cell against
    /// child display names; ambiguous or unknown names stay UNASSIGNED for the
    /// parent to resolve explicitly.
    private func autoAssign(children: [ProfileCache], to rows: [StagedImportRow]) -> [StagedImportRow] {
        guard !children.isEmpty else { return rows }
        return rows.map { row in
            var row = row
            guard let rawName = row.purchasedByRaw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawName.isEmpty
            else { return row }

            let lowered = rawName.lowercased()
            let matches = children.filter { $0.displayName.lowercased() == lowered }
            if matches.count == 1, let first = matches.first {
                row.assignedProfileRecordName = first.recordName
            }
            return row
        }
    }

    private func refreshIssue(on row: inout StagedImportRow) {
        var issues: [String] = []
        if row.date == nil {
            issues.append("Unreadable date")
        }
        if row.amount == nil {
            issues.append("Unreadable amount")
        }
        row.parseIssue = issues.isEmpty ? nil : issues.joined(separator: ", ")
    }

    private func mutateRow(_ rowID: String, _ transform: (inout StagedImportRow) -> Void) {
        guard let index = stagedRows.firstIndex(where: { $0.id == rowID }) else { return }
        transform(&stagedRows[index])
    }
}

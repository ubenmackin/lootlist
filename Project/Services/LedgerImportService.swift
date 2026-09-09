//
//  LedgerImportService.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import CloudKit
import CryptoKit
import Foundation
import os

/// WHY staging: malformed rows persist for explicit parent fix, never silent drop.
struct StagedImportRow: Identifiable, Equatable {
    /// WHY stable identity: line plus content digest keeps duplicate rows distinct.
    let id: String

    let lineNumber: Int

    var descriptionText: String
    var merchant: String
    var amountText: String
    var dateText: String

    /// WHY pre-select: raw cell matches child display names for assignment dropdown.
    var purchasedByRaw: String?

    var date: Date?
    /// WHY signed pennies: CSV amounts debit spend consistently.
    var amount: Int64?

    var assignedProfileRecordName: String?
    var isExcluded: Bool = false

    var parseIssue: String?

    var isAssigned: Bool {
        assignedProfileRecordName != nil
    }
}

enum LedgerImportError: Error, LocalizedError, Equatable {
    case unauthorized
    case noActiveFamily
    case nothingToImport
    case blockedRows(Int)
    case persistenceFailed

    var errorDescription: String? {
        switch self {
        case .unauthorized: "Only parents can import transactions."
        case .noActiveFamily: "No active family loaded."
        case .nothingToImport: "There are no included rows to import."
        case let .blockedRows(count): "\(count) row(s) still need an assignment or a fix."
        case .persistenceFailed: "Could not save the import. Please try again."
        }
    }
}

/// WHY staging: CSV text becomes editable rows before any ledger write.
enum LedgerCSVParser {
    static func parse(_ csvText: String) -> [StagedImportRow] {
        let records = tokenize(csvText)
        guard let firstRecord = records.first else { return [] }

        // WHY content header: exports with or without header share one mapping.
        let headerNames = firstRecord.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let isHeader = headerNames.contains("transaction date") && headerNames.contains("amount")
        let columns = isHeader ? ColumnMapping(header: headerNames) : .positional
        let dataRecords = isHeader ? Array(records.dropFirst()) : records

        return dataRecords.enumerated().compactMap { index, fields in
            let lineNumber = index + (isHeader ? 2 : 1)
            if fields.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                return nil
            }
            return makeRow(lineNumber: lineNumber, columns: columns, fields: fields)
        }
    }

    private struct ColumnMapping {
        let transactionDate: Int
        let descriptionColumn: Int
        let merchant: Int
        let amount: Int
        let purchasedBy: Int?

        static let positional = ColumnMapping(
            transactionDate: 0, descriptionColumn: 1, merchant: 2, amount: 3, purchasedBy: 4
        )

        init(transactionDate: Int, descriptionColumn: Int, merchant: Int, amount: Int, purchasedBy: Int?) {
            self.transactionDate = transactionDate
            self.descriptionColumn = descriptionColumn
            self.merchant = merchant
            self.amount = amount
            self.purchasedBy = purchasedBy
        }

        init(header: [String]) {
            func index(of name: String) -> Int? {
                header.firstIndex(where: { $0.contains(name) })
            }
            transactionDate = index(of: "transaction date") ?? 0
            descriptionColumn = index(of: "description") ?? 1
            merchant = index(of: "merchant") ?? 2
            amount = index(of: "amount") ?? 3
            purchasedBy = index(of: "purchased")
        }
    }

    private static func makeRow(lineNumber: Int, columns: ColumnMapping, fields: [String]) -> StagedImportRow {
        func field(_ index: Int?) -> String? {
            guard let index, fields.indices.contains(index) else { return nil }
            var value = fields[index].trimmingCharacters(in: .whitespacesAndNewlines)
            // Strips leading formula-guard apostrophe from CSV cells.
            if value.hasPrefix("'"), value.dropFirst().first.map({ "=+-@".contains($0) }) == true {
                value.removeFirst()
            }
            return value.isEmpty ? nil : value
        }

        let dateRaw = field(columns.transactionDate)
        let descriptionRaw = field(columns.descriptionColumn)
        let merchantRaw = field(columns.merchant)
        let amountRaw = field(columns.amount)
        let parsedDate = dateRaw.flatMap(parseDate)
        let parsedAmount = amountRaw.flatMap(parseAmount)

        var issue: String?
        if dateRaw == nil || parsedDate == nil {
            issue = "Unreadable date"
        }
        if amountRaw == nil || parsedAmount == nil {
            issue = issue.map { "\($0), unreadable amount" } ?? "Unreadable amount"
        }

        let rawCells = [dateRaw, descriptionRaw, merchantRaw, amountRaw]
        let digest = SHA256.hash(data: Data(rawCells.compactMap(\.self).joined(separator: "|").utf8))
        let fingerprint = digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } % 1_000_000_007

        return StagedImportRow(
            id: "\(lineNumber)-\(fingerprint)",
            lineNumber: lineNumber,
            descriptionText: descriptionRaw ?? "",
            merchant: merchantRaw ?? "",
            amountText: amountRaw ?? "",
            dateText: dateRaw ?? "",
            purchasedByRaw: field(columns.purchasedBy),
            date: parsedDate,
            amount: parsedAmount,
            parseIssue: issue
        )
    }

    /// WHY RFC4180: quoted fields carry commas, newlines, and escaped quotes.
    static func tokenize(_ csvText: String) -> [[String]] {
        let chars = Array(csvText)
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var inQuotes = false
        var charIndex = 0

        while charIndex < chars.count {
            let currentChar = chars[charIndex]
            if inQuotes {
                if currentChar == "\"" {
                    if charIndex + 1 < chars.count, chars[charIndex + 1] == "\"" {
                        field.append("\"")
                        charIndex += 2
                    } else {
                        inQuotes = false
                        charIndex += 1
                    }
                } else {
                    field.append(currentChar)
                    charIndex += 1
                }
            } else {
                switch currentChar {
                case "\"":
                    inQuotes = true
                    charIndex += 1
                case ",":
                    record.append(field)
                    field = ""
                    charIndex += 1
                case "\r":
                    charIndex += 1
                case "\n":
                    record.append(field)
                    records.append(record)
                    record = []
                    field = ""
                    charIndex += 1
                default:
                    field.append(currentChar)
                    charIndex += 1
                }
            }
        }
        if !field.isEmpty || !record.isEmpty {
            record.append(field)
            records.append(record)
        }
        return records
    }

    /// WHY bank exports: thousands separators strip before numeric conversion.
    static func parseAmount(_ raw: String) -> Int64? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        var negative = false
        if text.hasPrefix("("), text.hasSuffix(")") {
            negative = true
            text = String(text.dropFirst().dropLast())
        }
        text = text.replacingOccurrences(of: CurrencyFormatter.currencySymbol, with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if text.hasPrefix("-") {
            negative.toggle()
            text.removeFirst()
        } else if text.hasPrefix("+") {
            text.removeFirst()
        }

        guard let value = Double(text), value.isFinite else { return nil }
        let pennies = CurrencyFormatter.dollarsToPennies(value)
        return negative ? -abs(pennies) : pennies
    }

    /// WHY flexible dates: ISO and US bank formats share one parser.
    static func parseDate(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let isoFull = ISO8601DateFormatter()
        isoFull.formatOptions = [.withInternetDateTime]
        if let date = isoFull.date(from: text) {
            return date
        }

        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFractional.date(from: text) {
            return date
        }

        let formats = [
            "yyyy-MM-dd",
            "MM/dd/yyyy",
            "M/d/yyyy",
            "MM/dd/yyyy h:mm a",
            "MM/dd/yy",
            "MMM d, yyyy",
            "MMMM d, yyyy"
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) {
                return date
            }
        }
        return nil
    }
}

// WHY deterministic import: confirmed rows mint stable IDs without touching ledger pre-confirm.
#if DEBUG
    /// WHY test seam: cache-only coordination keeps reads deterministic.
    @MainActor
    extension NoopSyncEnqueuing: SyncCoordinating {}
#endif

@MainActor
@Observable
final class LedgerImportService {
    private let cloudKit: any CloudKitServiceProtocol
    let cacheService: any CacheServicing
    let syncCoordinator: any SyncEnqueuing & SyncCoordinating
    let appState: AppState

    private static let staticLogger = Logger(category: "LedgerImport")
    private let logger = Logger(category: "LedgerImport")

    struct FinalizeSummary: Equatable, Sendable {
        let importedCount: Int
        let skippedDuplicates: Int
    }

    init(
        cloudKit: any CloudKitServiceProtocol,
        cacheService: any CacheServicing,
        appState: AppState,
        syncCoordinator: any SyncEnqueuing & SyncCoordinating
    ) {
        self.cloudKit = cloudKit
        self.cacheService = cacheService
        self.appState = appState
        self.syncCoordinator = syncCoordinator
    }

    @_disfavoredOverload
    convenience init(
        cloudKit: any CloudKitServiceProtocol,
        cacheService: (any CacheServicing)? = nil,
        appState: AppState? = nil,
        syncCoordinator: (any SyncEnqueuing & SyncCoordinating)? = nil
    ) {
        let cache: any CacheServicing
        if let cacheService {
            cache = cacheService
        } else {
            Self.staticLogger.warning("LedgerImportService initialized without cacheService; using fallback in-memory cache.")
            cache = CacheService.inMemoryFallback(logger: Self.staticLogger)
        }
        let state = appState ?? AppState()
        // WHY single stack: shared coordinator owns hydration; ephemeral engines fork freshness.
        if let coord: any SyncEnqueuing & SyncCoordinating = syncCoordinator ?? AppDependencies.shared?.syncCoordinator {
            self.init(cloudKit: cloudKit, cacheService: cache, appState: state, syncCoordinator: coord)
        } else {
            #if DEBUG
                // WHY test seam: cache-only coordination keeps reads deterministic.
                if TestEnvironment.isRunningUnitOrUITests {
                    Self.staticLogger.warning("LedgerImportService initialized without syncCoordinator; using test Noop seam.")
                } else {
                    Self.staticLogger.error("LedgerImportService initialized without syncCoordinator and no shared coordinator; falling back to Noop seam.")
                }
                self.init(cloudKit: cloudKit, cacheService: cache, appState: state, syncCoordinator: NoopSyncEnqueuing())
            #else
                // WHY fail-closed: production without engine must not drop writes.
                preconditionFailure("LedgerImportService requires a sync coordinator in production")
            #endif
        }
    }

    // MARK: - Staging

    func stage(csvText: String) -> [StagedImportRow] {
        LedgerCSVParser.parse(csvText)
    }

    // MARK: - Deterministic IDs

    /// WHY distinct identity: assigned child is part of the content hash.
    static func recordName(for row: StagedImportRow, profileRecordName: String) -> String {
        let cents = Int(row.amount ?? 0)
        // WHY sentinel: blockingRows gates nil dates, but direct callers still converge on a stable value.
        let rowDate = row.date ?? Date(timeIntervalSince1970: 0)
        let timestamp = Int(rowDate.timeIntervalSince1970)
        let canonical = [
            row.descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            row.merchant.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            String(cents),
            String(timestamp),
            profileRecordName
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        let hex = digest.shortHex
        return DeterministicRecordID.import(hex: hex)
    }

    /// WHY explicit gate: excluded rows never block finalization.
    static func blockingRows(in stagedRows: [StagedImportRow]) -> [StagedImportRow] {
        stagedRows.filter { row in
            !row.isExcluded && (!row.isAssigned || row.parseIssue != nil || row.amount == nil || row.date == nil)
        }
    }

    // MARK: - Finalization

    func finalize(_ stagedRows: [StagedImportRow], family: Family) async throws -> FinalizeSummary {
        guard let acting = appState.currentProfile, acting.role.isParent else {
            throw FamilyServiceError.unauthorized
        }
        // WHY fail-closed: production without engine must not drop writes.
        #if !DEBUG
            guard !(syncCoordinator is NoopSyncEnqueuing) else {
                throw LedgerImportError.persistenceFailed
            }
        #else
            if !TestEnvironment.isRunningUnitOrUITests, syncCoordinator is NoopSyncEnqueuing {
                throw LedgerImportError.persistenceFailed
            }
        #endif
        try validateScope(family: family)

        let included = stagedRows.filter { !$0.isExcluded }
        let blockers = Self.blockingRows(in: stagedRows)
        guard blockers.isEmpty else {
            throw LedgerImportError.blockedRows(blockers.count)
        }
        guard !included.isEmpty else {
            throw LedgerImportError.nothingToImport
        }

        let zoneID = appState.resolvedFamilyZoneID()
        var importedCount = 0
        var skippedDuplicates = 0

        for row in included {
            guard let profileRecordName = row.assignedProfileRecordName,
                  let amount = row.amount,
                  let date = row.date
            else { continue }

            let recordName = Self.recordName(for: row, profileRecordName: profileRecordName)
            // WHY idempotent: deterministic ID already cached means row was confirmed before.
            if cacheService.fetchLedgerEntry(recordName: recordName, family: family.id.recordName) != nil {
                skippedDuplicates += 1
                continue
            }

            // WHY spend debit: imports keep bucket balances consistent with ledger total.
            let entry = LedgerEntry(
                profile: CKRecord.Reference(
                    recordID: CKRecord.ID(recordName: profileRecordName, zoneID: zoneID),
                    action: .none
                ),
                amount: amount,
                description: trimmedNonEmpty(row.descriptionText) ?? "Imported transaction",
                location: trimmedNonEmpty(row.merchant),
                date: date,
                source: LedgerSource.import.rawValue,
                bucketKind: BucketKind.spend.rawValue,
                family: CKRecord.Reference(recordID: family.id, action: .none),
                id: CKRecord.ID(recordName: recordName, zoneID: zoneID)
            )

            await cacheService.upsertLedgerEntry(entry)
            ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(syncCoordinator, id: entry.id, appState: appState, logger: logger, context: "LedgerImportService.finalizeImport")
            importedCount += 1
        }

        logger.info("Ledger import finalized: \(importedCount) created, \(skippedDuplicates) duplicates skipped")
        return FinalizeSummary(importedCount: importedCount, skippedDuplicates: skippedDuplicates)
    }

    // MARK: - Helpers

    private func trimmedNonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func validateScope(family: Family) throws {
        // WHY fail-closed: tests establish full session, never family-only fallback.
        try ActiveFamilyScopeGuard.requireActiveFamilyScope(family: family, cloudKit: cloudKit, appState: appState)
    }
}

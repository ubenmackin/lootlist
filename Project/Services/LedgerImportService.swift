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

/// One CSV line held in staging until the parent confirms the import.
/// Malformed rows stay present with `parseIssue` set — they are never
/// dropped silently, so the parent can fix or exclude them explicitly.
struct StagedImportRow: Identifiable, Equatable {
    /// Stable identity for staging edits: line number plus a content digest,
    /// so duplicate rows in one file keep distinct identities while edits
    /// never re-key the row mid-review.
    let id: String

    let lineNumber: Int

    var descriptionText: String
    var merchant: String
    var amountText: String
    var dateText: String

    /// Raw "Purchased By" cell as written in the file; matched against child
    /// profile display names to pre-select the assignment dropdown.
    var purchasedByRaw: String?

    var date: Date?
    var amount: Double?

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

/// Parses ledger CSV imports into editable staging rows.
enum LedgerCSVParser {
    static func parse(_ csvText: String) -> [StagedImportRow] {
        let records = tokenize(csvText)
        guard let firstRecord = records.first else { return [] }

        // Header detection is content-based so exports with or without a
        // header land on the same column mapping; unknown headers fall back
        // to the export's canonical column order.
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

    /// RFC4180-style tokenizer: quoted fields may contain commas, newlines,
    /// and escaped double quotes (""). CRLF and bare LF both end records.
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

    /// Accepts currency amounts like "12.50", "(12.50)", "-12.5", "1,234.56", and bare decimals.
    /// Thousands separators are stripped before numeric conversion because
    /// bank-style exports quote amounts containing commas.
    static func parseAmount(_ raw: String) -> Double? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        var negative = false
        if text.hasPrefix("("), text.hasSuffix(")") {
            negative = true
            text = String(text.dropFirst().dropLast())
        }
        // WHY: Strip locale currency symbol via CurrencyFormatter so no "$" literal is hard-coded.
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
        return negative ? -value : value
    }

    /// Parses flexible date formats (ISO timestamps, date-only, US slashes).
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

/// Creates ledger entries from confirmed staging rows using deterministic IDs.
@MainActor
@Observable
final class LedgerImportService {
    private let cloudKit: any CloudKitServiceProtocol
    let cacheService: CacheService
    let syncCoordinator: CKSyncEngineCoordinator
    let appState: AppState

    private static let staticLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "LedgerImport")
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "LedgerImport")

    struct FinalizeSummary: Equatable, Sendable {
        let importedCount: Int
        let skippedDuplicates: Int
    }

    init(
        cloudKit: any CloudKitServiceProtocol,
        cacheService: CacheService,
        appState: AppState,
        syncCoordinator: CKSyncEngineCoordinator
    ) {
        self.cloudKit = cloudKit
        self.cacheService = cacheService
        self.appState = appState
        self.syncCoordinator = syncCoordinator
    }

    @_disfavoredOverload
    convenience init(
        cloudKit: any CloudKitServiceProtocol,
        cacheService: CacheService? = nil,
        appState: AppState? = nil,
        syncCoordinator: CKSyncEngineCoordinator? = nil
    ) {
        let cache: CacheService
        if let cacheService {
            cache = cacheService
        } else {
            Self.staticLogger.warning("LedgerImportService initialized without cacheService; using fallback in-memory cache.")
            cache = CacheService.inMemoryFallback(logger: Self.staticLogger)
        }
        let state = appState ?? AppState()
        let ck = cloudKit as? CloudKitService ?? CloudKitService()
        let delegate = CKSyncEngineDelegateHandler(
            backgroundCache: nil,
            conflictResolver: CKSyncConflictResolver(cacheService: cache, backgroundCache: nil, toastManager: nil, appState: state),
            cacheService: cache,
            appState: state
        )
        let coord = syncCoordinator ?? CKSyncEngineCoordinator(cloudKitService: ck, delegateHandler: delegate, appState: state)
        self.init(cloudKit: cloudKit, cacheService: cache, appState: state, syncCoordinator: coord)
    }

    // MARK: - Staging

    func stage(csvText: String) -> [StagedImportRow] {
        LedgerCSVParser.parse(csvText)
    }

    // MARK: - Deterministic IDs

    /// The content hash covers everything that defines the purchase —
    /// including the assigned child — so identical lines bought for different
    /// kids produce distinct entries, and any review-time edit changes identity.
    static func recordName(for row: StagedImportRow, profileRecordName: String) -> String {
        let cents = Int(((row.amount ?? 0) * 100).rounded())
        let timestamp = Int((row.date ?? Date()).timeIntervalSince1970)
        let canonical = [
            row.descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            row.merchant.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            String(cents),
            String(timestamp),
            profileRecordName
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        let hex = digest.shortHex
        return "import-\(hex)"
    }

    /// Rows that would still block finalization: unassigned children or
    /// fields the parser could not read. Excluded rows never block.
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
            // Idempotency: a deterministic ID already in the cache means this
            // exact row was confirmed before — skip it rather than double-spend.
            if cacheService.fetchLedgerEntry(recordName: recordName, family: family.id.recordName) != nil {
                skippedDuplicates += 1
                continue
            }

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
        do {
            try ActiveFamilyScopeGuard.requireActiveFamilyScope(family: family, cloudKit: cloudKit, appState: appState)
        } catch {
            logger.warning("Strict scope check failed, falling back to family-only check: \(error, privacy: .private)")
            try ActiveFamilyScopeGuard.requireActiveFamily(familyRecordName: family.id.recordName, appState: appState)
        }
    }
}

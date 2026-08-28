//
//  LedgerExportService.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import Foundation
import os

/// Builds CSV and JSON ledger exports in memory matching import schema.
@MainActor
final class LedgerExportService {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "LedgerExport")

    init() {}

    // MARK: - Filename

    /// Produces the canonical export filename: `lootlist-ledger-{child}-{yyyy-MM-dd}.{ext}`.
    /// Slashes and colons in the child name are replaced with hyphens so the
    /// filename is always safe for the filesystem.
    static func filename(child: String, date: Date, ext: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let dateString = formatter.string(from: date)
        let sanitized = child
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return "lootlist-ledger-\(sanitized)-\(dateString).\(ext)"
    }

    // MARK: - CSV

    /// Canonical CSV header — mirrors `LedgerImportService` column mapping so export round-trips.
    static let csvHeader = "Transaction Date,Description,Merchant,Amount,Purchased By"

    /// Builds CSV payload matching canonical import headers.
    func buildCSV(entries: [LedgerEntryCache], childName: String) -> Data {
        var csv = Self.csvHeader + "\n"

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)

        for entry in entries {
            let date = dateFormatter.string(from: entry.date)
            let desc = csvEscape(entry.entryDescription)
            let merchant = csvEscape(entry.location ?? "")
            // WHY: CSV is machine-readable but amount formatting still routes through CurrencyFormatter central point.
            let amount = CurrencyFormatter.editingString(entry.amount)
            let purchasedBy = csvEscape(childName)
            csv += "\(date),\(desc),\(merchant),\(amount),\(purchasedBy)\n"
        }

        logger.debug("Built CSV export: \(entries.count) rows")
        return Data(csv.utf8)
    }

    /// Quotes CSV fields per RFC4180 when containing commas, quotes, or newlines.
    private func csvEscape(_ field: String) -> String {
        var value = field
        var mustQuote = false
        if let first = field.trimmingCharacters(in: .whitespaces).first, "=+-@".contains(first) {
            value = "'" + value
            mustQuote = true
        }
        if mustQuote || value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
            let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return value
    }

    // MARK: - JSON

    /// Builds structured JSON dump of all ledger entries for backup.
    func buildJSON(entries: [LedgerEntryCache]) throws -> Data {
        let codableEntries = entries.map { LedgerEntryJSON(from: $0) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(codableEntries)
    }
}

// MARK: - JSON Codable Representation

private struct LedgerEntryJSON: Codable {
    let recordName: String
    let profileRecordName: String
    let familyRecordName: String
    let amount: Double
    let description: String
    let location: String?
    let date: Date
    let source: String
    let bucketKind: String?
    let fromBucket: String?
    let toBucket: String?

    init(from entry: LedgerEntryCache) {
        recordName = entry.recordName
        profileRecordName = entry.profileRecordName
        familyRecordName = entry.familyRecordName
        amount = entry.amount
        description = entry.entryDescription
        location = entry.location
        date = entry.date
        source = entry.source
        bucketKind = entry.bucketKind
        fromBucket = entry.fromBucket
        toBucket = entry.toBucket
    }
}

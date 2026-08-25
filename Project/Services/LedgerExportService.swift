//
//  LedgerExportService.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import Foundation
import os

/// Builds CSV and JSON ledger exports entirely in-memory. CSV columns match
/// the import parser's expected shape (Transaction Date,Description,Merchant,
/// Amount,Purchased By) so exported files round-trip through the import flow
/// without manual column remapping. JSON is a full structured dump of every
/// LedgerEntryCache field — bucket attribution, source, dates — for external
/// tooling or backup.
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

    /// Builds a CSV payload whose header exactly matches the canonical import
    /// columns so a parent can export, optionally edit, and re-import without
    /// adjusting column mappings. The "Merchant" column is sourced from
    /// `LedgerEntryCache.location`; "Purchased By" uses the supplied child
    /// display name. Fields are RFC4180-quoted when they contain commas,
    /// double quotes, or newlines, and formula-leading characters are
    /// neutralized before quoting (see `csvEscape`).
    func buildCSV(entries: [LedgerEntryCache], childName: String) -> Data {
        var csv = "Transaction Date,Description,Merchant,Amount,Purchased By\n"

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)

        for entry in entries {
            let date = dateFormatter.string(from: entry.date)
            let desc = csvEscape(entry.entryDescription)
            let merchant = csvEscape(entry.location ?? "")
            let amount = String(format: "%.2f", entry.amount)
            let purchasedBy = csvEscape(childName)
            csv += "\(date),\(desc),\(merchant),\(amount),\(purchasedBy)\n"
        }

        logger.debug("Built CSV export: \(entries.count) rows")
        return Data(csv.utf8)
    }

    /// RFC4180 field quoting: wrap in double quotes whenever the field
    /// contains a comma, double-quote, CR, or LF; double any internal
    /// double quotes per the spec. A field beginning with =, +, -, or @
    /// would execute as a formula when opened in Excel/Numbers/Sheets, so it
    /// gets a leading apostrophe (the spreadsheet text-marker convention) and
    /// is force-quoted so every downstream parser reads the cell as inert
    /// text rather than evaluating it.
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

    /// Full structured dump of every LedgerEntryCache field — record name,
    /// profile/family attribution, amount, description, location, date, source,
    /// and bucket attribution columns. Dates are ISO 8601; output is pretty-
    /// printed with sorted keys for deterministic diffs.
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

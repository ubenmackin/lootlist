//
//  LedgerExportServiceTests.swift
//  LootList
//
//  Created by Ben Mackin on 8/25/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

@MainActor
struct LedgerExportServiceTests {
    private let service = LedgerExportService()

    private func makeEntry(
        amount: Double = 12.34,
        entryDescription: String,
        location: String? = nil
    ) -> LedgerEntryCache {
        LedgerEntryCache(
            recordName: "entry1",
            profileRecordName: "hero1",
            familyRecordName: "fam1",
            amount: amount,
            entryDescription: entryDescription,
            location: location,
            date: Date(timeIntervalSince1970: 1_786_000_000),
            source: "manual"
        )
    }

    /// Splits the built CSV into data rows (header dropped). Only safe to
    /// comma-split further when no field itself contains a comma.
    private func dataRows(of csv: Data) -> [String] {
        (String(data: csv, encoding: .utf8) ?? "")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .dropFirst()
            .map(String.init)
    }

    /// Raw Description cell of a data row, parsed with the RFC4180 tokenizer
    /// so embedded commas and escaped quotes cannot shift the column index.
    /// The apostrophe formula-guard marker is intentionally preserved here.
    private func descriptionCell(of row: String) -> String? {
        let fields = LedgerCSVParser.tokenize(row).first ?? []
        return fields.count > 1 ? fields[1] : nil
    }

    @Test
    func `description starting with equals sign is prefixed and quoted`() {
        let csv = service.buildCSV(
            entries: [makeEntry(entryDescription: #"=HYPERLINK("https://evil.example","tap")"#)],
            childName: "Ava"
        )
        let row = dataRows(of: csv)[0]
        // Force-quoted so spreadsheet parsers read the cell as inert text.
        // The guard lives on the Description cell — the row itself leads
        // with the date column, so assert against the extracted field.
        #expect(row.contains(",\"'="), "Description cell must be force-quoted")
        let cell = descriptionCell(of: row)
        #expect(cell?.hasPrefix("'=") == true, "Description cell must carry the apostrophe guard")
        // Escaped quotes round-trip back to the original formula text.
        #expect(cell.map { String($0.dropFirst()) } == #"=HYPERLINK("https://evil.example","tap")"#)
    }

    @Test
    func `plus minus and at sign leading characters are neutralized too`() {
        for payload in ["=sum(A1)", "+SUM(A1)", "-1) or 1=1--", "@cmd"] {
            let csv = service.buildCSV(entries: [makeEntry(entryDescription: payload)], childName: "Ava")
            let row = dataRows(of: csv)[0]
            // The guard is on the Description cell, not the whole row — the
            // row leads with the date column — so extract the field first.
            #expect(row.contains(",\"'"), "Expected \(payload) to be quoted")
            let cell = descriptionCell(of: row)
            #expect(cell?.hasPrefix("'") == true, "Expected \(payload) to be neutralized")
            #expect(cell.map { String($0.dropFirst()) } == payload, "Guard must not alter the payload text")
        }
    }

    @Test
    func `merchant field starting with at sign is neutralized`() {
        let csv = service.buildCSV(
            entries: [makeEntry(entryDescription: "Sneakers", location: "@shop")],
            childName: "Ava"
        )
        let row = dataRows(of: csv)[0]
        #expect(row.contains(",\"'@shop\","))
    }

    @Test
    func `normal fields are emitted without prefix or quotes`() {
        let csv = service.buildCSV(
            entries: [makeEntry(entryDescription: "LEGO Set", location: "Amazon")],
            childName: "Ava"
        )
        let columns = dataRows(of: csv)[0].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        #expect(columns.count == 5)
        #expect(columns[1] == "LEGO Set")
        #expect(columns[2] == "Amazon")
        #expect(columns[4] == "Ava")
    }

    @Test
    func `amount column is never formula guarded`() {
        let csv = service.buildCSV(
            entries: [makeEntry(amount: -42.10, entryDescription: "Refund")],
            childName: "Ava"
        )
        let columns = dataRows(of: csv)[0].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        // Numeric cells stay numeric: a bare negative amount is a number in
        // every spreadsheet, not a formula.
        #expect(columns[3] == "-42.10")
    }

    @Test
    func `exported formula cells round trip back to their original text`() {
        let payload = "=cmd|'/c calc'!A1"
        let csv = service.buildCSV(
            entries: [makeEntry(entryDescription: payload, location: "=Store")],
            childName: "Ava"
        )
        let rows = LedgerCSVParser.parse(String(data: csv, encoding: .utf8) ?? "")
        #expect(rows.count == 1)
        #expect(rows[0].parseIssue == nil)
        #expect(rows[0].descriptionText == payload)
        #expect(rows[0].merchant == "=Store")
    }

    @Test
    func `literal leading apostrophe descriptions round trip unchanged`() {
        // A literal apostrophe is not a formula character, so it exports bare;
        // the import parser must likewise leave it alone, keeping the parsed
        // text — and therefore the content hash behind the deterministic ID —
        // identical across export/import cycles.
        let payload = "'90s toy"
        let csv = service.buildCSV(
            entries: [makeEntry(entryDescription: payload)],
            childName: "Ava"
        )
        #expect(!dataRows(of: csv)[0].contains("\"'"), "Literal apostrophe text needs no formula guard")

        let rows = LedgerCSVParser.parse(String(data: csv, encoding: .utf8) ?? "")
        #expect(rows.count == 1)
        #expect(rows[0].parseIssue == nil)
        #expect(rows[0].descriptionText == payload)
    }
}

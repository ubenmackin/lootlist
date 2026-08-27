//
//  LedgerImportServiceTests.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

// MARK: - Parser Edge Cases

struct LedgerCSVParserTests {
    @Test
    func `parses positional columns without a header`() {
        let csv = "2026-08-01,LEGO Set,Amazon,29.99,Ava"
        let rows = LedgerCSVParser.parse(csv)

        #expect(rows.count == 1)
        #expect(rows[0].descriptionText == "LEGO Set")
        #expect(rows[0].merchant == "Amazon")
        #expect(rows[0].amount == 29.99)
        #expect(rows[0].date != nil)
        #expect(rows[0].purchasedByRaw == "Ava")
        #expect(rows[0].parseIssue == nil)
    }

    @Test
    func `tolerates an optional header row`() {
        let csv = """
        Transaction Date,Description,Merchant,Amount,Purchased By
        2026-08-01,LEGO Set,Amazon,29.99,Ava
        """
        let rows = LedgerCSVParser.parse(csv)
        #expect(rows.count == 1)
        #expect(rows[0].descriptionText == "LEGO Set")
        #expect(rows[0].lineNumber == 2)
    }

    @Test
    func `maps columns by header names regardless of order`() {
        let csv = """
        Amount,Purchased By,Merchant,Transaction Date,Description
        $5.00,Sam,Ice Cream Shop,2026-08-02,Two scoops
        """
        let rows = LedgerCSVParser.parse(csv)
        #expect(rows.count == 1)
        #expect(rows[0].descriptionText == "Two scoops")
        #expect(rows[0].merchant == "Ice Cream Shop")
        #expect(rows[0].amount == 5.0)
        #expect(rows[0].purchasedByRaw == "Sam")
    }

    @Test
    func `quoted commas stay inside one field`() {
        let csv = "2026-08-01,\"Blocks, Bricks and Baseplates\",Toy Store,19.50,Ava"
        let rows = LedgerCSVParser.parse(csv)
        #expect(rows.count == 1)
        #expect(rows[0].descriptionText == "Blocks, Bricks and Baseplates")
    }

    @Test
    func `escaped quotes round trip through quoted fields`() {
        let csv = "2026-08-01,\"The \"\"Big\"\" Kit\",Maker Fair,40,Ava"
        let rows = LedgerCSVParser.parse(csv)
        #expect(rows.count == 1)
        #expect(rows[0].descriptionText == "The \"Big\" Kit")
    }

    @Test
    func `leading apostrophe marker is stripped during staging`() {
        let csv = "2026-08-01,'=Formula Desc,'@Merchant,29.99,Ava"
        let rows = LedgerCSVParser.parse(csv)
        #expect(rows.count == 1)
        #expect(rows[0].descriptionText == "=Formula Desc")
        #expect(rows[0].merchant == "@Merchant")
    }

    @Test
    func `guarded formula marker still strips before every neutralized character`() {
        let csv = "2026-08-01,'+Refund Bonus,'-Not A Date Is Fine Here,10.00,Ava"
        let rows = LedgerCSVParser.parse(csv)
        #expect(rows[0].descriptionText == "+Refund Bonus")
        #expect(rows[0].merchant == "-Not A Date Is Fine Here")
    }

    @Test
    func `literal leading apostrophe text is preserved verbatim`() {
        // A lone apostrophe followed by a non-formula character is real text,
        // not a spreadsheet guard — it must survive parsing untouched so its
        // content hash stays stable across re-imports.
        let csv = "2026-08-01,'90s toy,Vintage Shop,5.00,Ava"
        let rows = LedgerCSVParser.parse(csv)
        #expect(rows.count == 1)
        #expect(rows[0].descriptionText == "'90s toy")
        #expect(rows[0].merchant == "Vintage Shop")
    }

    @Test
    func `parses iso timestamps and iso date only values`() {
        #expect(LedgerCSVParser.parseDate("2026-08-01T15:04:05Z") != nil)
        #expect(LedgerCSVParser.parseDate("2026-08-01T10:11:12.500Z") != nil)
        #expect(LedgerCSVParser.parseDate("2026-08-01") != nil)
    }

    @Test
    func `parses us locale date formats`() {
        #expect(LedgerCSVParser.parseDate("08/09/2026") != nil)
        #expect(LedgerCSVParser.parseDate("8/9/2026") != nil)
        #expect(LedgerCSVParser.parseDate("Aug 9, 2026") != nil)
        #expect(LedgerCSVParser.parseDate("August 9, 2026") != nil)
        // Locale-independent determinism: US format never flips month/day.
        let augustNinth = LedgerCSVParser.parseDate("08/09/2026")
        #expect(augustNinth.map { Calendar.iso8601UTC.component(.month, from: $0) } == 8)
        #expect(augustNinth.map { Calendar.iso8601UTC.component(.day, from: $0) } == 9)
    }

    @Test
    func `rejects unreadable dates`() {
        #expect(LedgerCSVParser.parseDate("") == nil)
        #expect(LedgerCSVParser.parseDate("not a date") == nil)
        #expect(LedgerCSVParser.parseDate("32/32/2026") == nil)
    }

    @Test
    func `parses dollar prefixed amounts`() {
        #expect(LedgerCSVParser.parseAmount("$12.50") == 12.50)
        #expect(LedgerCSVParser.parseAmount(" $1,234.56 ") == 1234.56)
    }

    @Test
    func `parses parenthesized negatives as negative values`() {
        #expect(LedgerCSVParser.parseAmount("(42.10)") == -42.10)
        #expect(LedgerCSVParser.parseAmount("($42.10)") == -42.10)
    }

    @Test
    func `parses bare decimals and explicit signs`() {
        #expect(LedgerCSVParser.parseAmount("7") == 7.0)
        #expect(LedgerCSVParser.parseAmount("-3.25") == -3.25)
        #expect(LedgerCSVParser.parseAmount("+3.25") == 3.25)
    }

    @Test
    func `rejects unreadable amounts`() {
        #expect(LedgerCSVParser.parseAmount("") == nil)
        #expect(LedgerCSVParser.parseAmount("$n/a") == nil)
    }

    @Test
    func `malformed rows are flagged inline and never dropped`() {
        let csv = """
        Transaction Date,Description,Merchant,Amount,Purchased By
        2026-08-01,Good Row,Store,10.00,Ava
        someday,Bad Row,Store,ninety dollars,Ava
        ,Missing Date,Store,10.00,Ava
        """
        let rows = LedgerCSVParser.parse(csv)

        #expect(rows.count == 3, "Malformed rows must remain staged")
        #expect(rows[0].parseIssue == nil)
        #expect(rows[1].parseIssue?.contains("date") == true)
        #expect(rows[1].parseIssue?.contains("amount") == true)
        #expect(rows[2].parseIssue == "Unreadable date")
    }

    @Test
    func `blank lines are skipped without shifting line numbers`() {
        let csv = """

        2026-08-01,First,Store,1.00,Ava

        2026-08-02,Second,Store,2.00,Sam
        """
        let rows = LedgerCSVParser.parse(csv)
        #expect(rows.count == 2)
        #expect(rows[1].lineNumber > rows[0].lineNumber)
    }
}

// MARK: - Finalization & Idempotency

@MainActor
struct LedgerImportServiceTests {
    // MARK: - Shared Fixtures

    private func makeZoneID() -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
    }

    private func makeFamilyRef(_ zoneID: CKRecordZone.ID) -> CKRecord.Reference {
        CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID),
            action: .none
        )
    }

    private func makeParent(_ zoneID: CKRecordZone.ID) -> Profile {
        Profile(
            displayName: "Guild Master",
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .guildMaster,
            iCloudUserID: CKRecord.ID(recordName: "parent1", zoneID: zoneID),
            family: makeFamilyRef(zoneID),
            id: CKRecord.ID(recordName: "parent1", zoneID: zoneID)
        )
    }

    private func makeHero(_ zoneID: CKRecordZone.ID, name: String = "Ava", recordName: String = "hero1") -> Profile {
        Profile(
            displayName: name,
            avatarClass: .mage,
            avatarPresetID: "mage_01",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: recordName, zoneID: zoneID),
            family: makeFamilyRef(zoneID),
            id: CKRecord.ID(recordName: recordName, zoneID: zoneID)
        )
    }

    private func makeFamily(_ zoneID: CKRecordZone.ID) -> Family {
        Family(
            name: "Test Guild",
            createdBy: CKRecord.ID(recordName: "parent1", zoneID: zoneID),
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )
    }

    private func setupActiveScope(
        appState: AppState,
        cloudKit: MockCloudKitService,
        family: Family,
        actingProfile: Profile
    ) {
        appState.family = family
        appState.familyZoneID = family.id.zoneID
        appState.isZoneOwner = true
        appState.currentProfile = actingProfile
        cloudKit.activeFamilyZoneID = family.id.zoneID
        cloudKit.activeIsOwner = true
    }

    private func makeAssignedRow(
        description: String = "LEGO Set",
        merchant: String = "Amazon",
        amountText: String = "$29.99",
        dateText: String = "2026-08-01",
        profileRecordName: String = "hero1"
    ) -> StagedImportRow {
        var row = LedgerCSVParser.parse("\(dateText),\(description),\(merchant),\(amountText),X")[0]
        row.assignedProfileRecordName = profileRecordName
        return row
    }

    // MARK: - Tests

    @Test
    func `finalize writes ledger entries to cache immediately`() async throws {
        let zoneID = makeZoneID()
        let cloudKit = MockCloudKitService()
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        let service = LedgerImportService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        let family = makeFamily(zoneID)
        setupActiveScope(appState: appState, cloudKit: cloudKit, family: family, actingProfile: makeParent(zoneID))

        let summary = try await service.finalize([makeAssignedRow()], family: family)

        #expect(summary.importedCount == 1)
        let cached = cache.fetchLedgerEntries(profileRecordName: "hero1", family: family.id.recordName)
        #expect(cached.count == 1)
        #expect(cached.first?.source == "import")
        #expect(cached.first?.location == "Amazon")
        #expect(cached.first?.recordName.hasPrefix("import-") == true)
    }

    @Test
    func `re-importing identical rows is idempotent`() async throws {
        let zoneID = makeZoneID()
        let cloudKit = MockCloudKitService()
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        let service = LedgerImportService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        let family = makeFamily(zoneID)
        setupActiveScope(appState: appState, cloudKit: cloudKit, family: family, actingProfile: makeParent(zoneID))

        let firstRun = try await service.finalize([makeAssignedRow()], family: family)
        #expect(firstRun.importedCount == 1)
        #expect(firstRun.skippedDuplicates == 0)

        // Double-run safety: same content hashes to the same deterministic ID.
        let secondRun = try await service.finalize([makeAssignedRow()], family: family)
        #expect(secondRun.importedCount == 0)
        #expect(secondRun.skippedDuplicates == 1)

        let cached = cache.fetchLedgerEntries(profileRecordName: "hero1", family: family.id.recordName)
        #expect(cached.count == 1, "Re-import must not duplicate ledger entries")
    }

    @Test
    func `literal apostrophe descriptions stay dedup-stable across finalizations`() async throws {
        let zoneID = makeZoneID()
        let cloudKit = MockCloudKitService()
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        let service = LedgerImportService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        let family = makeFamily(zoneID)
        setupActiveScope(appState: appState, cloudKit: cloudKit, family: family, actingProfile: makeParent(zoneID))

        // Round-trip safety for literal apostrophe text: parsing the same
        // content twice yields identical deterministic IDs.
        let rowA = makeAssignedRow(description: "'90s toy")
        let rowB = makeAssignedRow(description: "'90s toy")
        #expect(
            LedgerImportService.recordName(for: rowA, profileRecordName: "hero1")
                == LedgerImportService.recordName(for: rowB, profileRecordName: "hero1")
        )

        let firstRun = try await service.finalize([rowA], family: family)
        #expect(firstRun.importedCount == 1)

        let secondRun = try await service.finalize([rowB], family: family)
        #expect(secondRun.importedCount == 0)
        #expect(secondRun.skippedDuplicates == 1)

        let cached = cache.fetchLedgerEntries(profileRecordName: "hero1", family: family.id.recordName)
        #expect(cached.count == 1, "Literal apostrophe text must not duplicate on re-import")
        #expect(cached.first?.entryDescription == "'90s toy")

        // The formula-guarded variant strips to different text ("=90s toy"),
        // so it must never collide with the literal "'90s toy" entry.
        let guardedRow = makeAssignedRow(description: "'=90s toy")
        #expect(guardedRow.descriptionText == "=90s toy")
        #expect(
            LedgerImportService.recordName(for: guardedRow, profileRecordName: "hero1")
                != LedgerImportService.recordName(for: rowA, profileRecordName: "hero1")
        )
    }

    @Test
    func `deterministic record name depends on content and assignment`() {
        let rowA = makeAssignedRow(profileRecordName: "hero1")
        let rowB = makeAssignedRow(profileRecordName: "hero2")
        let rowC = makeAssignedRow(description: "Different Thing")

        let nameA = LedgerImportService.recordName(for: rowA, profileRecordName: "hero1")

        #expect(nameA.hasPrefix("import-"))
        #expect(LedgerImportService.recordName(for: rowA, profileRecordName: "hero1") == nameA)
        #expect(LedgerImportService.recordName(for: rowB, profileRecordName: "hero2") != nameA)
        #expect(LedgerImportService.recordName(for: rowC, profileRecordName: "hero1") != nameA)
    }

    @Test
    func `unassigned included rows block finalization`() async throws {
        let zoneID = makeZoneID()
        let cloudKit = MockCloudKitService()
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        let service = LedgerImportService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        let family = makeFamily(zoneID)
        setupActiveScope(appState: appState, cloudKit: cloudKit, family: family, actingProfile: makeParent(zoneID))

        var unassigned = makeAssignedRow()
        unassigned.assignedProfileRecordName = nil

        await #expect(throws: LedgerImportError.self) {
            _ = try await service.finalize([unassigned], family: family)
        }
        #expect(cache.fetchLedgerEntries(profileRecordName: "hero1", family: family.id.recordName).isEmpty)
    }

    @Test
    func `excluded rows neither import nor block`() async throws {
        let zoneID = makeZoneID()
        let cloudKit = MockCloudKitService()
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        let service = LedgerImportService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        let family = makeFamily(zoneID)
        setupActiveScope(appState: appState, cloudKit: cloudKit, family: family, actingProfile: makeParent(zoneID))

        var malformed = LedgerCSVParser.parse("not a date,Bad,Store,nope,Ava")[0]
        malformed.isExcluded = true
        let valid = makeAssignedRow()

        let summary = try await service.finalize([malformed, valid], family: family)
        #expect(summary.importedCount == 1)
        #expect(cache.fetchLedgerEntries(profileRecordName: "hero1", family: family.id.recordName).count == 1)
    }

    @Test
    func `hero role cannot finalize an import`() async throws {
        let zoneID = makeZoneID()
        let cloudKit = MockCloudKitService()
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        let service = LedgerImportService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        let family = makeFamily(zoneID)
        setupActiveScope(appState: appState, cloudKit: cloudKit, family: family, actingProfile: makeHero(zoneID))

        do {
            _ = try await service.finalize([makeAssignedRow()], family: family)
            Issue.record("Expected unauthorized throw for hero role")
        } catch {
            #expect(error is FamilyServiceError)
        }
        #expect(cache.fetchLedgerEntries(profileRecordName: "hero1", family: family.id.recordName).isEmpty)
    }
}

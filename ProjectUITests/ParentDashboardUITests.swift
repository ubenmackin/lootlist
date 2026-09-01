//
//  ParentDashboardUITests.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import XCTest

@MainActor
final class ParentDashboardUITests: XCTestCase {
    /// Record names come from the deterministic `--uitest-seed=parent` fixture
    /// family, so identifier suffixes are stable across runs.
    private static let mayaRecordName = "hero_maya"
    private static let leoRecordName = "hero_leo"
    private static let pendingCompletionRecordName = "completion_maya_3"

    var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        launchSeededParentApp()
    }

    // MARK: - Dashboard Stats & Child Grid

    func testStatCardsRenderFamilyOutflowAndPendingReviewCount() {
        XCTAssertTrue(anyElement("dashboard.outflowCard").waitForExistence(timeout: 10.0),
                      "Family outflow stat card should render on the parent dashboard")
        XCTAssertTrue(anyElement("dashboard.pendingReviewCard").waitForExistence(timeout: 5.0),
                      "Pending review stat card should render on the parent dashboard")
    }

    func testChildAccountGridListsEveryHeroCard() {
        XCTAssertTrue(anyElement("dashboard.childAccount-\(Self.mayaRecordName)").waitForExistence(timeout: 10.0),
                      "Maya's child account card should render in the grid")
        XCTAssertTrue(anyElement("dashboard.childAccount-\(Self.leoRecordName)").waitForExistence(timeout: 5.0),
                      "Leo's child account card should render in the grid")

        // Per-child pending attribution surfaces through the approval queue's
        // semantic labels; the card itself combines children into one
        // accessibility element, so the badge is not separately queryable.
        let heroAttribution = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'Maya'")
        ).firstMatch
        scrollToHittable(heroAttribution)
        XCTAssertTrue(heroAttribution.exists, "The approval queue should attribute the pending submission to Maya")
    }

    // MARK: - Approval Queue

    func testApprovePendingCompletionClearsQueueCount() {
        let approveButton = anyElement("dashboard.approveButton-\(Self.pendingCompletionRecordName)")
        XCTAssertTrue(approveButton.waitForExistence(timeout: 10.0), "Approve action should render for the seeded pending completion")
        scrollToHittable(approveButton)
        approveButton.tap()

        waitForDisappearance(of: approveButton, timeout: 15.0)
    }

    func testRejectPendingCompletionClearsQueueCount() {
        let rejectButton = anyElement("dashboard.rejectButton-\(Self.pendingCompletionRecordName)")
        XCTAssertTrue(rejectButton.waitForExistence(timeout: 10.0), "Reject action should render for the seeded pending completion")
        scrollToHittable(rejectButton)
        rejectButton.tap()

        waitForDisappearance(of: rejectButton, timeout: 15.0)
    }

    // MARK: - Deposit / Withdraw Entry Points

    func testDepositEntryPointOpensTransactionSheet() {
        openQuickAction("dashboard.depositButton", expectingFieldPlaceholder: "Birthday check from Grandpa")
        dismissSheetViaCancel()
    }

    func testWithdrawEntryPointOpensTransactionSheet() {
        openQuickAction("dashboard.withdrawButton", expectingFieldPlaceholder: "Cash for camp event.")
        dismissSheetViaCancel()
    }

    // MARK: - Kids Savings Goals

    func testKidsSavingsGoalsShowsPerChildSectionsAndProgress() {
        openChildAccount(Self.mayaRecordName)

        let savingsGoalsLink = anyElement("heroDetail.savingsGoalsNavCard")
        XCTAssertTrue(savingsGoalsLink.waitForExistence(timeout: 10.0), "Savings Goals entry point should render on the child detail screen")
        savingsGoalsLink.tap()

        // The focused hero sorts first but every child gets their own section.
        XCTAssertTrue(anyElement("kidsGoals.section-\(Self.mayaRecordName)").waitForExistence(timeout: 10.0),
                      "Maya's goals section should render with per-child attribution")
        XCTAssertTrue(anyElement("kidsGoals.section-\(Self.leoRecordName)").waitForExistence(timeout: 5.0),
                      "Leo's goals section should render below the focused hero")

        // Goal cards below the fold only materialize as the scroll view lays
        // them out, so walk downward instead of asserting offscreen elements.
        let mayaArtCard = scrollToElement(anyElement("kidsGoals.goalCard-goal_maya_art"))
        XCTAssertTrue(mayaArtCard.exists, "Maya's seeded goal card should render")

        // Progress bars are exposed through the goal card's combined
        // accessibility label rather than as separate elements.
        let leoSkateboardCard = scrollToElement(anyElement("kidsGoals.goalCard-goal_leo_skateboard"))
        waitForLabel(of: leoSkateboardCard, contains: "percent earned")
    }

    func testInterestMatchEntryPointOpensConfigurationSheet() {
        openChildAccount(Self.mayaRecordName)

        let interestMatchLink = anyElement("heroDetail.interestMatchRow")
        XCTAssertTrue(interestMatchLink.waitForExistence(timeout: 10.0), "Interest & Match entry point should render on child hub")
        interestMatchLink.tap()

        let interestHeader = anyElement("Monthly Interest")
        XCTAssertTrue(interestHeader.waitForExistence(timeout: 10.0), "Interest & Match sheet should render")

        let cancelBtn = app.buttons["Cancel"]
        XCTAssertTrue(cancelBtn.waitForExistence(timeout: 5.0))
        cancelBtn.tap()
    }

    // MARK: - Ledger Export

    func testLedgerExportInvokesShareSheet() {
        openChildAccount(Self.leoRecordName)

        let treasuryNavCard = anyElement("heroDetail.treasuryNavCard")
        XCTAssertTrue(treasuryNavCard.waitForExistence(timeout: 10.0), "Treasury navigation card should exist on the child detail screen")
        treasuryNavCard.tap()

        let exportButton = app.buttons["square.and.arrow.up"]
        XCTAssertTrue(exportButton.waitForExistence(timeout: 10.0), "Export toolbar button should render for parents")
        exportButton.tap()

        let exportCSVOption = app.buttons["Export as CSV"]
        XCTAssertTrue(exportCSVOption.waitForExistence(timeout: 10.0), "Export format dialog should present")
        exportCSVOption.tap()

        // UIActivityViewController exposes transfer targets as buttons.
        let shareTarget = app.descendants(matching: .any).matching(
            NSPredicate(format: "label IN {'AirDrop', 'Messages', 'Mail', 'Copy', 'Save to Files', 'Print', 'Notes'}")
        ).firstMatch
        XCTAssertTrue(shareTarget.waitForExistence(timeout: 15.0), "ShareSheet should present after choosing an export format")

        if app.buttons["Cancel"].exists {
            app.buttons["Cancel"].tap()
        } else {
            app.swipeDown()
        }
    }

    // MARK: - Ledger Import Staging

    func testImportStagingBlocksConfirmationUntilEveryRowIsAssigned() {
        openImportStaging()

        let confirmButton = anyElement("import.confirmButton")
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 10.0), "Confirm action should render once a file is staged")
        XCTAssertTrue(anyElement("import.chooseAnotherFileButton").exists,
                      "Re-choose-file action should stay available while staging")

        // Seeded sample rows have no resolvable Purchased By values.
        XCTAssertFalse(confirmButton.isEnabled,
                       "Unassigned rows must block confirmation instead of guessing an owner")

        editFirstRowDescription(to: "Sketch pad from Michaels")
        assignFirstUnassignedRow(to: "Maya")

        XCTAssertTrue(confirmButton.exists)
        XCTAssertFalse(confirmButton.isEnabled,
                       "One assigned row must not be enough while another row stays unassigned")

        // Excluding the remaining row is the parent's explicit choice, so it
        // unblocks confirmation without assigning it.
        app.switches.element(boundBy: 1).tap()
        XCTAssertTrue(confirmButton.isEnabled, "Excluding the last blocked row should unblock confirmation")
    }

    func testImportConfirmCreatesEntriesInChildLedgers() {
        openImportStaging()

        let confirmButton = anyElement("import.confirmButton")
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 10.0))
        XCTAssertFalse(confirmButton.isEnabled)

        editFirstRowDescription(to: "Sketch pad from Michaels")
        assignFirstUnassignedRow(to: "Maya")
        assignFirstUnassignedRow(to: "Leo")
        XCTAssertTrue(confirmButton.isEnabled, "Fully assigned rows should enable confirmation")
        confirmButton.tap()

        // Confirmation dismisses staging and only then touches the ledger.
        XCTAssertTrue(app.navigationBars["Payout History"].waitForExistence(timeout: 10.0),
                      "Staging sheet should dismiss after import completes")

        assertChildLedgerContains(childRecordName: Self.mayaRecordName, descriptionFragment: "Sketch pad")
        assertChildLedgerContains(childRecordName: Self.leoRecordName, descriptionFragment: "Movie rental")
    }

    // MARK: - Navigation helpers

    private func launchSeededParentApp(additionalArguments: [String] = []) {
        // Relaunching between tests resets all app state; skip the very first
        // launch of a session where no app instance exists yet.
        app?.terminate()
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--uitest-seed=parent"] + additionalArguments
        app.launch()

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10.0), "Parent tab bar should load for the seeded Guild Master")
    }

    private func openChildAccount(_ recordName: String) {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10.0))
        if tabBar.buttons["Payouts"].isSelected {
            tabBar.buttons["Family"].tap()
        }

        let card = anyElement("dashboard.childAccount-\(recordName)")
        if !card.exists {
            popToFamilyDashboard()
        }

        scrollToHittable(card)
        XCTAssertTrue(card.exists, "Child account card for \(recordName) should render")
        card.tap()
    }

    private func tapBackButton() {
        let backButton = app.navigationBars.buttons.matching(
            NSPredicate(format: "label != 'square.and.arrow.up' AND identifier != 'square.and.arrow.up' AND NOT (label CONTAINS[c] 'Export')")
        ).firstMatch
        if backButton.waitForExistence(timeout: 5.0) {
            backButton.tap()
        }
    }

    private func popToFamilyDashboard() {
        // If in Treasury, pop back to Child Hub
        if app.navigationBars["Treasury"].waitForExistence(timeout: 3.0) {
            tapBackButton()
        }
        // If in Child Hub, pop back to Family Dashboard
        let treasuryNav = anyElement("heroDetail.treasuryNavCard")
        if treasuryNav.waitForExistence(timeout: 5.0) {
            tapBackButton()
        }
        _ = anyElement("dashboard.outflowCard").waitForExistence(timeout: 5.0)
    }

    private func assertChildLedgerContains(childRecordName: String, descriptionFragment: String) {
        openChildAccount(childRecordName)

        let treasuryNavCard = anyElement("heroDetail.treasuryNavCard")
        XCTAssertTrue(treasuryNavCard.waitForExistence(timeout: 10.0))
        treasuryNavCard.tap()

        let importedRow = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", descriptionFragment)
        ).firstMatch
        scrollToElement(importedRow)
        XCTAssertTrue(importedRow.exists,
                      "Confirmed import should place '\(descriptionFragment)' in \(childRecordName)'s ledger")

        popToFamilyDashboard()
    }

    private func openQuickAction(_ identifier: String, expectingFieldPlaceholder placeholder: String) {
        let quickAction = anyElement(identifier)
        scrollToHittable(quickAction)
        XCTAssertTrue(quickAction.exists, "\(identifier) entry point should render")
        quickAction.tap()

        let reasonField = app.textFields[placeholder].firstMatch
        XCTAssertTrue(reasonField.waitForExistence(timeout: 10.0),
                      "Transaction sheet should open with its reason field")
    }

    private func dismissSheetViaCancel() {
        let cancelButton = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 5.0))
        cancelButton.tap()
    }

    /// Reaches the import staging list by handing the app a CSV through the
    /// `--uitest-import-csv` launch argument, then opening the parent-only
    /// import entry point on the Payouts tab.
    private func openImportStaging() {
        guard let csvPath = stagedSampleCSVPath() else {
            XCTFail("Bundled CSV import sample should be readable from the test target bundle")
            return
        }
        launchSeededParentApp(additionalArguments: ["--uitest-import-csv=\(csvPath)"])

        let payoutsTab = app.tabBars.buttons["Payouts"]
        XCTAssertTrue(payoutsTab.waitForExistence(timeout: 10.0))
        payoutsTab.tap()

        let importButton = anyElement("payoutHistory.importButton")
        XCTAssertTrue(importButton.waitForExistence(timeout: 10.0), "Parent-only ledger import entry point should render on Payouts")
        importButton.tap()

        XCTAssertTrue(anyElement("import.chooseAnotherFileButton").waitForExistence(timeout: 10.0),
                      "Staging list should appear because the launch argument stages the sample directly")
    }

    // MARK: - Import interaction helpers

    /// Rewrites the first staging row's description. Deletes past the original
    /// length so the replacement text is exact regardless of cursor placement.
    private func editFirstRowDescription(to newText: String) {
        let descriptionField = app.textFields["Description"].firstMatch
        XCTAssertTrue(descriptionField.waitForExistence(timeout: 10.0), "Staged rows should expose editable descriptions")
        descriptionField.tap()
        descriptionField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40))
        descriptionField.typeText(newText)
    }

    /// Assigns the topmost still-unassigned staging row via its Purchased By
    /// picker. Menu-backed pickers expose options as buttons; navigation-style
    /// pickers push a plain list, so fall back to any matching element.
    private func assignFirstUnassignedRow(to childName: String) {
        let trigger = app.descendants(matching: .any).matching(
            NSPredicate(format: "label ==[c] 'UNASSIGNED'")
        ).firstMatch
        XCTAssertTrue(trigger.waitForExistence(timeout: 5.0), "An unassigned Purchased By picker should be available")
        trigger.tap()

        let buttonOption = app.buttons.matching(
            NSPredicate(format: "label ==[c] %@", childName)
        ).firstMatch
        if buttonOption.waitForExistence(timeout: 3.0) {
            buttonOption.tap()
            return
        }

        let fallbackOption = app.descendants(matching: .any).matching(
            NSPredicate(format: "label ==[c] %@", childName)
        ).firstMatch
        XCTAssertTrue(fallbackOption.waitForExistence(timeout: 5.0), "Picker should offer child profile \(childName)")
        fallbackOption.tap()
    }

    // MARK: - Fixture handling

    /// The bundled sample uses date placeholders so staged rows always fall
    /// inside the ledger's default this-week scope no matter when the suite
    /// runs. Simulator processes share the filesystem, so the rewritten file
    /// written by the runner is readable by the app process.
    private func stagedSampleCSVPath() -> String? {
        guard let sampleURL = Bundle(for: ParentDashboardUITests.self)
            .url(forResource: "uitest-import-sample", withExtension: "csv"),
            var csvText = try? String(contentsOf: sampleURL, encoding: .utf8)
        else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())
        csvText = csvText
            .replacingOccurrences(of: "{{DATE_1}}", with: today)
            .replacingOccurrences(of: "{{DATE_2}}", with: today)

        let destination = NSTemporaryDirectory().appending("uitest-import-sample.csv")
        do {
            try csvText.write(toFile: destination, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        return destination
    }

    // MARK: - Query helpers

    /// Accessibility identifiers are the assertion contract; querying any
    /// element kind keeps tests agnostic to SwiftUI's trait mapping.
    private func anyElement(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func waitForLabel(of element: XCUIElement, equals text: String, timeout: TimeInterval = 10.0) {
        wait(for: [expectation(for: NSPredicate(format: "label == %@", text), evaluatedWith: element)], timeout: timeout)
    }

    private func waitForLabel(of element: XCUIElement, contains text: String, timeout: TimeInterval = 10.0) {
        wait(for: [expectation(for: NSPredicate(format: "label CONTAINS[c] %@", text), evaluatedWith: element)], timeout: timeout)
    }

    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval = 10.0) {
        wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)], timeout: timeout)
    }

    /// ScrollView content exists offscreen but cannot be tapped until scrolled
    /// into view; swipe up until the element becomes hittable.
    private func scrollToHittable(_ element: XCUIElement, maxSwipes: Int = 6) {
        var swipes = 0
        while swipes < maxSwipes, !element.isHittable {
            app.swipeUp()
            swipes += 1
            if element.isHittable {
                break
            }
        }
    }

    /// Content below the fold materializes only as SwiftUI lays it out during
    /// scrolling; swipe until the element exists before asserting on it.
    @discardableResult
    private func scrollToElement(_ element: XCUIElement, maxSwipes: Int = 6) -> XCUIElement {
        if element.waitForExistence(timeout: 2.0) {
            return element
        }
        // Try scrolling down (swipe up) in case the element is below the current viewport
        var swipes = 0
        while !element.exists, swipes < maxSwipes {
            app.swipeUp()
            swipes += 1
            if element.waitForExistence(timeout: 2.0) {
                return element
            }
        }
        // Try scrolling up (swipe down) in case the element is above the current viewport
        swipes = 0
        while !element.exists, swipes < maxSwipes {
            app.swipeDown()
            swipes += 1
            if element.waitForExistence(timeout: 2.0) {
                return element
            }
        }
        return element
    }
}

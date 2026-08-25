//
//  TreasuryUITests.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import XCTest

/// Child money flows over the seeded hero: creating a goal through the goal
/// editor, posting a hub purchase into the ledger, and moving money between
/// buckets. Label predicates are used only for child-entered text; everything
/// else binds to accessibility identifiers.
@MainActor
final class TreasuryUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        // Seeded child gives deterministic buckets and goals; light mode pins
        // the rendering across runs.
        app.launchArguments = ["--uitesting", "--uitest-seed=child", "--uitest-appearance=light"]
        app.launch()
    }

    // MARK: - Helpers

    /// Identifier queries run across every element kind because these screens
    /// compose plain containers rather than standard controls.
    private func element(withIdentifier id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func firstElement(withLabelContaining substring: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", substring))
            .firstMatch
    }

    /// Inline bucket pickers expose each option row under a section-scoped
    /// identifier, so Source and Destination options never collide even
    /// though both sections render every bucket.
    private func selectPickerOption(_ identifier: String) {
        let option = element(withIdentifier: identifier)
        XCTAssertTrue(option.waitForExistence(timeout: 5.0),
                      "Bucket picker option '\(identifier)' should be present")
        option.tap()
    }

    /// Segmented pickers surface their segments as control-scoped buttons on
    /// current iOS but fall back to bare buttons elsewhere.
    private func selectSegment(titled title: String) {
        let segment = app.segmentedControls.buttons[title]
        if segment.exists {
            segment.tap()
            return
        }
        let fallback = app.buttons[title]
        if fallback.exists {
            fallback.tap()
        }
    }

    // MARK: - Goal Creation

    func testCreateGoalViaGoalEditorSheet() {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10.0))

        tabBar.buttons["Goals"].tap()

        let addButton = element(withIdentifier: "goals.addGoalButton")
        XCTAssertTrue(addButton.waitForExistence(timeout: 5.0), "Add Goal action should be available on My Goals")
        addButton.tap()

        let nameField = element(withIdentifier: "goalEditor.nameField")
        XCTAssertTrue(nameField.waitForExistence(timeout: 5.0), "Goal editor sheet should present the name field")
        nameField.tap()
        nameField.typeText("Robot Kit")

        let rocketEmoji = app.buttons["🚀"]
        if rocketEmoji.exists {
            rocketEmoji.tap()
        }

        let amountField = element(withIdentifier: "goalEditor.amountField")
        XCTAssertTrue(amountField.exists, "Target amount field should be present in the goal editor")
        amountField.tap()
        amountField.typeText("24.99")

        selectSegment(titled: "Long Save")

        element(withIdentifier: "goalEditor.saveButton").tap()

        // The new card carries a generated record name, so it is located by
        // the child-authored title.
        XCTAssertTrue(firstElement(withLabelContaining: "Robot Kit").waitForExistence(timeout: 5.0),
                      "Saved goal should appear as a card after the sheet dismisses")
    }

    // MARK: - Log a Purchase

    func testLogPurchaseCTAOpensSpendEntryAndPostsTransaction() {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10.0))

        let logButton = element(withIdentifier: "hub.logPurchaseButton")
        XCTAssertTrue(logButton.waitForExistence(timeout: 5.0), "Log-a-purchase CTA should be pinned to the child hub")
        logButton.tap()

        // The spending form's inputs hold child-authored text only, so they
        // are located by placeholder rather than identifier.
        let descriptionField = app.textFields["What did you buy?"]
        XCTAssertTrue(descriptionField.waitForExistence(timeout: 5.0), "Spending entry form should open from the hub CTA")
        descriptionField.tap()
        descriptionField.typeText("Comic books")

        let amountEntry = app.textFields["2.50"]
        XCTAssertTrue(amountEntry.exists, "Amount field should be present in the spending form")
        amountEntry.tap()
        amountEntry.typeText("3.25")

        app.buttons["Add to Scroll"].tap()

        // Posted purchases land on the Money tab's transaction history.
        tabBar.buttons["Money"].tap()
        XCTAssertTrue(firstElement(withLabelContaining: "Comic books").waitForExistence(timeout: 5.0),
                      "Logged purchase should appear as a ledger transaction")
    }

    // MARK: - Bucket Transfer

    func testBucketTransferMovesMoneyFromLongSaveToSpend() {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10.0))

        tabBar.buttons["Money"].tap()

        let moveMoneyEntry = element(withIdentifier: "ledger.moveMoneyButton")
        XCTAssertTrue(moveMoneyEntry.waitForExistence(timeout: 5.0),
                      "Move Money action should be pinned to the child Money tab")
        moveMoneyEntry.tap()

        let amountField = element(withIdentifier: "transfer.amountField")
        XCTAssertTrue(amountField.waitForExistence(timeout: 5.0), "Move Money screen should expose the amount field")
        amountField.tap()
        amountField.typeText("1.00")

        selectPickerOption("transfer.fromOption-longTermSave")
        selectPickerOption("transfer.toOption-spend")

        let confirmButton = element(withIdentifier: "transfer.confirmButton")
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 5.0),
                      "Confirm should stay available after both buckets are chosen")
        XCTAssertTrue(confirmButton.isEnabled, "Confirm should enable once source, destination, and amount are valid")
        confirmButton.tap()

        let alertConfirm = app.alerts.buttons.matching(
            NSPredicate(format: "label BEGINSWITH[c] 'Move'")
        ).firstMatch
        XCTAssertTrue(alertConfirm.waitForExistence(timeout: 5.0), "Confirm alert should summarize the transfer")
        alertConfirm.tap()

        // A settled transfer dismisses the confirmation alert first, then
        // the form sheet; either still visible means the movement was
        // rejected and no ledger row can exist yet.
        expectation(for: NSPredicate(format: "exists == 0"), evaluatedWith: alertConfirm)
        waitForExpectations(timeout: 5.0)

        expectation(for: NSPredicate(format: "exists == 0"), evaluatedWith: amountField)
        waitForExpectations(timeout: 5.0)

        // Transfer ledger entries use deterministic ids, so the posted
        // movement is assertable without locale-sensitive currency parsing.
        let day = Int(Date().timeIntervalSince1970 / 86400)
        let expectedRows = [
            "ledger.row-transfer-hero_maya-\(day)-longTermSave-spend",
            "ledger.row-transfer-hero_maya-\(day - 1)-longTermSave-spend"
        ]
        let postedRow = expectedRows.map { element(withIdentifier: $0) }.first { $0.exists }
        XCTAssertNotNil(postedRow, "Posted transfer should create its deterministic ledger row")
    }
}

import XCTest

@MainActor
final class TreasuryUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
    }

    func testLogSpendingModalOpens() {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5.0))

        tabBar.buttons.element(boundBy: 1).tap()

        let logButton = app.buttons["Log Spending"]
        if logButton.waitForExistence(timeout: 5.0) {
            logButton.tap()

            let spendingTitleField = app.textFields["What did you buy?"]
            XCTAssertTrue(spendingTitleField.waitForExistence(timeout: 5.0), "Spending input textfield should appear in modal")
        }
    }
}

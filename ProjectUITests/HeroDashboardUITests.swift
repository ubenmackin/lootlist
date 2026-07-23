import XCTest

@MainActor
final class HeroDashboardUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
    }

    func testTabBarNavigation() throws {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5.0), "Tab bar should be visible")

        let questsTab = tabBar.buttons.element(boundBy: 0)
        let goldTab = tabBar.buttons.element(boundBy: 1)
        let trophiesTab = tabBar.buttons.element(boundBy: 2)

        XCTAssertTrue(questsTab.exists, "Quests tab should exist")
        XCTAssertTrue(goldTab.exists, "Gold/Treasury tab should exist")
        XCTAssertTrue(trophiesTab.exists, "Trophies tab should exist")
    }

    func testSwitchingTabs() throws {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5.0))

        // Tap Treasury tab
        tabBar.buttons.element(boundBy: 1).tap()
        let treasuryHeader = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Scroll' OR label CONTAINS[c] 'Treasury' OR label CONTAINS[c] 'Gold'")).firstMatch
        XCTAssertTrue(treasuryHeader.waitForExistence(timeout: 3.0), "Treasury view header should appear after switching tabs")

        // Tap Trophies tab
        tabBar.buttons.element(boundBy: 2).tap()
        let trophiesHeader = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Hall' OR label CONTAINS[c] 'Trophies' OR label CONTAINS[c] 'Level'")).firstMatch
        XCTAssertTrue(trophiesHeader.waitForExistence(timeout: 3.0), "Trophy view header should appear after switching tabs")
    }
}

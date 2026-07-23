import XCTest

@MainActor
final class ParentDashboardUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--parent"]
        app.launch()
    }

    func testParentDashboardLoadsForGuildMaster() throws {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5.0), "Parent tab bar should load")
    }
}

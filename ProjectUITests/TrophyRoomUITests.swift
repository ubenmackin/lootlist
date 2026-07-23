import XCTest

@MainActor
final class TrophyRoomUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
    }

    func testTrophyRoomDisplaysCharacterInfo() throws {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5.0))

        tabBar.buttons.element(boundBy: 2).tap()

        let characterName = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Sir Testalot' OR label CONTAINS[c] 'Hero'")).firstMatch
        XCTAssertTrue(characterName.waitForExistence(timeout: 4.0), "Character name should be visible in Trophy Room")
    }
}

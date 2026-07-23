import XCTest

@MainActor
final class OnboardingUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--onboarding"]
        app.launch()
    }

    func testOnboardingWelcomeScreenDisplays() throws {
        let welcomeTitle = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Adventurer' OR label CONTAINS[c] 'Loot List'")).firstMatch
        XCTAssertTrue(welcomeTitle.waitForExistence(timeout: 5.0), "Welcome screen title should appear")
    }

    func testRoleSelectionFlow() throws {
        let startButton = app.buttons["welcome.startButton"]
        if startButton.waitForExistence(timeout: 5.0) {
            startButton.tap()
        }

        let parentButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Parent' OR label CONTAINS[c] 'Guild Master'")).firstMatch
        let heroButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Hero' OR label CONTAINS[c] 'Kid'")).firstMatch

        XCTAssertTrue(parentButton.waitForExistence(timeout: 5.0) || heroButton.waitForExistence(timeout: 5.0), "Role selection options should be visible")
    }
}

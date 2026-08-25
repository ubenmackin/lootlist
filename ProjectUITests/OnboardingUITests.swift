//
//  OnboardingUITests.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import XCTest

@MainActor
final class OnboardingUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--uitest-seed=onboarding"]
        app.launch()
    }

    // MARK: - Helpers

    /// Any-element lookup keeps assertions bound to the identifier contract
    /// instead of SwiftUI's per-view element-type mapping.
    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func relaunch(arguments: [String]) {
        app.terminate()
        app.launchArguments = arguments
        app.launch()
    }

    /// Advances welcome → role selection and taps the given intent card.
    private func chooseIntent(_ identifier: String) {
        let startButton = app.buttons["welcome.startButton"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 5.0), "Welcome screen should present its start button")
        startButton.tap()

        let intentButton = app.buttons[identifier]
        XCTAssertTrue(intentButton.waitForExistence(timeout: 5.0), "Role selection should offer \(identifier)")
        intentButton.tap()
    }

    /// Walks the full create-family handoff: guild naming, then the
    /// name-only profile-setup screen.
    private func reachProfileSetup() {
        chooseIntent("role.createFamily")

        let familyNameField = app.textFields["createFamily.familyNameField"]
        XCTAssertTrue(familyNameField.waitForExistence(timeout: 5.0), "Guild naming should precede profile setup")
        familyNameField.tap()
        familyNameField.typeText("Test Family\n")

        // The advance control carries no identifier yet, so match its label
        // purely for navigation — never for assertions.
        let nextButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Next'")).firstMatch
        XCTAssertTrue(nextButton.waitForExistence(timeout: 3.0), "Guild naming should expose an advance control")
        nextButton.tap()
    }

    // MARK: - Simplified flow

    func testWelcomeScreenPresentsStartButton() {
        let startButton = app.buttons["welcome.startButton"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 5.0), "Fresh onboarding should land on the welcome screen")
    }

    func testRoleSelectionOffersCreateAndJoinPaths() {
        let startButton = app.buttons["welcome.startButton"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 5.0))
        startButton.tap()

        XCTAssertTrue(app.buttons["role.createFamily"].waitForExistence(timeout: 5.0),
                      "Create-a-family path should be offered")
        XCTAssertTrue(app.buttons["role.joinFamily"].exists,
                      "Join-a-family path should sit beside create")
    }

    func testJoinIntentHandsOffToInviteWaitingScreen() {
        chooseIntent("role.joinFamily")

        // A fresh launch holds no share metadata, so the join path parks on
        // the invitation-waiting surface rather than advancing to setup.
        XCTAssertTrue(element("joinFamily.waitingScreen").waitForExistence(timeout: 5.0),
                      "Join intent should hand off to the invitation-waiting screen")
    }

    func testCreateFamilyPathAdvancesToNameOnlyProfileSetup() {
        reachProfileSetup()

        let nameField = app.textFields["avatar.displayNameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5.0), "Profile setup should collect a display name")

        let finalizeButton = app.buttons["avatar.finalizeButton"]
        XCTAssertTrue(finalizeButton.waitForExistence(timeout: 5.0))
        XCTAssertFalse(finalizeButton.isEnabled, "Finalize stays disabled until a name is entered")

        nameField.tap()
        nameField.typeText("Alex\n")

        XCTAssertTrue(finalizeButton.isEnabled, "Name-only entry should unlock finalization")
    }

    func testAvatarSetupShowsEmojiPickerWithoutClassSelection() {
        reachProfileSetup()

        let emojiGrid = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'avatar.emoji.'"))
        XCTAssertTrue(emojiGrid.firstMatch.waitForExistence(timeout: 5.0),
                      "Emoji avatar picker should be visible with no photo attached")

        let firstEmoji = emojiGrid.firstMatch
        if firstEmoji.isHittable {
            firstEmoji.tap()
        }

        // Class and sprite pickers belong to the immersive layer, which is
        // forced off during UI testing.
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'avatar.class.'")).count, 0,
                       "Class selection must not appear in the simplified flow")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'avatar.preset.'")).count, 0,
                       "Sprite presets must not appear in the simplified flow")
    }

    func testSimplifiedOnboardingRendersInDarkMode() {
        relaunch(arguments: ["--uitesting", "--uitest-seed=onboarding", "--uitest-appearance=dark"])

        let startButton = app.buttons["welcome.startButton"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 5.0), "Welcome screen should render in dark mode")
        startButton.tap()

        XCTAssertTrue(app.buttons["role.createFamily"].waitForExistence(timeout: 5.0),
                      "Role selection should render in dark mode")
    }
}

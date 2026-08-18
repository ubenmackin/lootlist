//
//  TrophyRoomUITests.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

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

    func testTrophyRoomDisplaysCharacterInfo() {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5.0))

        // Navigate to Trophies via Profile tab → Trophies link
        tabBar.buttons["Profile"].tap()
        let trophiesLink = app.buttons["profile.trophies"]
        XCTAssertTrue(trophiesLink.waitForExistence(timeout: 3.0), "Trophies row should appear on Profile")
        trophiesLink.tap()

        let characterName = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Sir Testalot' OR label CONTAINS[c] 'Hero'")).firstMatch
        XCTAssertTrue(characterName.waitForExistence(timeout: 4.0), "Character name should be visible in Trophy Room")
    }
}

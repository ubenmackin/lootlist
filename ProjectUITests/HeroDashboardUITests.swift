//
//  HeroDashboardUITests.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

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

    func testTabBarNavigation() {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5.0), "Tab bar should be visible")

        let homeTab = tabBar.buttons.element(boundBy: 0)
        let questsTab = tabBar.buttons.element(boundBy: 1)
        let goldTab = tabBar.buttons.element(boundBy: 2)
        let profileTab = tabBar.buttons.element(boundBy: 3)

        XCTAssertTrue(homeTab.exists, "Home tab should exist")
        XCTAssertTrue(questsTab.exists, "Quests tab should exist")
        XCTAssertTrue(goldTab.exists, "Money/Treasury tab should exist")
        XCTAssertTrue(profileTab.exists, "Profile tab should exist")
    }

    func testSwitchingTabs() {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5.0))

        // Tap Money tab (now index 2 in the [Home, Quests, Money, Profile] order)
        tabBar.buttons["Money"].tap()
        let treasuryHeader = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Scroll' OR label CONTAINS[c] 'Treasury' OR label CONTAINS[c] 'Money'")).firstMatch
        XCTAssertTrue(treasuryHeader.waitForExistence(timeout: 3.0), "Treasury view header should appear after switching tabs")

        // Navigate to Trophies via Profile tab → Trophies cell
        tabBar.buttons["Profile"].tap()
        let trophiesLink = app.buttons["profile.trophies"]
        XCTAssertTrue(trophiesLink.waitForExistence(timeout: 3.0), "Trophies row should appear on Profile")
        trophiesLink.tap()

        let trophiesHeader = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Hall' OR label CONTAINS[c] 'Trophies' OR label CONTAINS[c] 'Level'")).firstMatch
        XCTAssertTrue(trophiesHeader.waitForExistence(timeout: 3.0), "Trophy view header should appear after opening from Profile")
    }
}

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
        app.launchArguments = ["--uitesting", "--uitest-seed=child"]
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

    /// Trophy criteria live on the utility Profile surface, so the room must
    /// stay reachable no matter how the immersive layer is flagged.
    private func navigateToTrophyRoom() {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5.0), "Tab bar should load for the seeded child")
        tabBar.buttons["Profile"].tap()

        // Immersive-layer shortcuts stay hidden while rpgImmersive is off.
        XCTAssertFalse(app.buttons["profile.gemShop"].exists,
                       "Gem Shop must stay hidden while the immersive layer is disabled")

        let trophiesLink = app.buttons["profile.trophies"]
        XCTAssertTrue(trophiesLink.waitForExistence(timeout: 5.0), "Trophies row should appear on Profile")
        trophiesLink.tap()

        XCTAssertTrue(app.navigationBars["Hall of Heroes"].waitForExistence(timeout: 5.0),
                      "Trophy Room should open from the utility profile surface")
    }

    /// Trophy cards live in a lazy grid, so walk downward until the target
    /// row materializes before asserting on it.
    @discardableResult
    private func scrollToCard(_ trophyName: String) -> XCUIElement {
        let card = element("TrophyCard.\(trophyName)")
        var scrolls = 0
        while !card.exists, scrolls < 8 {
            app.swipeUp()
            scrolls += 1
        }
        return card
    }

    // MARK: - Repivoted criteria

    func testTrophyRoomOpensFromUtilityProfileSurface() {
        navigateToTrophyRoom()
    }

    func testQuestCountAndGoalCriteriaRenderAsTrophies() {
        navigateToTrophyRoom()

        // Alphabetical order keeps the lazy-grid walk monotonic.
        let repivotedTrophies = [
            "First Goal Created",
            "First Quest Complete",
            "Goal Getter",
            "Quest Novice",
            "Quest Regular"
        ]
        for trophy in repivotedTrophies {
            XCTAssertTrue(scrollToCard(trophy).exists,
                          "\(trophy) should render in the trophy grid")
        }
    }

    func testEarnedAndLockedStatesMatchSeedProgress() {
        navigateToTrophyRoom()

        let earnedCard = scrollToCard("First Quest Complete")
        XCTAssertTrue(earnedCard.exists)
        XCTAssertEqual(earnedCard.value as? String, "Trophy earned",
                       "Seeded child has completed quests, so the first-quest trophy is unlocked")

        let lockedCard = scrollToCard("Quest Champion")
        XCTAssertTrue(lockedCard.exists)
        XCTAssertEqual(lockedCard.value as? String, "Trophy locked",
                       "High quest-count tiers stay locked at seed progress")
    }

    func testTrophyRoomRendersInDarkMode() {
        relaunch(arguments: ["--uitesting", "--uitest-seed=child", "--uitest-appearance=dark"])
        navigateToTrophyRoom()

        XCTAssertTrue(scrollToCard("Goal Getter").exists,
                      "Goal-based trophies should render in dark mode")
    }
}

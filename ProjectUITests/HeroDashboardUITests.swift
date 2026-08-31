//
//  HeroDashboardUITests.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import XCTest

/// Child-flow suite over the seeded hero scenario. Assertions bind to
/// accessibility identifiers; label predicates appear only for text the
/// child authors themselves.
@MainActor
final class HeroDashboardUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        // Seeded child gives deterministic buckets, goals, and a pending
        // parent review; light mode pins the dashboard rendering.
        app.launchArguments = ["--uitesting", "--uitest-seed=child", "--uitest-appearance=light"]
        app.launch()
    }

    // MARK: - Helpers

    /// Identifier queries run across every element kind because the hub
    /// composes plain containers (tiles, rings, chore rows) rather than
    /// standard controls.
    private func element(withIdentifier id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    // MARK: - Hub Content

    func testHubShowsBalanceCardAndBucketTiles() {
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10.0), "Child tab bar should load")

        let balanceCard = element(withIdentifier: "hub.balanceCard")
        XCTAssertTrue(balanceCard.waitForExistence(timeout: 5.0), "Balance hero card should render at the top of the child hub")

        for id in ["hub.bucketTile-spend", "hub.bucketTile-shortSave", "hub.bucketTile-longSave"] {
            XCTAssertTrue(element(withIdentifier: id).exists, "Bucket tile \(id) should render in the balance card")
        }
    }

    func testHubShowsWeeklyProgressRingAndActiveGoal() {
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10.0))

        let progressRing = element(withIdentifier: "hub.weeklyProgressRing")
        XCTAssertTrue(progressRing.waitForExistence(timeout: 5.0), "Weekly progress ring section should render")

        // FIFO puts the oldest open goal at the head, so the card renders
        // without any scrolling under the seed.
        XCTAssertTrue(element(withIdentifier: "hub.activeGoalCard").exists, "Active goal card should show the FIFO head goal")
    }

    func testTodaysChoresShowsPendingReviewRow() {
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10.0))

        // The parentVerify quest is complete but unreviewed under the seed;
        // its completion drives the amber pending-review row.
        let pendingRow = element(withIdentifier: "hub.choreRow-completion_maya_3")
        XCTAssertTrue(pendingRow.waitForExistence(timeout: 5.0), "Chore awaiting parent review should render in the pending-review state")
    }

    // MARK: - Child Flows

    func testMyChoresShowsPendingReviewAndUpcomingSections() {
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10.0))

        app.tabBars.buttons["Quests"].tap()

        // Pending rows key off the quest's record name; upcoming rows list
        // every active assignment not awaiting review, including ones whose
        // auto-approved completion already paid out.
        XCTAssertTrue(element(withIdentifier: "chores.pendingRow-quest_hero1_3").waitForExistence(timeout: 5.0),
                      "Quest sent for review should render in the amber pending section")
        XCTAssertTrue(element(withIdentifier: "chores.upcomingRow-quest_hero1_1").exists,
                      "Auto-approved quest should remain listed under Upcoming")
        XCTAssertTrue(element(withIdentifier: "chores.upcomingRow-quest_hero1_2").exists,
                      "Auto-approved quest should remain listed under Upcoming")

        XCTAssertTrue(element(withIdentifier: "chores.heroBoardLink").exists, "Hero Board should be reachable from My Chores")
    }

    func testMyGoalsListsSeededGoalCards() {
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10.0))

        app.tabBars.buttons["Goals"].tap()

        XCTAssertTrue(element(withIdentifier: "goals.addGoalButton").waitForExistence(timeout: 5.0), "Add Goal action should be available on My Goals")

        // Short Save section sorts first, so its card needs no scrolling;
        // Long Save cards sit below the fold on compact devices.
        XCTAssertTrue(element(withIdentifier: "goals.card-goal_maya_art").exists, "Short Save goal card should render")
        app.swipeUp()
        XCTAssertTrue(element(withIdentifier: "goals.card-goal_maya_nintendo").waitForExistence(timeout: 3.0), "Long Save goal cards should render after scrolling")
        app.swipeUp()
        XCTAssertTrue(element(withIdentifier: "goals.card-goal_maya_bike").waitForExistence(timeout: 3.0), "Long Save goal cards should render after scrolling")
    }
}

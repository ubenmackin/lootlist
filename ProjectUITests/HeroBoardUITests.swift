//
//  HeroBoardUITests.swift
//  LootList
//
//  Created by Ben Mackin on 8/25/26.
//

import XCTest

@MainActor
final class HeroBoardUITests: XCTestCase {
    /// Message the board surfaces when a claim race is lost to another child.
    private static let lostRaceMessage = "Someone grabbed it first!"

    var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--uitest-seed=hero-board"]
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

    /// Opens the board from the seeded child's Quests surface.
    private func openHeroBoard() {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5.0), "Tab bar should load for the seeded child")
        tabBar.buttons["Quests"].tap()

        let boardLink = app.buttons["chores.heroBoardLink"]
        XCTAssertTrue(boardLink.waitForExistence(timeout: 5.0), "Hero Board link should sit in the Quests toolbar")
        boardLink.tap()

        XCTAssertTrue(element("board.availableRow-quest_board_plants").waitForExistence(timeout: 5.0),
                      "The unclaimed seed quest should render on the board")
    }

    // MARK: - Child claim flow

    func testBoardListsUnassignedQuestsForChild() {
        openHeroBoard()

        let availableRow = element("board.availableRow-quest_board_plants")
        XCTAssertTrue(availableRow.exists, "Unassigned quests should render in Up for Grabs")
        XCTAssertTrue(app.buttons["board.claimButton-quest_board_plants"].exists,
                      "Unassigned quests should expose a claim action to children")
    }

    func testChildClaimsAvailableQuest() {
        openHeroBoard()

        let claimButton = app.buttons["board.claimButton-quest_board_plants"]
        XCTAssertTrue(claimButton.waitForExistence(timeout: 5.0))
        claimButton.tap()

        // An accepted optimistic claim pulls the quest out of Up for Grabs
        // right away; claimed detail only renders on the parent surface.
        let rowGone = NSPredicate(format: "exists == 0")
        let rowRemoved = expectation(for: rowGone, evaluatedWith: element("board.availableRow-quest_board_plants"))
        wait(for: [rowRemoved], timeout: 5.0)
    }

    func testSiblingClaimedQuestsLeaveTheGrabList() {
        openHeroBoard()

        // Two-child seed: quests already claimed by the sibling are withheld
        // from Up for Grabs entirely, so a slower second child is never shown
        // a claim affordance for a quest they would lose.
        XCTAssertFalse(element("board.availableRow-quest_board_dog").exists)
        XCTAssertFalse(element("board.availableRow-quest_board_vacuum").exists)
        XCTAssertFalse(app.buttons["board.claimButton-quest_board_dog"].exists)
        XCTAssertFalse(app.buttons["board.claimButton-quest_board_vacuum"].exists)
    }

    func testCleanClaimDoesNotSurfaceLostRaceToast() {
        openHeroBoard()

        let claimButton = app.buttons["board.claimButton-quest_board_plants"]
        XCTAssertTrue(claimButton.waitForExistence(timeout: 5.0))
        claimButton.tap()

        // A single-child optimistic win must never render the conflict toast;
        // that warning is reserved for the ingest-revealed lost race covered
        // at the view-model level. Toasts carry the message as their value.
        let conflictToast = app.descendants(matching: .any)
            .matching(NSPredicate(format: "value CONTAINS[c] %@", Self.lostRaceMessage))
            .firstMatch
        XCTAssertFalse(conflictToast.waitForExistence(timeout: 2.0),
                       "A clean claim should not show '\(Self.lostRaceMessage)'")
    }

    func testHeroBoardRendersInDarkMode() {
        relaunch(arguments: ["--uitesting", "--uitest-seed=hero-board", "--uitest-appearance=dark"])
        openHeroBoard()

        XCTAssertTrue(app.buttons["board.claimButton-quest_board_plants"].exists,
                      "Claim actions should render in dark mode")
    }
}

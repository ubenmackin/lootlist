//
//  LootListScreenshotTests.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import XCTest

final class LootListScreenshotTests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testHeroScreenshots() {
        let app = XCUIApplication()
        setupSnapshot(app)
        app.launchArguments += ["--uitesting"]
        app.launch()

        sleep(2)
        snapshot("01HeroQuestsView")

        let tabBar = app.tabBars.firstMatch
        if tabBar.waitForExistence(timeout: 5) {
            let moneyTab = tabBar.buttons["Money"]
            if moneyTab.exists {
                moneyTab.tap()
                sleep(2)
                snapshot("02TreasuryView")
            }

            let profileTab = tabBar.buttons["Profile"]
            if profileTab.exists {
                profileTab.tap()
                sleep(2)
                snapshot("04ProfileView")

                // Trophies now lives under Profile — drill in for the
                // Hall of Heroes screenshot, then return to Profile.
                let trophiesLink = app.buttons["profile.trophies"]
                if trophiesLink.waitForExistence(timeout: 3) {
                    trophiesLink.tap()
                    sleep(2)
                    snapshot("03TrophyRoomView")
                }
            }
        }
    }

    @MainActor
    func testParentScreenshots() {
        let app = XCUIApplication()
        setupSnapshot(app)
        app.launchArguments += ["--uitesting", "--parent"]
        app.launch()

        sleep(2)
        snapshot("05ParentFamilyDashboard")

        let tabBar = app.tabBars.firstMatch
        if tabBar.waitForExistence(timeout: 5) {
            let manageTab = tabBar.buttons["Manage"]
            if manageTab.exists {
                manageTab.tap()
                sleep(2)
                snapshot("06QuestManagerView")
            }

            let payoutsTab = tabBar.buttons["Payouts"]
            if payoutsTab.exists {
                payoutsTab.tap()
                sleep(2)
                snapshot("07PayoutHistoryView")
            }

            let settingsTab = tabBar.buttons["Settings"]
            if settingsTab.exists {
                settingsTab.tap()
                sleep(2)
                snapshot("08GuildSettingsView")
            }
        }
    }

    @MainActor
    func testOnboardingScreenshot() {
        let app = XCUIApplication()
        setupSnapshot(app)
        app.launchArguments += ["--uitesting", "--onboarding"]
        app.launch()

        sleep(2)
        snapshot("00OnboardingWelcomeView")
    }
}

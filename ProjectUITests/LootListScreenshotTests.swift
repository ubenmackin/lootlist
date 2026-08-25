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

    private struct AppearanceConfig {
        let flag: String
        let suffix: String
    }

    /// Each scenario is captured twice per run — once in light and once in
    /// dark mode, forced through the `--uitest-appearance` launch argument so
    /// no simulator reconfiguration is needed between captures.
    private static let appearances: [AppearanceConfig] = [
        AppearanceConfig(flag: "light", suffix: "Light"),
        AppearanceConfig(flag: "dark", suffix: "Dark")
    ]

    @MainActor
    func testHeroScreenshots() {
        for appearance in Self.appearances {
            let app = XCUIApplication()
            setupSnapshot(app)
            app.launchArguments += [
                "--uitesting",
                "--uitest-seed=child",
                "--uitest-appearance=\(appearance.flag)"
            ]
            app.launch()

            sleep(2)
            snapshot("01HeroQuestsView-\(appearance.suffix)")

            let tabBar = app.tabBars.firstMatch
            if tabBar.waitForExistence(timeout: 5) {
                let moneyTab = tabBar.buttons["Money"]
                if moneyTab.exists {
                    moneyTab.tap()
                    sleep(2)
                    snapshot("02TreasuryView-\(appearance.suffix)")
                }

                let profileTab = tabBar.buttons["Profile"]
                if profileTab.exists {
                    profileTab.tap()
                    sleep(2)
                    snapshot("04ProfileView-\(appearance.suffix)")

                    // Trophies now lives under Profile — drill in for the
                    // Hall of Heroes screenshot, then return to Profile.
                    let trophiesLink = app.buttons["profile.trophies"]
                    if trophiesLink.waitForExistence(timeout: 3) {
                        trophiesLink.tap()
                        sleep(2)
                        snapshot("03TrophyRoomView-\(appearance.suffix)")
                    }
                }
            }
        }
    }

    @MainActor
    func testParentScreenshots() {
        for appearance in Self.appearances {
            let app = XCUIApplication()
            setupSnapshot(app)
            app.launchArguments += [
                "--uitesting",
                "--uitest-seed=parent",
                "--uitest-appearance=\(appearance.flag)"
            ]
            app.launch()

            sleep(2)
            snapshot("05ParentFamilyDashboard-\(appearance.suffix)")

            let tabBar = app.tabBars.firstMatch
            if tabBar.waitForExistence(timeout: 5) {
                let manageTab = tabBar.buttons["Manage"]
                if manageTab.exists {
                    manageTab.tap()
                    sleep(2)
                    snapshot("06QuestManagerView-\(appearance.suffix)")
                }

                let payoutsTab = tabBar.buttons["Payouts"]
                if payoutsTab.exists {
                    payoutsTab.tap()
                    sleep(2)
                    snapshot("07PayoutHistoryView-\(appearance.suffix)")
                }

                let settingsTab = tabBar.buttons["Settings"]
                if settingsTab.exists {
                    settingsTab.tap()
                    sleep(2)
                    snapshot("08GuildSettingsView-\(appearance.suffix)")
                }
            }
        }
    }

    @MainActor
    func testOnboardingScreenshot() {
        for appearance in Self.appearances {
            let app = XCUIApplication()
            setupSnapshot(app)
            app.launchArguments += [
                "--uitesting",
                "--uitest-seed=onboarding",
                "--uitest-appearance=\(appearance.flag)"
            ]
            app.launch()

            sleep(2)
            snapshot("00OnboardingWelcomeView-\(appearance.suffix)")
        }
    }
}

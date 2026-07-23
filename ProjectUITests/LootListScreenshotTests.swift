import XCTest

final class LootListScreenshotTests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testHeroScreenshots() throws {
        let app = XCUIApplication()
        setupSnapshot(app)
        app.launchArguments += ["--uitesting"]
        app.launch()

        sleep(2)
        snapshot("01HeroQuestsView")

        let tabBar = app.tabBars.firstMatch
        if tabBar.waitForExistence(timeout: 5) {
            let goldTab = tabBar.buttons["Gold"]
            if goldTab.exists {
                goldTab.tap()
                sleep(2)
                snapshot("02TreasuryView")
            }

            let trophiesTab = tabBar.buttons["Trophies"]
            if trophiesTab.exists {
                trophiesTab.tap()
                sleep(2)
                snapshot("03TrophyRoomView")
            }

            let profileTab = tabBar.buttons["Profile"]
            if profileTab.exists {
                profileTab.tap()
                sleep(2)
                snapshot("04ProfileView")
            }
        }
    }

    @MainActor
    func testParentScreenshots() throws {
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
    func testOnboardingScreenshot() throws {
        let app = XCUIApplication()
        setupSnapshot(app)
        app.launchArguments += ["--uitesting", "--onboarding"]
        app.launch()

        sleep(2)
        snapshot("00OnboardingWelcomeView")
    }
}

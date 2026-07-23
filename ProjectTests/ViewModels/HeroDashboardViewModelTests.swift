import Foundation
import Testing
import CloudKit
@testable import LootList

@MainActor
struct HeroDashboardViewModelTests {

    @Test("Weekday code formatting")
    func testTodayWeekdayCode() {
        let code = HeroDashboardViewModel.todayWeekdayCode()
        let validCodes = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        #expect(validCodes.contains(code))
    }

    @Test("Initial state before loading")
    func testInitialState() {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = CloudKitService(zoneID: zoneID)
        let questService = QuestService(cloudKit: cloudKit)
        let appState = AppState()

        let viewModel = HeroDashboardViewModel(questService: questService, appState: appState)

        #expect(viewModel.todaysQuests.isEmpty)
        #expect(viewModel.streak == 0)
        #expect(viewModel.earnedThisWeek == 0)
        #expect(viewModel.isLoading == false)
    }

    @Test("Load clears state when no profile is present")
    func testLoadWithoutProfile() async {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = CloudKitService(zoneID: zoneID)
        let questService = QuestService(cloudKit: cloudKit)
        let appState = AppState()

        let viewModel = HeroDashboardViewModel(questService: questService, appState: appState)
        await viewModel.load()

        #expect(viewModel.todaysQuests.isEmpty)
        #expect(viewModel.streak == 0)
        #expect(viewModel.earnedThisWeek == 0)
        #expect(viewModel.availableTemplatesCount == 0)
    }

    @Test("Sunday-Saturday week days calculation")
    func testCurrentWeekDays() {
        let weekDays = HeroDashboardViewModel.currentWeekDays()
        #expect(weekDays.count == 7)
        #expect(weekDays.first?.weekdayCode == "sunday")
        #expect(weekDays.first?.shortName == "Sun")
        #expect(weekDays.last?.weekdayCode == "saturday")
        #expect(weekDays.last?.shortName == "Sat")
        #expect(weekDays.contains(where: { $0.isToday }))
    }
}

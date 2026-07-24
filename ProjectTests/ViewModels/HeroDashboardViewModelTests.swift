import CloudKit
import Foundation
@testable import LootList
import Testing

@MainActor
struct HeroDashboardViewModelTests {
    @Test
    func `weekday code formatting`() {
        let code = HeroDashboardViewModel.todayWeekdayCode()
        let validCodes = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        #expect(validCodes.contains(code))
    }

    @Test
    func `initial state before loading`() {
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

    @Test
    func `load clears state when no profile is present`() async {
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

    @Test
    func `sunday-Saturday week days calculation`() {
        let weekDays = HeroDashboardViewModel.currentWeekDays()
        #expect(weekDays.count == 7)
        #expect(weekDays.first?.weekdayCode == "sunday")
        #expect(weekDays.first?.shortName == "Sun")
        #expect(weekDays.last?.weekdayCode == "saturday")
        #expect(weekDays.last?.shortName == "Sat")
        // swiftformat:disable:next preferKeyPath redundantClosure
        #expect(weekDays.contains(where: { $0.isToday }))
    }
}

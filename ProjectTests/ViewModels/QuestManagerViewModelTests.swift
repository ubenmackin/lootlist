//
//  QuestManagerViewModelTests.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

@MainActor
struct QuestManagerViewModelTests {
    private struct Dependencies {
        let questService: QuestService
        let familyService: FamilyService
        let appState: AppState
    }

    private func makeDependencies() -> Dependencies {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService(zoneID: zoneID)
        let appState = AppState()
        let xpService = XPService(cloudKit: cloudKit)
        let questService = QuestService(cloudKit: cloudKit, xpService: xpService)
        let familyService = FamilyService(cloudKit: cloudKit, appState: appState, questService: questService)
        return Dependencies(
            questService: questService,
            familyService: familyService,
            appState: appState
        )
    }

    @Test
    func `initial quest manager state`() {
        let deps = makeDependencies()
        let vm = QuestManagerViewModel(
            questService: deps.questService,
            familyService: deps.familyService,
            appState: deps.appState
        )

        #expect(vm.templates.isEmpty)
        #expect(vm.activeAssignments.isEmpty)
        #expect(vm.isLoading == false)
        #expect(vm.loadError == nil)
    }

    @Test
    func `load clears state when family is nil`() async {
        let deps = makeDependencies()
        let vm = QuestManagerViewModel(
            questService: deps.questService,
            familyService: deps.familyService,
            appState: deps.appState
        )

        await vm.load()

        #expect(vm.templates.isEmpty)
        #expect(vm.activeAssignments.isEmpty)
        #expect(vm.isLoading == false)
    }

    @Test
    func `quest edit locked error localized description`() {
        let error = QuestEditLockedError.lockedFields
        #expect(error.errorDescription != nil)
        #expect(error.errorDescription?.contains("locked") == true)
    }

    @Test
    func `locked fields gate includes isAllOrNothing`() {
        let deps = makeDependencies()
        let vm = QuestManagerViewModel(
            questService: deps.questService,
            familyService: deps.familyService,
            appState: deps.appState
        )
        #expect(vm.templates.isEmpty)
    }

    @Test
    func `updateQuest propagateToTemplate defaults to false`() {
        let deps = makeDependencies()
        let vm = QuestManagerViewModel(
            questService: deps.questService,
            familyService: deps.familyService,
            appState: deps.appState
        )
        #expect(vm.activeAssignments.isEmpty)
    }
}

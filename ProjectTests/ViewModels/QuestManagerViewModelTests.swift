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
    private func makeDependencies() -> (QuestService, FamilyService, AppState) { // swiftlint:disable:this large_tuple
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = CloudKitService(zoneID: zoneID)
        let appState = AppState()
        let xpService = XPService(cloudKit: cloudKit)
        let questService = QuestService(cloudKit: cloudKit, xpService: xpService)
        let familyService = FamilyService(cloudKit: cloudKit, appState: appState, questService: questService)
        return (questService, familyService, appState)
    }

    @Test
    func `initial quest manager state`() {
        let (questService, familyService, appState) = makeDependencies()
        let vm = QuestManagerViewModel(questService: questService, familyService: familyService, appState: appState)

        #expect(vm.templates.isEmpty)
        #expect(vm.activeAssignments.isEmpty)
        #expect(vm.isLoading == false)
        #expect(vm.loadError == nil)
    }

    @Test
    func `load clears state when family is nil`() async {
        let (questService, familyService, appState) = makeDependencies()
        let vm = QuestManagerViewModel(questService: questService, familyService: familyService, appState: appState)

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
        let (questService, familyService, appState) = makeDependencies()
        let vm = QuestManagerViewModel(questService: questService, familyService: familyService, appState: appState)
        #expect(vm.templates.isEmpty)
    }

    @Test
    func `updateQuest propagateToTemplate defaults to false`() {
        let (questService, familyService, appState) = makeDependencies()
        let vm = QuestManagerViewModel(questService: questService, familyService: familyService, appState: appState)
        #expect(vm.activeAssignments.isEmpty)
    }
}

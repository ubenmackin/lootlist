//
//  FamilyServiceTests.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

@MainActor
struct FamilyServiceTests {
    private func makeDependencies() -> (FamilyService, CloudKitService, AppState, QuestService) { // swiftlint:disable:this large_tuple
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = CloudKitService(zoneID: zoneID)
        let appState = AppState()
        let questService = QuestService(cloudKit: cloudKit)
        let familyService = FamilyService(cloudKit: cloudKit, appState: appState, questService: questService)
        return (familyService, cloudKit, appState, questService)
    }

    @Test
    func `family service error equality`() {
        #expect(FamilyServiceError.invalidInviteCode == FamilyServiceError.invalidInviteCode)
        #expect(FamilyServiceError.accountUnavailable == FamilyServiceError.accountUnavailable)
        #expect(FamilyServiceError.joinFailed("e1") == FamilyServiceError.joinFailed("e1"))
        #expect(FamilyServiceError.joinFailed("e1") != FamilyServiceError.joinFailed("e2"))
        #expect(FamilyServiceError.creationFailed("c1") == FamilyServiceError.creationFailed("c1"))
        #expect(FamilyServiceError.persistenceFailed("p1") == FamilyServiceError.persistenceFailed("p1"))
    }

    @Test
    func `create family empty name validation`() async {
        let (familyService, _, _, _) = makeDependencies()
        let dummyZone = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: dummyZone), action: .none)
        let profile = Profile(
            displayName: "Test GM",
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .guildMaster,
            iCloudUserID: CKRecord.ID(recordName: "u1", zoneID: dummyZone),
            family: familyRef
        )

        do {
            _ = try await familyService.createFamily(name: "   ", ownerProfile: profile)
            #expect(Bool(false), "Expected empty name error")
        } catch let error as FamilyServiceError {
            #expect(error == FamilyServiceError.creationFailed("Family name cannot be empty."))
        } catch {
            #expect(Bool(false), "Unexpected error type: \(error)")
        }
    }
}

//
//  QuestServiceTests+Queries.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

extension QuestServiceTests {
    // MARK: - Review remediation: no ad-hoc post-save CloudKit query

    @Test
    func `markComplete performs no ad-hoc post-save CloudKit query`() async throws {
        // Verify that markComplete performs no ad-hoc background CloudKit queries post-save.
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = QueryParkingCloudKitService(zoneID: zoneID)
        let scaffold = try MarkCompleteScaffold(cloudKitOverride: cloudKit)

        // Rejected seed keeps the local alreadyCompleted check below target
        // without any CloudKit read.
        scaffold.cache.upsertQuestCompletions([scaffold.completion(status: .rejected)])

        let service = scaffold.questService
        let quest = scaffold.quest
        let hero = scaffold.hero
        _ = try await service.markComplete(quest: quest, by: hero)

        // Give any fire-and-forget spawned `Task` a chance to schedule and enter
        // `cloudKit.query` (which would park). A short hop suffices because the
        // query mock records the hit synchronously on entry.
        try await Task.sleep(for: .milliseconds(50))

        #expect(
            cloudKit.queryHitCount == 0,
            "markComplete must not issue an ad-hoc post-save CloudKit query; SyncEngine is the single writer"
        )

        // Release any (none, post-remediation) parked query so the test cleans up.
        cloudKit.releaseQueries()
    }

    @Test
    func `verify resolves quest and hero from cache with zero CloudKit reads`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = NetworkCountingCloudKitService(zoneID: zoneID)
        let scaffold = try MarkCompleteScaffold(cloudKitOverride: cloudKit)

        // Seed quest, hero, and a pending completion into the cache only.
        scaffold.cache.upsertQuest(scaffold.quest)
        scaffold.cache.upsertProfile(scaffold.hero)
        let pending = scaffold.completion(status: .pending)
        scaffold.cache.upsertQuestCompletion(pending)

        // A completed sync pass stamped this family's quest/profile/completion
        // caches as fresh, so verify's cache-first resolution is trusted.
        scaffold.cache.markCacheFresh(familyRecordName: "fam1", type: .quest)
        scaffold.cache.markCacheFresh(familyRecordName: "fam1", type: .profile)
        scaffold.cache.markCacheFresh(familyRecordName: "fam1", type: .questCompletion)

        // verify is parent-only — override the scaffold's default hero acting
        // session to the parent performing the verification.
        scaffold.appState.currentProfile = scaffold.parent
        let saved = try await scaffold.questService.verify(questLog: pending, by: scaffold.parent)

        #expect(saved.verificationStatus == .verified)
        #expect(
            cloudKit.readCallCount == 0,
            "verify must resolve quest + hero from cache when fresh"
        )

        let cached = scaffold.cache.fetchQuestCompletions(family: scaffold.familyRef.recordID.recordName)
            .first(where: { $0.recordName == pending.id.recordName })
        #expect(
            cached?.toQuestCompletion(zoneID: zoneID).verificationStatus == .verified,
            "Cache must hold the verified completion after verify"
        )
    }

    @Test
    func `reject works from cache with zero CloudKit reads`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = NetworkCountingCloudKitService(zoneID: zoneID)
        let scaffold = try MarkCompleteScaffold(cloudKitOverride: cloudKit)

        let pending = scaffold.completion(status: .pending)
        scaffold.cache.upsertQuestCompletion(pending)

        // reject is parent-only — override the scaffold's default hero acting
        // session to the parent performing the rejection.
        scaffold.appState.currentProfile = scaffold.parent
        let saved = try await scaffold.questService.reject(questLog: pending, by: scaffold.parent)

        #expect(saved.verificationStatus == .rejected)
        #expect(
            cloudKit.readCallCount == 0,
            "reject must perform no CloudKit reads"
        )

        let cached = scaffold.cache.fetchQuestCompletions(family: scaffold.familyRef.recordID.recordName)
            .first(where: { $0.recordName == pending.id.recordName })
        #expect(
            cached?.toQuestCompletion(zoneID: zoneID).verificationStatus == .rejected,
            "Cache must hold the rejected completion after reject"
        )
    }

    // MARK: - Service-layer authorization (parent-only verification)

    @Test
    func `verify throws unauthorized when acting profile is a hero`() async throws {
        let scaffold = try MarkCompleteScaffold()
        let pending = scaffold.completion(status: .pending)
        scaffold.cache.upsertQuestCompletion(pending)

        // The authenticated session is a hero; passing the hero as the
        // verifier must be rejected before any status flip occurs.
        scaffold.appState.currentProfile = scaffold.hero
        await #expect(throws: FamilyServiceError.unauthorized) {
            try await scaffold.questService.verify(questLog: pending, by: scaffold.hero)
        }

        // The completion must remain untouched: still pending.
        let cached = scaffold.cache.fetchQuestCompletions(family: scaffold.familyRef.recordID.recordName)
            .first(where: { $0.recordName == pending.id.recordName })
        #expect(cached?.verificationStatusEnum == .pending)
    }

    @Test
    func `reject throws unauthorized when acting profile is a hero`() async throws {
        let scaffold = try MarkCompleteScaffold()
        let pending = scaffold.completion(status: .pending)
        scaffold.cache.upsertQuestCompletion(pending)

        scaffold.appState.currentProfile = scaffold.hero
        await #expect(throws: FamilyServiceError.unauthorized) {
            try await scaffold.questService.reject(questLog: pending, by: scaffold.hero)
        }

        let cached = scaffold.cache.fetchQuestCompletions(family: scaffold.familyRef.recordID.recordName)
            .first(where: { $0.recordName == pending.id.recordName })
        #expect(cached?.verificationStatusEnum == .pending)
    }

    @Test
    func `verify succeeds when acting profile is a ranger parent`() async throws {
        let scaffold = try MarkCompleteScaffold()
        let pending = scaffold.completion(status: .pending)
        scaffold.cache.upsertQuestCompletion(pending)
        // Seed quest + hero so verify's post-save reward resolution is served
        // from cache rather than a CloudKit fetch.
        scaffold.cache.upsertQuest(scaffold.quest)
        scaffold.cache.upsertProfile(scaffold.hero)
        scaffold.cache.markCacheFresh(familyRecordName: "fam1", type: .quest)
        scaffold.cache.markCacheFresh(familyRecordName: "fam1", type: .profile)
        scaffold.cache.markCacheFresh(familyRecordName: "fam1", type: .questCompletion)

        // Rangers are parent roles and may verify completions.
        let ranger = Profile(
            displayName: "Ranger",
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .ranger,
            iCloudUserID: CKRecord.ID(recordName: "r1", zoneID: scaffold.zoneID),
            family: scaffold.familyRef,
            id: CKRecord.ID(recordName: "ranger1", zoneID: scaffold.zoneID)
        )

        // The authenticated session is the ranger verifying the completion.
        scaffold.appState.currentProfile = ranger
        let saved = try await scaffold.questService.verify(questLog: pending, by: ranger)

        #expect(saved.verificationStatus == .verified)
        #expect(saved.verifiedBy?.recordID.recordName == ranger.id.recordName)
    }

    @Test
    func `verify throws unauthorized when acting hero passes another parent's profile`() async throws {
        let scaffold = try MarkCompleteScaffold()
        let pending = scaffold.completion(status: .pending)
        scaffold.cache.upsertQuestCompletion(pending)

        // The authenticated session is a hero. Because parent Profiles are
        // visible to every family member, the hero attempts to self-approve
        // their own parentVerify quest by passing a DIFFERENT parent's Profile.
        // The acting session profile must match the caller-supplied verifier's
        // identity AND hold a parent role, so this must throw unauthorized.
        scaffold.appState.currentProfile = scaffold.hero
        let otherParent = Profile(
            displayName: "Other GM",
            avatarClass: .knight,
            avatarPresetID: "knight_02",
            role: .guildMaster,
            iCloudUserID: CKRecord.ID(recordName: "gm2", zoneID: scaffold.zoneID),
            family: scaffold.familyRef,
            id: CKRecord.ID(recordName: "gm2", zoneID: scaffold.zoneID)
        )

        await #expect(throws: FamilyServiceError.unauthorized) {
            try await scaffold.questService.verify(questLog: pending, by: otherParent)
        }

        // The completion must remain untouched: still pending.
        let cached = scaffold.cache.fetchQuestCompletions(family: scaffold.familyRef.recordID.recordName)
            .first(where: { $0.recordName == pending.id.recordName })
        #expect(cached?.verificationStatusEnum == .pending)
    }

    @Test
    func `reject throws unauthorized when acting hero passes another parent's profile`() async throws {
        let scaffold = try MarkCompleteScaffold()
        let pending = scaffold.completion(status: .pending)
        scaffold.cache.upsertQuestCompletion(pending)

        // Same forgery attempt as verify: a hero passing another parent's
        // Profile to reject must throw unauthorized, leaving the completion
        // pending rather than rejected.
        scaffold.appState.currentProfile = scaffold.hero
        let otherParent = Profile(
            displayName: "Other GM",
            avatarClass: .knight,
            avatarPresetID: "knight_02",
            role: .guildMaster,
            iCloudUserID: CKRecord.ID(recordName: "gm2", zoneID: scaffold.zoneID),
            family: scaffold.familyRef,
            id: CKRecord.ID(recordName: "gm2", zoneID: scaffold.zoneID)
        )

        await #expect(throws: FamilyServiceError.unauthorized) {
            try await scaffold.questService.reject(questLog: pending, by: otherParent)
        }

        let cached = scaffold.cache.fetchQuestCompletions(family: scaffold.familyRef.recordID.recordName)
            .first(where: { $0.recordName == pending.id.recordName })
        #expect(cached?.verificationStatusEnum == .pending)
    }

    // MARK: - markComplete identity guard (hero self-action)

    @Test
    func `markComplete rejects unauthorized hero passing wrong profile`() async throws {
        // A hero passing another profile's identity (any profile — hero or
        // parent — that is not the authenticated session) must throw
        // unauthorized before any completion is written. The guard prevents
        // an attacker who can read the family's profile list from forging a
        // `completedBy` reference for someone else.
        let scaffold = try MarkCompleteScaffold()

        // The authenticated session is the scaffold's hero. The completer
        // argument is a DIFFERENT hero — identity does not match.
        scaffold.appState.currentProfile = scaffold.hero
        let otherHero = Profile(
            displayName: "Other Hero",
            avatarClass: .mage,
            avatarPresetID: "mage_02",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "hero2", zoneID: scaffold.zoneID),
            family: scaffold.familyRef,
            id: CKRecord.ID(recordName: "hero2", zoneID: scaffold.zoneID)
        )

        await #expect(throws: FamilyServiceError.unauthorized) {
            try await scaffold.questService.markComplete(quest: scaffold.quest, by: otherHero)
        }

        // No completion may be written on the rejected path.
        let logs = scaffold.cache.fetchQuestCompletions(family: scaffold.familyRef.recordID.recordName)
            .filter { $0.questRecordName == scaffold.quest.id.recordName }
        #expect(
            logs.isEmpty,
            "markComplete must not write a completion when the acting profile does not match the completer"
        )
    }

    // MARK: - Parent-only mutation guards (templates + assignments)

    @Test
    func `createTemplate rejects non-parent creator`() async throws {
        let scaffold = try MarkCompleteScaffold()

        // Authenticated session is the hero — createTemplate is parent-only.
        scaffold.appState.currentProfile = scaffold.hero

        await #expect(throws: FamilyServiceError.unauthorized) {
            _ = try await scaffold.questService.createTemplate(
                name: "Unauthorized",
                description: "",
                defaultGold: 5.0,
                xpReward: 10,
                createdBy: scaffold.hero,
                family: Family(
                    name: "Guild",
                    createdBy: scaffold.parent.id,
                    id: CKRecord.ID(recordName: "fam1", zoneID: scaffold.zoneID)
                )
            )
        }

        let templates = scaffold.cache.fetchQuestTemplates(family: "fam1")
            .filter { $0.name == "Unauthorized" }
        #expect(
            templates.isEmpty,
            "createTemplate must not write a template when the actor is not a parent"
        )
    }

    @Test
    func `updateTemplate rejects non-parent actor`() async throws {
        let scaffold = try MarkCompleteScaffold()
        // Seed a template the unauthorized actor attempts to edit.
        let template = QuestTemplate(
            name: "Edit Target",
            description: "desc",
            defaultGold: 5,
            xpReward: 10,
            scheduleType: .weeklyFlexible,
            specificDays: [],
            targetCount: 1,
            createdBy: CKRecord.Reference(recordID: scaffold.parent.id, action: .none),
            family: scaffold.familyRef,
            id: CKRecord.ID(recordName: "tmpl_edit", zoneID: scaffold.zoneID)
        )
        scaffold.cache.upsertQuestTemplate(template)

        // Authenticated session is a hero — updateTemplate is parent-only.
        scaffold.appState.currentProfile = scaffold.hero

        await #expect(throws: FamilyServiceError.unauthorized) {
            _ = try await scaffold.questService.updateTemplate(template)
        }
    }

    @Test
    func `deactivateTemplate rejects non-parent actor`() async throws {
        let scaffold = try MarkCompleteScaffold()
        let template = QuestTemplate(
            name: "Deactivate Target",
            description: "desc",
            defaultGold: 5,
            xpReward: 10,
            scheduleType: .weeklyFlexible,
            specificDays: [],
            targetCount: 1,
            createdBy: CKRecord.Reference(recordID: scaffold.parent.id, action: .none),
            family: scaffold.familyRef,
            id: CKRecord.ID(recordName: "tmpl_deactivate", zoneID: scaffold.zoneID)
        )
        scaffold.cache.upsertQuestTemplate(template)

        scaffold.appState.currentProfile = scaffold.hero

        await #expect(throws: FamilyServiceError.unauthorized) {
            _ = try await scaffold.questService.deactivateTemplate(template)
        }
    }

    @Test
    func `assignQuest rejects non-parent`() async throws {
        let scaffold = try MarkCompleteScaffold()
        let template = QuestTemplate(
            name: "Assign Target",
            description: "desc",
            defaultGold: 10,
            xpReward: 20,
            scheduleType: .weeklyFlexible,
            specificDays: [],
            targetCount: 1,
            createdBy: CKRecord.Reference(recordID: scaffold.parent.id, action: .none),
            family: scaffold.familyRef,
            id: CKRecord.ID(recordName: "tmpl_assign", zoneID: scaffold.zoneID)
        )
        scaffold.cache.upsertQuestTemplate(template)

        // Authenticated session is a hero — assignQuest is parent-only.
        scaffold.appState.currentProfile = scaffold.hero

        await #expect(throws: FamilyServiceError.unauthorized) {
            _ = try await scaffold.questService.assignQuest(
                template: template,
                assignee: scaffold.hero,
                weekOf: WeekMath.mondayOfWeek(for: Date()),
                createdBy: scaffold.hero,
                family: Family(
                    name: "Guild",
                    createdBy: scaffold.parent.id,
                    id: CKRecord.ID(recordName: "fam1", zoneID: scaffold.zoneID)
                )
            )
        }
    }

    @Test
    func `assignQuickQuest rejects non-parent`() async throws {
        let scaffold = try MarkCompleteScaffold()

        scaffold.appState.currentProfile = scaffold.hero

        await #expect(throws: FamilyServiceError.unauthorized) {
            _ = try await scaffold.questService.assignQuickQuest(
                name: "Unauthorized Quick",
                description: "",
                assignee: scaffold.hero,
                goldReward: 5,
                xpReward: 10,
                weekOf: WeekMath.mondayOfWeek(for: Date()),
                createdBy: scaffold.hero,
                family: Family(
                    name: "Guild",
                    createdBy: scaffold.parent.id,
                    id: CKRecord.ID(recordName: "fam1", zoneID: scaffold.zoneID)
                )
            )
        }
    }

    @Test
    func `updateQuest rejects non-parent`() async throws {
        let scaffold = try MarkCompleteScaffold()
        scaffold.cache.upsertQuest(scaffold.quest)

        scaffold.appState.currentProfile = scaffold.hero

        await #expect(throws: FamilyServiceError.unauthorized) {
            _ = try await scaffold.questService.updateQuest(scaffold.quest)
        }
    }

    @Test
    func `unassignQuest rejects a stranger hero`() async throws {
        let scaffold = try MarkCompleteScaffold()
        scaffold.cache.upsertQuest(scaffold.quest)

        // A non-parent hero who is NOT the quest's assignee cannot unassign
        // another hero's quest.
        let stranger = Profile(
            displayName: "Stranger Hero",
            avatarClass: .mage,
            avatarPresetID: "mage_01",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "hero2", zoneID: scaffold.zoneID),
            family: scaffold.familyRef,
            id: CKRecord.ID(recordName: "hero2", zoneID: scaffold.zoneID)
        )
        scaffold.appState.currentProfile = stranger

        await #expect(throws: FamilyServiceError.unauthorized) {
            try await scaffold.questService.unassignQuest(scaffold.quest)
        }
    }

    @Test
    func `unassignQuest rejects unauthenticated actor`() async throws {
        let scaffold = try MarkCompleteScaffold()
        scaffold.cache.upsertQuest(scaffold.quest)

        scaffold.appState.currentProfile = nil

        await #expect(throws: FamilyServiceError.unauthorized) {
            try await scaffold.questService.unassignQuest(scaffold.quest)
        }
    }

    @Test
    func `unassignQuest allows the assignee hero to unassign their own quest`() async throws {
        let scaffold = try MarkCompleteScaffold()
        scaffold.cache.upsertQuest(scaffold.quest)
        scaffold.seedMockRecords([scaffold.quest])

        // The quest's own assignee may unassign it (self-service leave
        // cleanup). The scaffold's hero is the assignee of `scaffold.quest`.
        scaffold.appState.currentProfile = scaffold.hero

        try await scaffold.questService.unassignQuest(scaffold.quest)

        // Local-first: The quest is immediately invalidated in the cache
        let familyName = scaffold.familyRef.recordID.recordName
        #expect(scaffold.cache.fetchQuest(recordName: scaffold.quest.id.recordName, family: familyName) == nil)
    }
}

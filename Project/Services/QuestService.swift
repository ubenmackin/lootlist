//
//  QuestService.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
import os
import Synchronization

enum QuestServiceError: Error, Equatable, Sendable {
    case missingSession

    case alreadyCompleted

    case alreadyInFlight

    case alreadyResolved(String)

    case missingRecord(String)

    case staleData(String)
}

@MainActor
@Observable
final class QuestService {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "QuestService")
    let cloudKit: any CloudKitServiceProtocol

    let xpService: XPService
    let notificationService: NotificationService?

    var cacheService: CacheService?
    var treasuryService: TreasuryService?
    var achievementService: AchievementService?
    /// Loot-drop reward surface for quest completions. Set by `AppDependencies`
    /// after `LootDropService` is constructed (it owns `GemService`). Optional
    /// so read-only callers (tests) need not set it.
    var lootDropService: LootDropService?
    var syncCoordinator: CKSyncEngineCoordinator?

    /// The active session's app state, used to resolve the acting profile for
    /// privileged quest verification. Wired by `AppDependencies`; optional so
    /// read-only callers (tests) need not set it.
    var appState: AppState?

    let toastManager: ToastManager?

    var cloudKitReference: any CloudKitServiceProtocol {
        cloudKit
    }

    let calendar: Calendar = .iso8601UTC

    /// Record names of quests with a completion save currently in flight.
    /// Local double-submit guard: a second `markComplete` tap for the
    /// same quest while a save is pending is a no-op/toast instead of a
    /// duplicate write. Actor-safe via `Mutex`; entries are inserted
    /// before the optimistic write and released when the save settles.
    let inFlightCompletions = Mutex<Set<String>>([])

    /// Record names of quest completions with a verify/reject action currently in flight.
    let inFlightVerifications = Mutex<Set<String>>([])

    /// Record names of quest completions with a withdrawal action currently in flight.
    let inFlightWithdrawals = Mutex<Set<String>>([])

    init(cloudKit: any CloudKitServiceProtocol,
         xpService: XPService,
         notificationService: NotificationService? = nil,
         cacheService: CacheService? = nil,
         treasuryService: TreasuryService? = nil,
         toastManager: ToastManager? = nil,
         appState: AppState? = nil,
         syncCoordinator: CKSyncEngineCoordinator? = nil)
    {
        self.cloudKit = cloudKit
        self.xpService = xpService
        self.notificationService = notificationService
        self.cacheService = cacheService
        self.treasuryService = treasuryService
        self.appState = appState
        self.toastManager = toastManager
        self.syncCoordinator = syncCoordinator
    }

    // MARK: - Quest Templates

    @discardableResult
    func createTemplate(name: String,
                        description: String = "",
                        defaultGold: Double,
                        xpReward: Int,
                        schedule: QuestSchedule = .weeklyFlexible,
                        specificDays: [String] = [],
                        targetCount: Int = 1,
                        isAllOrNothing: Bool = false,
                        approvalMode: ApprovalMode = .autoApprove,
                        createdBy: Profile,
                        family: Family) async throws -> QuestTemplate
    {
        guard let appState, let acting = appState.currentProfile,
              acting.id == createdBy.id,
              acting.role.isParent
        else {
            throw FamilyServiceError.unauthorized
        }
        guard createdBy.family.recordID == family.id,
              createdBy.id.zoneID == family.id.zoneID
        else {
            throw FamilyServiceError.unauthorized
        }
        try ActiveFamilyScopeGuard.requireActiveFamilyScope(
            family: family,
            cloudKit: cloudKit,
            appState: appState
        )

        let template = QuestTemplate(
            name: name,
            description: description,
            defaultGold: defaultGold,
            xpReward: xpReward,
            scheduleType: schedule,
            specificDays: schedule.requiresSpecificDays ? specificDays : [],
            targetCount: max(1, targetCount),
            isAllOrNothing: isAllOrNothing,
            approvalMode: approvalMode,
            createdBy: CKRecord.Reference(recordID: createdBy.id, action: .none),
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: CKRecord.ID(recordName: UUID().uuidString, zoneID: family.id.zoneID)
        )

        cacheService?.upsertQuestTemplate(template)
        let isOwner = appState.isZoneOwner
        syncCoordinator?.enqueueSave(recordID: template.id, isOwner: isOwner)
        return template
    }

    @discardableResult
    func updateTemplate(_ template: QuestTemplate) async throws -> QuestTemplate {
        guard let appState, let acting = appState.currentProfile,
              acting.role.isParent
        else {
            throw FamilyServiceError.unauthorized
        }
        try ActiveFamilyScopeGuard.requireActiveFamilyScope(
            familyRef: template.family,
            zoneID: template.id.zoneID,
            appState: appState,
            cloudKit: cloudKit
        )

        cacheService?.upsertQuestTemplate(template)
        let isOwner = appState.isZoneOwner
        syncCoordinator?.enqueueSave(recordID: template.id, isOwner: isOwner)
        return template
    }

    @discardableResult
    func deactivateTemplate(_ template: QuestTemplate) async throws -> QuestTemplate {
        guard let appState, let acting = appState.currentProfile,
              acting.role.isParent
        else {
            throw FamilyServiceError.unauthorized
        }
        try ActiveFamilyScopeGuard.requireActiveFamilyScope(
            familyRef: template.family,
            zoneID: template.id.zoneID,
            appState: appState,
            cloudKit: cloudKit
        )

        var deactivated = template
        deactivated.isActive = false

        cacheService?.upsertQuestTemplate(deactivated)
        let isOwner = appState.isZoneOwner
        syncCoordinator?.enqueueSave(recordID: deactivated.id, isOwner: isOwner)
        return deactivated
    }

    /// Cache-first read. Background refresh handled by CKSyncEngine.
    func fetchTemplates(family: Family) async throws -> [QuestTemplate] {
        if let cache = cacheService {
            let familyName = family.id.recordName
            let cached = cache.fetchQuestTemplates(family: familyName)
            if cache.isCacheFresh(familyRecordName: familyName, type: .questTemplate) {
                return cached.map { $0.toQuestTemplate(zoneID: family.id.zoneID) }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
        }

        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let predicate = NSPredicate(format: "family == %@", familyRef)
        let all = try await cloudKit.query(QuestTemplate.self, predicate: predicate, in: family.id.zoneID)
        cacheService?.upsertQuestTemplates(all)
        return all
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    func assignQuest(template: QuestTemplate,
                     assignee: Profile,
                     goldOverride: Double? = nil,
                     xpOverride: Int? = nil,
                     approvalOverride: ApprovalMode? = nil,
                     nameOverride: String? = nil,
                     weekOf: Date,
                     createdBy: Profile,
                     family: Family) async throws -> Quest
    {
        guard let appState, let acting = appState.currentProfile,
              acting.id == createdBy.id,
              acting.role.isParent
        else {
            throw FamilyServiceError.unauthorized
        }
        guard template.family.recordID == family.id,
              template.id.zoneID == family.id.zoneID,
              assignee.family.recordID == family.id,
              assignee.id.zoneID == family.id.zoneID,
              createdBy.family.recordID == family.id,
              createdBy.id.zoneID == family.id.zoneID
        else {
            throw FamilyServiceError.unauthorized
        }
        try ActiveFamilyScopeGuard.requireActiveFamilyScope(
            family: family,
            cloudKit: cloudKit,
            appState: appState
        )

        let payoutDay = assignee.payoutDay ?? family.payoutDay
        let normalizedWeek = WeekMath.startOfWeek(for: weekOf, payoutDay: payoutDay)
        let questName = nameOverride.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            ?? template.name

        let quest = Quest(
            template: CKRecord.Reference(recordID: template.id, action: .none),
            assignee: CKRecord.Reference(recordID: assignee.id, action: .none),
            goldReward: goldOverride ?? template.defaultGold,
            xpReward: xpOverride ?? template.xpReward,
            scheduleType: template.scheduleType,
            targetCount: template.targetCount,
            isAllOrNothing: template.isAllOrNothing,
            approvalMode: approvalOverride ?? template.approvalMode,
            weekOf: normalizedWeek,
            createdBy: CKRecord.Reference(recordID: createdBy.id, action: .none),
            family: CKRecord.Reference(recordID: family.id, action: .none),
            name: questName,
            descriptionText: template.description,
            id: CKRecord.ID(recordName: UUID().uuidString, zoneID: family.id.zoneID)
        )

        cacheService?.upsertQuest(quest)
        let isOwner = appState.isZoneOwner
        syncCoordinator?.enqueueSave(recordID: quest.id, isOwner: isOwner)
        sendAssignmentNotification(to: assignee, questName: questName)
        return quest
    }

    @discardableResult
    func updateQuest(_ quest: Quest) async throws -> Quest {
        guard let appState, let acting = appState.currentProfile,
              acting.role.isParent
        else {
            throw FamilyServiceError.unauthorized
        }
        try ActiveFamilyScopeGuard.requireActiveFamilyScope(
            familyRef: quest.family,
            zoneID: quest.id.zoneID,
            appState: appState,
            cloudKit: cloudKit
        )

        cacheService?.upsertQuest(quest)
        let isOwner = appState.isZoneOwner
        syncCoordinator?.enqueueSave(recordID: quest.id, isOwner: isOwner)
        return quest
    }

    @discardableResult
    func assignQuickQuest(name: String,
                          description: String = "",
                          assignee: Profile,
                          goldReward: Double,
                          xpReward: Int,
                          scheduleType: QuestSchedule = .weeklyFlexible,
                          specificDays: [String] = [],
                          targetCount: Int = 1,
                          approvalMode: ApprovalMode = .autoApprove,
                          weekOf: Date,
                          createdBy: Profile,
                          family: Family) async throws -> Quest
    {
        guard let appState, let acting = appState.currentProfile,
              acting.id == createdBy.id,
              acting.role.isParent
        else {
            throw FamilyServiceError.unauthorized
        }
        guard assignee.family.recordID == family.id,
              assignee.id.zoneID == family.id.zoneID,
              createdBy.family.recordID == family.id,
              createdBy.id.zoneID == family.id.zoneID
        else {
            throw FamilyServiceError.unauthorized
        }
        try ActiveFamilyScopeGuard.requireActiveFamilyScope(
            family: family,
            cloudKit: cloudKit,
            appState: appState
        )

        // Generate ad-hoc inactive template so it doesn't clutter routine template list
        let adhocTemplate = try await createTemplate(
            name: name,
            description: description,
            defaultGold: goldReward,
            xpReward: xpReward,
            schedule: scheduleType,
            specificDays: specificDays,
            targetCount: targetCount,
            approvalMode: approvalMode,
            createdBy: createdBy,
            family: family
        )
        _ = try await deactivateTemplate(adhocTemplate)

        let payoutDay = assignee.payoutDay ?? family.payoutDay
        let normalizedWeek = WeekMath.startOfWeek(for: weekOf, payoutDay: payoutDay)

        let quest = Quest(
            template: CKRecord.Reference(recordID: adhocTemplate.id, action: .none),
            assignee: CKRecord.Reference(recordID: assignee.id, action: .none),
            goldReward: goldReward,
            xpReward: xpReward,
            scheduleType: scheduleType,
            targetCount: max(1, targetCount),
            isAllOrNothing: false,
            approvalMode: approvalMode,
            weekOf: normalizedWeek,
            createdBy: CKRecord.Reference(recordID: createdBy.id, action: .none),
            family: CKRecord.Reference(recordID: family.id, action: .none),
            name: name,
            descriptionText: description,
            id: CKRecord.ID(recordName: UUID().uuidString, zoneID: family.id.zoneID)
        )

        cacheService?.upsertQuest(quest)
        let isOwner = appState.isZoneOwner
        syncCoordinator?.enqueueSave(recordID: quest.id, isOwner: isOwner)
        sendAssignmentNotification(to: assignee, questName: name)
        return quest
    }

    func unassignQuest(_ quest: Quest) async throws {
        guard let appState, let acting = appState.currentProfile,
              acting.role.isParent || acting.id == quest.assignee.recordID
        else {
            throw FamilyServiceError.unauthorized
        }
        try ActiveFamilyScopeGuard.requireActiveFamilyScope(
            familyRef: quest.family,
            zoneID: quest.id.zoneID,
            appState: appState,
            cloudKit: cloudKit
        )

        let isOwner = appState.isZoneOwner
        if acting.role.isParent, isCarryForwardSuppressible(quest) {
            var tombstone = quest
            tombstone.active = false
            cacheService?.upsertQuest(tombstone)
            syncCoordinator?.enqueueSave(recordID: tombstone.id, isOwner: isOwner)
            return
        }

        let identity = ScopedRecordIdentity(
            databaseScope: isOwner ? .private : .shared,
            zoneID: quest.id.zoneID,
            recordID: quest.id,
            familyRecordName: quest.family.recordID.recordName
        )
        cacheService?.invalidateQuest(identity: identity)
        syncCoordinator?.enqueueDelete(recordID: quest.id, isOwner: isOwner)
    }

    /// Cache-first read. On cold cache miss, falls back to a single synchronous
    /// CloudKit query to hydrate. Background ongoing refresh handled by
    /// CKSyncEngine via push notifications.
    func fetchActiveQuests(profile: Profile, weekOf: Date) async throws -> [Quest] {
        let range = QuestService.weekRange(for: weekOf, payoutDay: effectivePayoutDay(for: profile))

        // Cache-first: check local cache
        if let cache = cacheService {
            let profileName = profile.id.recordName
            let familyName = profile.family.recordID.recordName
            let cached = cache.fetchQuests(family: familyName, weekInRange: range)
                .filter { $0.assigneeRecordName == profileName && $0.isActive && range.contains($0.weekOf) }
            if cache.isCacheFresh(familyRecordName: familyName, type: .quest) {
                return cached.map { $0.toQuest(zoneID: profile.id.zoneID) }
            }
        }

        let assigneeRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let predicate = NSPredicate(format: "assignee == %@", assigneeRef)
        let all = try await cloudKit.query(Quest.self, predicate: predicate, in: profile.id.zoneID)
        let stampedAll = await stampAllQuests(all)
        cacheService?.upsertQuests(stampedAll)
        return stampedAll
            .filter { $0.active && range.contains($0.weekOf) }
            .sorted { $0.template.recordID.recordName < $1.template.recordID.recordName }
    }

    /// Cache-first read. On cold cache miss, falls back to a single synchronous
    /// CloudKit query to hydrate. Background ongoing refresh handled by
    /// CKSyncEngine via push notifications.
    func fetchQuestsForFamilyWeek(family: Family, weekOf: Date) async throws -> [Quest] {
        let range = QuestService.weekRange(for: weekOf, payoutDay: family.payoutDay)

        if let cache = cacheService {
            let familyName = family.id.recordName
            let cached = cache.fetchQuests(family: familyName, weekInRange: range)
                .filter { $0.isActive && range.contains($0.weekOf) }
            if cache.isCacheFresh(familyRecordName: familyName, type: .quest) {
                return cached.map { $0.toQuest(zoneID: family.id.zoneID) }
            }
        }

        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let predicate = NSPredicate(format: "family == %@", familyRef)
        let all = try await cloudKit.query(Quest.self, predicate: predicate, in: family.id.zoneID)
        let stampedAll = await stampAllQuests(all)
        cacheService?.upsertQuests(stampedAll)
        return stampedAll
            .filter { $0.active && range.contains($0.weekOf) }
            .sorted { $0.assignee.recordID.recordName < $1.assignee.recordID.recordName }
    }

    /// Deactivates uncompleted quests from past weeks whose payouts have been
    /// finalized, so they no longer appear on primary active quest views. The
    /// current week is never swept: a mid-week early payout finalizes the week's
    /// earnings but must not retire quests the hero is still completing.
    @discardableResult
    func sweepExpiredQuests(family: Family, currentWeekOf: Date) async throws -> [Quest] {
        guard let appState, let acting = appState.currentProfile, acting.role.isParent else {
            throw FamilyServiceError.unauthorized
        }
        try ActiveFamilyScopeGuard.requireActiveFamilyScope(
            family: family,
            cloudKit: cloudKit,
            appState: appState
        )

        let familyName = family.id.recordName
        let normalizedCurrentWeek = WeekMath.startOfWeek(for: currentWeekOf, payoutDay: family.payoutDay)

        // Query allowance periods to identify weeks whose payouts have been completed (.paid)
        let allowancePeriods: [AllowancePeriod]
        if let cache = cacheService, cache.isCacheFresh(familyRecordName: familyName, type: .allowancePeriod) {
            allowancePeriods = cache.fetchAllowancePeriods(family: familyName)
                .map { $0.toAllowancePeriod(zoneID: family.id.zoneID) }
        } else {
            let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
            let predicate = NSPredicate(format: "family == %@", familyRef)
            allowancePeriods = await (try? cloudKit.query(AllowancePeriod.self, predicate: predicate, in: family.id.zoneID)) ?? []
        }

        let paidWeeks = Set(allowancePeriods.filter { $0.status == .paid }.map { Calendar.iso8601UTC.startOfDay(for: $0.weekOf) })

        let allQuests: [Quest]
        if let cache = cacheService, cache.isCacheFresh(familyRecordName: familyName, type: .quest) {
            allQuests = cache.fetchQuests(family: familyName)
                .filter(\.isActive)
                .map { $0.toQuest(zoneID: family.id.zoneID) }
        } else {
            let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
            let predicate = NSPredicate(format: "family == %@", familyRef)
            allQuests = try await cloudKit.query(Quest.self, predicate: predicate, in: family.id.zoneID)
                .filter(\.active)
        }

        var deactivated: [Quest] = []
        let isOwner = appState.isZoneOwner
        for var quest in allQuests {
            let questWeekStart = Calendar.iso8601UTC.startOfDay(for: quest.weekOf)
            if questWeekStart < normalizedCurrentWeek, paidWeeks.contains(questWeekStart) {
                quest.active = false
                cacheService?.upsertQuest(quest)
                syncCoordinator?.enqueueSave(recordID: quest.id, isOwner: isOwner)
                deactivated.append(quest)
            }
        }
        return deactivated
    }

    private func stampNameIfNeeded(_ quest: Quest) async -> Quest {
        guard quest.name == nil else { return quest }
        guard let template = try? await cloudKit.fetch(QuestTemplate.self, id: quest.template.recordID) else {
            return quest
        }
        var updated = quest
        updated.name = template.name
        cacheService?.upsertQuest(updated)
        return updated
    }

    private func stampAllQuests(_ quests: [Quest]) async -> [Quest] {
        var stamped: [Quest] = []
        stamped.reserveCapacity(quests.count)
        for quest in quests {
            await stamped.append(stampNameIfNeeded(quest))
        }
        return stamped
    }

    func sendAssignmentNotification(to assignee: Profile, questName: String) {
        guard let notificationService else { return }
        Task { @Sendable [logger] in
            do {
                try await notificationService.send(
                    .questAssigned,
                    to: assignee,
                    title: "⚔️ New Quest Assigned!",
                    body: "You have been assigned '\(questName)'."
                )
            } catch {
                logger.error("Failed to send assignment notification: \(error, privacy: .public)")
            }
        }
    }

    static func startOfWeek(for date: Date, payoutDay: PayoutDay = .sunday) -> Date {
        WeekMath.startOfWeek(for: date, payoutDay: payoutDay)
    }

    static func mondayOfWeek(for date: Date) -> Date {
        WeekMath.mondayOfWeek(for: date)
    }

    static func weekRange(for date: Date, payoutDay: PayoutDay = .sunday) -> Range<Date> {
        WeekMath.weekRange(starting: startOfWeek(for: date, payoutDay: payoutDay))
    }

    /// Resolves the effective payout day a profile's quests bucket by: the
    /// profile's own override wins, then the family's configured payout day
    /// (read from the local cache when present), falling back to the
    /// backward-compatible Sunday default when unknown. Mirrors the write-path
    /// normalization in `assignQuest`/`assignQuickQuest` so reads bucket by the
    /// same cycle the stored `weekOf` values were normalized to.
    func effectivePayoutDay(for profile: Profile) -> PayoutDay {
        if let profilePayoutDay = profile.payoutDay {
            return profilePayoutDay
        }
        let familyRecordName = profile.family.recordID.recordName
        if !familyRecordName.isEmpty,
           let cache = cacheService,
           cache.isCacheFresh(familyRecordName: familyRecordName, type: .family),
           let familyCache = cache.fetchFamily(recordName: familyRecordName),
           let familyPayoutDay = familyCache.payoutDayEnum
        {
            return familyPayoutDay
        }
        return .sunday
    }

    private func weekdayCodes(inWeekOf weekOf: Date) -> Set<String> {
        let codes = AppConstants.weekdayCodes
        var found: Set<String> = []
        for offset in 0 ..< 7 {
            let day = calendar.date(byAdding: .day, value: offset, to: weekOf) ?? weekOf
            let weekday = calendar.component(.weekday, from: day)
            let index = max(0, min(codes.count - 1, weekday - 1))
            found.insert(codes[index])
        }
        return found
    }

    /// True when `quest` is exactly what the weekly carry-forward engine would
    /// re-create after a hard delete: a removal from the current carry window
    /// whose backing template is still active. Mirrors the engine's own source
    /// filter (`activeTemplates`) from the same cache, day-normalized with the
    /// assignee's effective payout day — the same cycle `assignQuest` buckets
    /// the quest's `weekOf` into. Quick Create quests (inactive ad-hoc
    /// templates) and roster-cleanup quests (template gone) fail this check and
    /// keep the plain hard-delete semantics, since the engine can never re-create
    /// them in the first place.
    private func isCarryForwardSuppressible(_ quest: Quest) -> Bool {
        let assigneePayoutDay = cacheService?.fetchProfile(recordName: quest.assignee.recordID.recordName, family: quest.family.recordID.recordName)?.payoutDayEnum
            ?? cacheService?.fetchFamily(recordName: quest.family.recordID.recordName)?.payoutDayEnum
            ?? .sunday
        let currentWeekStart = WeekMath.startOfWeek(for: Date(), payoutDay: assigneePayoutDay)
        guard Calendar.iso8601UTC.startOfDay(for: quest.weekOf) == Calendar.iso8601UTC.startOfDay(for: currentWeekStart) else {
            return false
        }
        return cacheService?.fetchQuestTemplates(family: quest.family.recordID.recordName)
            .contains { $0.recordName == quest.template.recordID.recordName && $0.isActive } ?? false
    }
}

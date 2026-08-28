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

enum QuestServiceError: Error, Equatable, Sendable, LocalizedError {
    case missingSession

    case alreadyCompleted

    case alreadyInFlight

    case alreadyResolved(String)

    case missingRecord(String)

    case staleData(String)

    var errorDescription: String? {
        switch self {
        case .missingSession:
            "No active session — please sign in again."
        case .alreadyCompleted:
            "This quest has already been completed."
        case .alreadyInFlight:
            "This quest is already being processed."
        case let .alreadyResolved(detail):
            "This quest has already been resolved: \(detail)"
        case let .missingRecord(detail):
            "Quest record not found: \(detail)"
        case let .staleData(detail):
            "Quest data is out of date — please refresh: \(detail)"
        }
    }
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

    /// Guards against double-submit completions while a save is pending.
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

        await cacheService?.upsertQuestTemplate(template)
        // WHY: owner routing uses Family.creatorUserRecordName anchor via resolvedIsOwner, not role.
        let isOwner = ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState)
        let storedOwner = appState.isZoneOwner
        if isOwner != storedOwner {
            logger.warning("QuestService.createTemplate isOwner corrected via creator anchor: stored=\(storedOwner) resolved=\(isOwner)")
        }
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

        await cacheService?.upsertQuestTemplate(template)
        // WHY: owner routing uses Family.creatorUserRecordName anchor via resolvedIsOwner, not role.
        let isOwner = ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState)
        let storedOwner = appState.isZoneOwner
        if isOwner != storedOwner {
            logger.warning("QuestService.updateTemplate isOwner corrected via creator anchor: stored=\(storedOwner) resolved=\(isOwner)")
        }
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

        await cacheService?.upsertQuestTemplate(deactivated)
        // WHY: owner routing uses Family.creatorUserRecordName anchor via resolvedIsOwner, not role.
        let isOwner = ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState)
        let storedOwner = appState.isZoneOwner
        if isOwner != storedOwner {
            logger.warning("QuestService.deactivateTemplate isOwner corrected via creator anchor: stored=\(storedOwner) resolved=\(isOwner)")
        }
        syncCoordinator?.enqueueSave(recordID: deactivated.id, isOwner: isOwner)
        return deactivated
    }

    /// Cache-first read. Background refresh handled by CKSyncEngine.
    func fetchTemplates(family: Family) async throws -> [QuestTemplate] {
        if let cache = cacheService {
            let familyName = family.id.recordName
            let cached = cache.fetchQuestTemplates(family: familyName)
            let scope: CKDatabase.Scope = ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState) ? .private : .shared
            if cache.isCacheAuthoritative(familyRecordName: familyName, type: .questTemplate, scope: scope, cachedCount: cached.count) {
                return cached.map { $0.toQuestTemplate(zoneID: family.id.zoneID) }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
        }

        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let predicate = NSPredicate(format: "family == %@", familyRef)
        do {
            let all = try await cloudKit.query(QuestTemplate.self, predicate: predicate, in: family.id.zoneID)
            await syncCoordinator?.delegateHandler.hydrateFromQuery(
                models: all,
                databaseScope: ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState) ? .private : .shared,
                zoneID: family.id.zoneID
            )
            return all
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            // WHY: stale cache must re-validate via CloudKit; offline fallback renders stale cache explicitly at call site, not via authoritative predicate.
            logger.warning("fetchTemplates CloudKit query failed, falling back to stale cache: \(error, privacy: .private)")
            if let cache = cacheService {
                let cached = cache.fetchQuestTemplates(family: family.id.recordName)
                if !cached.isEmpty {
                    return cached.map { $0.toQuestTemplate(zoneID: family.id.zoneID) }
                        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                }
            }
            throw error
        }
    }

    /// Cache-first template fetch with server hydration fallback for local reads.
    func fetchTemplateCached(id: String, familyRecordName: String) async throws -> QuestTemplate? {
        guard let zoneID = appState?.familyZoneID else { return nil }
        return try await fetchTemplateCached(id: CKRecord.ID(recordName: id, zoneID: zoneID), familyRecordName: familyRecordName)
    }

    func fetchTemplateCached(id: CKRecord.ID, familyRecordName: String) async throws -> QuestTemplate? {
        if let cached = cacheService?.fetchQuestTemplate(recordName: id.recordName, family: familyRecordName) {
            return cached.toQuestTemplate(zoneID: id.zoneID)
        }

        let template = try await cloudKit.fetch(QuestTemplate.self, id: id)
        await syncCoordinator?.delegateHandler.hydrateFromQuery(
            models: [template],
            databaseScope: ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState) ? .private : .shared,
            zoneID: id.zoneID
        )
        return template
    }

    @discardableResult
    func assignQuest(template: QuestTemplate,
                     assignee: Profile,
                     goldOverride: Double? = nil,
                     xpOverride: Int? = nil,
                     approvalOverride: ApprovalMode? = nil,
                     isAllOrNothingOverride: Bool? = nil,
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
            isAllOrNothing: isAllOrNothingOverride ?? template.isAllOrNothing,
            approvalMode: approvalOverride ?? template.approvalMode,
            weekOf: normalizedWeek,
            createdBy: CKRecord.Reference(recordID: createdBy.id, action: .none),
            family: CKRecord.Reference(recordID: family.id, action: .none),
            name: questName,
            descriptionText: template.description,
            id: CKRecord.ID(recordName: UUID().uuidString, zoneID: family.id.zoneID)
        )

        await cacheService?.upsertQuest(quest)
        // WHY: owner routing uses Family.creatorUserRecordName anchor via resolvedIsOwner, not role.
        let isOwner = ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState)
        let storedOwner = appState.isZoneOwner
        if isOwner != storedOwner {
            logger.warning("QuestService.assignQuest isOwner corrected via creator anchor: stored=\(storedOwner) resolved=\(isOwner)")
        }
        syncCoordinator?.enqueueSave(recordID: quest.id, isOwner: isOwner)
        sendAssignmentNotification(to: assignee, questName: questName)
        return quest
    }

    @discardableResult
    func updateQuest(_ quest: Quest, newAssigneeRecordName: String? = nil) async throws -> Quest {
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

        var updatedQuest = quest
        if let newAssigneeRecordName {
            updatedQuest.assignee = CKRecord.Reference(recordID: CKRecord.ID(recordName: newAssigneeRecordName, zoneID: quest.id.zoneID), action: .none)
        }

        await cacheService?.upsertQuest(updatedQuest)
        // WHY: owner routing uses Family.creatorUserRecordName anchor via resolvedIsOwner, not role.
        let isOwner = ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState)
        let storedOwner = appState.isZoneOwner
        if isOwner != storedOwner {
            logger.warning("QuestService.updateQuest isOwner corrected via creator anchor: stored=\(storedOwner) resolved=\(isOwner)")
        }
        syncCoordinator?.enqueueSave(recordID: updatedQuest.id, isOwner: isOwner)
        return updatedQuest
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
                          isAllOrNothing: Bool = false,
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
            isAllOrNothing: isAllOrNothing,
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
            isAllOrNothing: isAllOrNothing,
            approvalMode: approvalMode,
            weekOf: normalizedWeek,
            createdBy: CKRecord.Reference(recordID: createdBy.id, action: .none),
            family: CKRecord.Reference(recordID: family.id, action: .none),
            name: name,
            descriptionText: description,
            id: CKRecord.ID(recordName: UUID().uuidString, zoneID: family.id.zoneID)
        )

        await cacheService?.upsertQuest(quest)
        // WHY: owner routing uses Family.creatorUserRecordName anchor via resolvedIsOwner, not role.
        let isOwner = ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState)
        let storedOwner = appState.isZoneOwner
        if isOwner != storedOwner {
            logger.warning("QuestService.assignQuickQuest isOwner corrected via creator anchor: stored=\(storedOwner) resolved=\(isOwner)")
        }
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

        // WHY: owner routing uses Family.creatorUserRecordName anchor via resolvedIsOwner, not role.
        let isOwner = ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState)
        let storedOwner = appState.isZoneOwner
        if isOwner != storedOwner {
            logger.warning("QuestService.unassignQuest isOwner corrected via creator anchor: stored=\(storedOwner) resolved=\(isOwner)")
        }
        let shouldRetainTombstone = acting.role.isParent && isCarryForwardSuppressible(quest)
        if shouldRetainTombstone {
            var tombstone = quest
            tombstone.active = false
            await cacheService?.upsertQuest(tombstone)
            syncCoordinator?.enqueueSave(recordID: tombstone.id, isOwner: isOwner)
            return
        }

        let identity = ScopedRecordIdentity(
            databaseScope: isOwner ? .private : .shared,
            zoneID: quest.id.zoneID,
            recordID: quest.id,
            familyRecordName: quest.family.recordID.recordName
        )
        // Pre-delete identity captured before invalidate; RecordBridge returns nil
        // for the dangling record and coordinator drain handles the tombstone.
        await cacheService?.invalidate(identity: identity, type: .quest, expectedActiveZone: appState.familyZoneID)
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
            let allForFamily = cache.fetchQuests(family: familyName)
            let cached = allForFamily.filter { $0.assigneeRecordName == profileName && $0.isActive && range.contains($0.weekOf) }
            let scope: CKDatabase.Scope = ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState) ? .private : .shared
            if cache.isCacheAuthoritative(familyRecordName: familyName, type: .quest, scope: scope, cachedCount: allForFamily.count) {
                return cached.map { $0.toQuest(zoneID: profile.id.zoneID) }
            }
        }

        let assigneeRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let predicate = NSPredicate(format: "assignee == %@", assigneeRef)
        do {
            let all = try await cloudKit.query(Quest.self, predicate: predicate, in: profile.id.zoneID)
            let stampedAll = await stampAllQuests(all)
            if let syncCoordinator {
                await syncCoordinator.delegateHandler.hydrateFromQuery(
                    models: stampedAll,
                    databaseScope: ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState) ? .private : .shared,
                    zoneID: profile.id.zoneID
                )
            } else {
                await cacheService?.upsertQuests(stampedAll)
            }
            return stampedAll
                .filter { $0.active && range.contains($0.weekOf) }
                .sorted { $0.template.recordID.recordName < $1.template.recordID.recordName }
        } catch {
            // WHY: stale cache must re-validate via CloudKit; offline fallback renders stale cache explicitly at call site, not via authoritative predicate.
            logger.warning("fetchActiveQuests CloudKit query failed, falling back to stale cache: \(error, privacy: .private)")
            if let cache = cacheService {
                let familyName = profile.family.recordID.recordName
                let allForFamily = cache.fetchQuests(family: familyName)
                let cached = allForFamily.filter { $0.assigneeRecordName == profile.id.recordName && $0.isActive && range.contains($0.weekOf) }
                if !cached.isEmpty {
                    return cached.map { $0.toQuest(zoneID: profile.id.zoneID) }
                }
                // Also return stale filtered empty when CloudKit fails offline — caller handles empty-cache-offline rendering.
                if !allForFamily.isEmpty {
                    return cached.map { $0.toQuest(zoneID: profile.id.zoneID) }
                }
            }
            throw error
        }
    }

    /// Cache-first read. On cold cache miss, falls back to a single synchronous
    /// CloudKit query to hydrate. Background ongoing refresh handled by
    /// CKSyncEngine via push notifications.
    func fetchQuestsForFamilyWeek(family: Family, weekOf: Date) async throws -> [Quest] {
        let range = QuestService.weekRange(for: weekOf, payoutDay: family.payoutDay)

        if let cache = cacheService {
            let familyName = family.id.recordName
            let allForFamily = cache.fetchQuests(family: familyName)
            let cached = allForFamily.filter { $0.isActive && range.contains($0.weekOf) }
            let scope: CKDatabase.Scope = ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState) ? .private : .shared
            if cache.isCacheAuthoritative(familyRecordName: familyName, type: .quest, scope: scope, cachedCount: allForFamily.count) {
                return cached.map { $0.toQuest(zoneID: family.id.zoneID) }
            }
        }

        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let predicate = NSPredicate(format: "family == %@", familyRef)
        do {
            let all = try await cloudKit.query(Quest.self, predicate: predicate, in: family.id.zoneID)
            let stampedAll = await stampAllQuests(all)
            if let syncCoordinator {
                await syncCoordinator.delegateHandler.hydrateFromQuery(
                    models: stampedAll,
                    databaseScope: ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState) ? .private : .shared,
                    zoneID: family.id.zoneID
                )
            } else {
                await cacheService?.upsertQuests(stampedAll)
            }
            return stampedAll
                .filter { $0.active && range.contains($0.weekOf) }
                .sorted { $0.assignee.recordID.recordName < $1.assignee.recordID.recordName }
        } catch {
            // WHY: stale cache must re-validate via CloudKit; offline fallback renders stale cache explicitly at call site, not via authoritative predicate.
            logger.warning("fetchQuestsForFamilyWeek CloudKit query failed, falling back to stale cache: \(error, privacy: .private)")
            if let cache = cacheService {
                let allForFamily = cache.fetchQuests(family: family.id.recordName)
                let cached = allForFamily.filter { $0.isActive && range.contains($0.weekOf) }
                if !cached.isEmpty {
                    return cached.map { $0.toQuest(zoneID: family.id.zoneID) }
                }
                // Return stale filtered (empty) when offline — caller handles empty-cache-offline rendering.
                if !allForFamily.isEmpty {
                    return cached.map { $0.toQuest(zoneID: family.id.zoneID) }
                }
            }
            throw error
        }
    }

    /// Deactivates uncompleted quests from past weeks on rollover.
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

        // Query allowance periods to identify weeks whose payouts have been completed (.paid)
        let allowancePeriods: [AllowancePeriod]
        if let cache = cacheService {
            let cached = cache.fetchAllowancePeriods(family: familyName)
            let scope: CKDatabase.Scope = ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState) ? .private : .shared
            if cache.isCacheAuthoritative(familyRecordName: familyName, type: .allowancePeriod, scope: scope, cachedCount: cached.count) {
                allowancePeriods = cached.map { $0.toAllowancePeriod(zoneID: family.id.zoneID) }
            } else {
                let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
                let predicate = NSPredicate(format: "family == %@", familyRef)
                do {
                    allowancePeriods = try await cloudKit.query(AllowancePeriod.self, predicate: predicate, in: family.id.zoneID)
                } catch {
                    logger.warning("Failed to fetch allowance periods from CloudKit: \(error, privacy: .private)")
                    allowancePeriods = cached.map { $0.toAllowancePeriod(zoneID: family.id.zoneID) }
                }
            }
        } else {
            let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
            let predicate = NSPredicate(format: "family == %@", familyRef)
            do {
                allowancePeriods = try await cloudKit.query(AllowancePeriod.self, predicate: predicate, in: family.id.zoneID)
            } catch {
                logger.warning("Failed to fetch allowance periods from CloudKit: \(error, privacy: .private)")
                allowancePeriods = []
            }
        }

        // Preserves raw weekOf timestamps matching the profile's normalized cycle.
        let paidWeeks = Set(allowancePeriods.filter { $0.status == .paid }.map(\.weekOf))

        let allQuests: [Quest]
        if let cache = cacheService {
            let cached = cache.fetchQuests(family: familyName).filter(\.isActive)
            let scope: CKDatabase.Scope = ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState) ? .private : .shared
            if cache.isCacheAuthoritative(familyRecordName: familyName, type: .quest, scope: scope, cachedCount: cached.count) {
                allQuests = cached.map { $0.toQuest(zoneID: family.id.zoneID) }
            } else {
                let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
                let predicate = NSPredicate(format: "family == %@", familyRef)
                do {
                    allQuests = try await cloudKit.query(Quest.self, predicate: predicate, in: family.id.zoneID).filter(\.active)
                } catch {
                    logger.warning("Failed to fetch quests from CloudKit: \(error, privacy: .private)")
                    allQuests = cached.map { $0.toQuest(zoneID: family.id.zoneID) }
                }
            }
        } else {
            let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
            let predicate = NSPredicate(format: "family == %@", familyRef)
            allQuests = try await cloudKit.query(Quest.self, predicate: predicate, in: family.id.zoneID)
                .filter(\.active)
        }

        var deactivated: [Quest] = []
        // WHY: owner routing uses Family.creatorUserRecordName anchor via resolvedIsOwner, not role.
        let isOwner = ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState)
        let storedOwner = appState.isZoneOwner
        if isOwner != storedOwner {
            logger.warning("QuestService.sweepExpiredQuests isOwner corrected via creator anchor: stored=\(storedOwner) resolved=\(isOwner)")
        }
        for var quest in allQuests {
            // Resolve effective payout day (profile override -> family -> .sunday fallback).
            let effectivePayoutDay = cacheService?.fetchProfile(recordName: quest.assignee.recordID.recordName, family: quest.family.recordID.recordName)?.payoutDayEnum
                ?? cacheService?.fetchFamily(recordName: quest.family.recordID.recordName)?.payoutDayEnum
                ?? family.payoutDay
            let questWeek = WeekMath.startOfWeek(for: quest.weekOf, payoutDay: effectivePayoutDay)
            let currentWeekForAssignee = WeekMath.startOfWeek(for: currentWeekOf, payoutDay: effectivePayoutDay)
            if questWeek < currentWeekForAssignee, paidWeeks.contains(questWeek) {
                quest.active = false
                await cacheService?.upsertQuest(quest)
                syncCoordinator?.enqueueSave(recordID: quest.id, isOwner: isOwner)
                deactivated.append(quest)
            }
        }
        return deactivated
    }

    private func stampNameIfNeeded(_ quest: Quest) async -> Quest {
        guard quest.name == nil else { return quest }
        let template: QuestTemplate
        do {
            template = try await cloudKit.fetch(QuestTemplate.self, id: quest.template.recordID)
        } catch {
            logger.debug("Template fetch failed for \(quest.id.recordName, privacy: .private): \(error, privacy: .private)")
            return quest
        }
        var updated = quest
        updated.name = template.name
        return updated
    }

    private func stampAllQuests(_ quests: [Quest]) async -> [Quest] {
        var stamped: [Quest] = []
        stamped.reserveCapacity(quests.count)
        var nameStamped: [Quest] = []
        for quest in quests {
            let resolved = await stampNameIfNeeded(quest)
            if resolved.name != quest.name {
                nameStamped.append(resolved)
            }
            stamped.append(resolved)
        }
        // Stamped names originate from server templates, so the rows re-enter
        // the cache through the single ingestion path; batching keeps N per-
        // quest stamps from becoming N separate ingest passes.
        if let zoneID = stamped.first?.id.zoneID {
            await syncCoordinator?.delegateHandler.hydrateFromQuery(
                models: nameStamped,
                databaseScope: ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState) ? .private : .shared,
                zoneID: zoneID
            )
        }
        return stamped
    }

    func sendAssignmentNotification(to assignee: Profile, questName: String) {
        guard let notificationService else { return }
        Task { @MainActor @Sendable [logger, notificationService, assignee, questName] in
            do {
                try await notificationService.send(
                    .questAssigned,
                    to: assignee,
                    title: "⚔️ New Quest Assigned!",
                    body: "You have been assigned '\(questName)'."
                )
            } catch {
                logger.error("Failed to send assignment notification: \(error, privacy: .private)")
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

    /// Resolves effective payout day (profile override -> family config -> Sunday default).
    func effectivePayoutDay(for profile: Profile) -> PayoutDay {
        if let profilePayoutDay = profile.payoutDay {
            return profilePayoutDay
        }
        let familyRecordName = profile.family.recordID.recordName
        if !familyRecordName.isEmpty,
           let cache = cacheService,
           let familyCache = cache.fetchFamily(recordName: familyRecordName),
           let familyPayoutDay = familyCache.payoutDayEnum
        {
            return familyPayoutDay
        }
        return .sunday
    }

    private func weekdayCodes(inWeekOf weekOf: Date) -> Set<String> {
        WeekMath.weekdayCodes(inWeekOf: weekOf)
    }

    /// Checks if quest matches template carry-forward state without local modifications.
    private func isCarryForwardSuppressible(_ quest: Quest) -> Bool {
        let assigneePayoutDay = cacheService?.fetchProfile(recordName: quest.assignee.recordID.recordName, family: quest.family.recordID.recordName)?.payoutDayEnum
            ?? cacheService?.fetchFamily(recordName: quest.family.recordID.recordName)?.payoutDayEnum
            ?? .sunday
        let currentWeekStart = WeekMath.startOfWeek(for: Date(), payoutDay: assigneePayoutDay)
        guard WeekMath.dayBucket(for: quest.weekOf) == WeekMath.dayBucket(for: currentWeekStart) else {
            return false
        }
        return cacheService?.fetchQuestTemplates(family: quest.family.recordID.recordName)
            .contains { $0.recordName == quest.template.recordID.recordName && $0.isActive } ?? false
    }
}

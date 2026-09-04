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

    var cacheService: CacheService
    var treasuryService: TreasuryService?
    var achievementService: AchievementService?
    /// Loot-drop reward surface for quest completions. Set by `AppDependencies`
    /// after `LootDropService` is constructed (it owns `GemService`).
    var lootDropService: LootDropService?
    var syncCoordinator: CKSyncEngineCoordinator

    var appState: AppState

    let toastManager: ToastManager?

    // WHY: expired-quest deactivation needs a complete paid-week set —
    // incomplete snapshot would mis-expire quests still owed payout; deferral keeps them active until next sync.
    private(set) var sweepDeferred: Bool = false
    var onSweepDeferred: ((Bool) -> Void)?

    private func setSweepDeferred(_ value: Bool) {
        guard sweepDeferred != value else { return }
        sweepDeferred = value
        onSweepDeferred?(value)
    }

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
         cacheService: CacheService,
         treasuryService: TreasuryService? = nil,
         toastManager: ToastManager? = nil,
         appState: AppState,
         syncCoordinator: CKSyncEngineCoordinator)
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

    private static let staticLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "QuestService")

    @_disfavoredOverload
    convenience init(
        cloudKit: any CloudKitServiceProtocol,
        xpService: XPService,
        notificationService: NotificationService? = nil,
        cacheService: CacheService? = nil,
        treasuryService: TreasuryService? = nil,
        toastManager: ToastManager? = nil,
        appState: AppState? = nil,
        syncCoordinator: CKSyncEngineCoordinator? = nil
    ) {
        let cache: CacheService
        if let cacheService {
            cache = cacheService
        } else {
            Self.staticLogger.warning("QuestService initialized without cacheService; using fallback in-memory cache.")
            cache = CacheService.inMemoryFallback(logger: Self.staticLogger)
        }
        let state = appState ?? AppState()
        let ck = cloudKit as? CloudKitService ?? CloudKitService()
        let delegate = CKSyncEngineDelegateHandler(
            backgroundCache: nil,
            conflictResolver: CKSyncConflictResolver(cacheService: cache, backgroundCache: nil, toastManager: toastManager, appState: state),
            cacheService: cache,
            appState: state
        )
        let coord = syncCoordinator ?? CKSyncEngineCoordinator(cloudKitService: ck, delegateHandler: delegate, appState: state)
        self.init(
            cloudKit: cloudKit,
            xpService: xpService,
            notificationService: notificationService,
            cacheService: cache,
            treasuryService: treasuryService,
            toastManager: toastManager,
            appState: state,
            syncCoordinator: coord
        )
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
        guard let acting = appState.currentProfile,
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

        let sanitizedDays = schedule.requiresSpecificDays ? specificDays : []
        // WHY: day checklist splits reward per day, so target tracks day count for prorated credit.
        let resolvedTarget = schedule.requiresSpecificDays && !sanitizedDays.isEmpty ? sanitizedDays.count : max(1, targetCount)

        let template = QuestTemplate(
            name: name,
            description: description,
            defaultGold: defaultGold,
            xpReward: xpReward,
            scheduleType: schedule,
            specificDays: sanitizedDays,
            targetCount: resolvedTarget,
            isAllOrNothing: isAllOrNothing,
            approvalMode: approvalMode,
            createdBy: CKRecord.Reference(recordID: createdBy.id, action: .none),
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: CKRecord.ID(recordName: UUID().uuidString, zoneID: family.id.zoneID)
        )

        await cacheService.upsertQuestTemplate(template)
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(syncCoordinator, id: template.id, appState: appState, logger: logger, context: "QuestService.createTemplate")
        return template
    }

    @discardableResult
    func updateTemplate(_ template: QuestTemplate) async throws -> QuestTemplate {
        guard let acting = appState.currentProfile,
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

        var normalized = template
        // WHY: day checklist splits reward per day, so target tracks day count for prorated credit.
        if normalized.scheduleType.requiresSpecificDays {
            normalized.targetCount = normalized.specificDays.isEmpty ? max(1, normalized.targetCount) : normalized.specificDays.count
        } else {
            normalized.specificDays = []
            normalized.targetCount = max(1, normalized.targetCount)
        }

        await cacheService.upsertQuestTemplate(normalized)
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(syncCoordinator, id: normalized.id, appState: appState, logger: logger, context: "QuestService.updateTemplate")
        return normalized
    }

    @discardableResult
    func deactivateTemplate(_ template: QuestTemplate) async throws -> QuestTemplate {
        guard let acting = appState.currentProfile,
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

        await cacheService.upsertQuestTemplate(deactivated)
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(syncCoordinator, id: deactivated.id, appState: appState, logger: logger, context: "QuestService.deactivateTemplate")
        return deactivated
    }

    /// Cache-first read. Background refresh handled by CKSyncEngine.
    func fetchTemplates(family: Family) async throws -> [QuestTemplate] {
        try await CacheFirst.cacheFirst(
            type: .questTemplate,
            family: family,
            cacheService: cacheService,
            appState: appState,
            fetchCache: { [cacheService] familyName in
                cacheService.fetchQuestTemplates(family: familyName)
            },
            map: { [family] cache in
                cache.toQuestTemplate(zoneID: family.id.zoneID)
            },
            query: { [cloudKit, family] in
                let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
                let predicate = NSPredicate(format: "family == %@", familyRef)
                return try await cloudKit.query(QuestTemplate.self, predicate: predicate, in: family.id.zoneID)
            },
            hydrate: { [syncCoordinator, appState, family] models in
                await syncCoordinator.delegateHandler.hydrateFromQuery(
                    models: models,
                    databaseScope: appState.activeDatabaseScope,
                    zoneID: family.id.zoneID
                )
            },
            sortedBy: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        )
    }

    /// Cache-first template fetch with server hydration fallback for local reads.
    func fetchTemplateCached(id: String, familyRecordName: String) async throws -> QuestTemplate? {
        guard let zoneID = appState.familyZoneID else { return nil }
        return try await fetchTemplateCached(id: CKRecord.ID(recordName: id, zoneID: zoneID), familyRecordName: familyRecordName)
    }

    func fetchTemplateCached(id: CKRecord.ID, familyRecordName: String) async throws -> QuestTemplate? {
        if let cached = cacheService.fetchQuestTemplate(recordName: id.recordName, family: familyRecordName) {
            return cached.toQuestTemplate(zoneID: id.zoneID)
        }

        let template = try await cloudKit.fetch(QuestTemplate.self, id: id)
        await syncCoordinator.delegateHandler.hydrateFromQuery(
            models: [template],
            databaseScope: appState.activeDatabaseScope,
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
        guard let acting = appState.currentProfile,
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

        let payoutDay = PayoutDayResolver.resolved(for: assignee, family: family)
        let normalizedWeek = WeekMath.startOfWeek(for: weekOf, payoutDay: payoutDay)
        let questName = nameOverride.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            ?? template.name
        // WHY: day checklist splits reward per day, so target tracks day count for prorated credit.
        let resolvedQuestTarget = template.scheduleType.requiresSpecificDays && !template.specificDays.isEmpty
            ? template.specificDays.count
            : max(1, template.targetCount)

        let quest = Quest(
            template: CKRecord.Reference(recordID: template.id, action: .none),
            assignee: CKRecord.Reference(recordID: assignee.id, action: .none),
            goldReward: goldOverride ?? template.defaultGold,
            xpReward: xpOverride ?? template.xpReward,
            scheduleType: template.scheduleType,
            targetCount: resolvedQuestTarget,
            isAllOrNothing: isAllOrNothingOverride ?? template.isAllOrNothing,
            approvalMode: approvalOverride ?? template.approvalMode,
            weekOf: normalizedWeek,
            createdBy: CKRecord.Reference(recordID: createdBy.id, action: .none),
            family: CKRecord.Reference(recordID: family.id, action: .none),
            name: questName,
            descriptionText: template.description,
            id: CKRecord.ID(recordName: UUID().uuidString, zoneID: family.id.zoneID)
        )

        await cacheService.upsertQuest(quest)
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(syncCoordinator, id: quest.id, appState: appState, logger: logger, context: "QuestService.assignQuest")
        sendAssignmentNotification(to: assignee, questName: questName)
        return quest
    }

    @discardableResult
    func updateQuest(_ quest: Quest, newAssigneeRecordName: String? = nil) async throws -> Quest {
        guard let acting = appState.currentProfile,
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
        // WHY: day checklist splits reward per day, so target tracks day count for prorated credit.
        if updatedQuest.scheduleType.requiresSpecificDays {
            let templateDays = cacheService.fetchQuestTemplate(
                recordName: updatedQuest.template.recordID.recordName,
                family: updatedQuest.family.recordID.recordName
            )?.specificDays ?? []
            updatedQuest.targetCount = templateDays.isEmpty ? max(1, updatedQuest.targetCount) : templateDays.count
        } else {
            updatedQuest.targetCount = max(1, updatedQuest.targetCount)
        }

        await cacheService.upsertQuest(updatedQuest)
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(syncCoordinator, id: updatedQuest.id, appState: appState, logger: logger, context: "QuestService.updateQuest")
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
        guard let acting = appState.currentProfile,
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

        let sanitizedQuickDays = scheduleType.requiresSpecificDays ? specificDays : []
        // WHY: day checklist splits reward per day, so target tracks day count for prorated credit.
        let resolvedQuickTarget = scheduleType.requiresSpecificDays && !sanitizedQuickDays.isEmpty
            ? sanitizedQuickDays.count
            : max(1, targetCount)

        let adhocTemplate = QuestTemplate(
            name: name,
            description: description,
            defaultGold: goldReward,
            xpReward: xpReward,
            scheduleType: scheduleType,
            specificDays: sanitizedQuickDays,
            targetCount: resolvedQuickTarget,
            isAllOrNothing: isAllOrNothing,
            approvalMode: approvalMode,
            createdBy: CKRecord.Reference(recordID: createdBy.id, action: .none),
            family: CKRecord.Reference(recordID: family.id, action: .none),
            isActive: false,
            id: CKRecord.ID(recordName: UUID().uuidString, zoneID: family.id.zoneID)
        )

        await cacheService.upsertQuestTemplate(adhocTemplate)
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(
            syncCoordinator,
            id: adhocTemplate.id,
            appState: appState,
            logger: logger,
            context: "QuestService.assignQuickQuest.template"
        )

        let payoutDay = PayoutDayResolver.resolved(for: assignee, family: family)
        let normalizedWeek = WeekMath.startOfWeek(for: weekOf, payoutDay: payoutDay)

        let quest = Quest(
            template: CKRecord.Reference(recordID: adhocTemplate.id, action: .none),
            assignee: CKRecord.Reference(recordID: assignee.id, action: .none),
            goldReward: goldReward,
            xpReward: xpReward,
            scheduleType: scheduleType,
            targetCount: resolvedQuickTarget,
            isAllOrNothing: isAllOrNothing,
            approvalMode: approvalMode,
            weekOf: normalizedWeek,
            createdBy: CKRecord.Reference(recordID: createdBy.id, action: .none),
            family: CKRecord.Reference(recordID: family.id, action: .none),
            name: name,
            descriptionText: description,
            id: CKRecord.ID(recordName: UUID().uuidString, zoneID: family.id.zoneID)
        )

        await cacheService.upsertQuest(quest)
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(syncCoordinator, id: quest.id, appState: appState, logger: logger, context: "QuestService.assignQuickQuest")
        sendAssignmentNotification(to: assignee, questName: name)
        return quest
    }

    func unassignQuest(_ quest: Quest) async throws {
        guard let acting = appState.currentProfile,
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

        let shouldRetainTombstone = acting.role.isParent && isCarryForwardSuppressible(quest)
        if shouldRetainTombstone {
            var tombstone = quest
            tombstone.active = false
            await cacheService.upsertQuest(tombstone)
            ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(syncCoordinator, id: tombstone.id, appState: appState, logger: logger, context: "QuestService.unassignQuest")
            return
        }

        let isOwnerForIdentity = ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState)
        let identity = ScopedRecordIdentity(
            databaseScope: DatabaseScopeResolver.scope(isOwner: isOwnerForIdentity),
            zoneID: quest.id.zoneID,
            recordID: quest.id,
            familyRecordName: quest.family.recordID.recordName
        )
        // Pre-delete identity captured before invalidate; RecordBridge returns nil
        // for the dangling record and coordinator drain handles the tombstone.
        await cacheService.invalidate(identity: identity, type: .quest, expectedActiveZone: appState.familyZoneID)
        ActiveFamilyScopeGuard.enqueueDeleteWithCorrectedOwner(syncCoordinator, id: quest.id, appState: appState, logger: logger, context: "QuestService.unassignQuest")
    }

    /// Cache-first read. On cold cache miss, falls back to a single synchronous
    /// CloudKit query to hydrate. Background ongoing refresh handled by
    /// CKSyncEngine via push notifications.
    /// WHY: when cache is not authoritative and CloudKit fails, returns stale cache without invalidating freshness — retry occurs on next reconcileCacheFromCloudKit.
    func fetchActiveQuests(profile: Profile, weekOf: Date) async throws -> [Quest] {
        let range = WeekMath.range(for: weekOf, payoutDay: effectivePayoutDay(for: profile)).range
        let family = Family(
            name: "",
            createdBy: profile.family.recordID,
            id: CKRecord.ID(recordName: profile.family.recordID.recordName, zoneID: profile.id.zoneID)
        )
        return try await CacheFirst.cacheFirst(
            type: .quest,
            family: family,
            cacheService: cacheService,
            appState: appState,
            fetchCache: { [cacheService, profile, range] familyName in
                cacheService.fetchQuests(family: familyName)
                    .filter { $0.assigneeRecordName == profile.id.recordName && $0.isActive && range.contains($0.weekOf) }
            },
            map: { [profile] cache in
                cache.toQuest(zoneID: profile.id.zoneID)
            },
            query: { [cloudKit, profile] in
                let assigneeRef = CKRecord.Reference(recordID: profile.id, action: .none)
                let predicate = NSPredicate(format: "assignee == %@", assigneeRef)
                let all = try await cloudKit.query(Quest.self, predicate: predicate, in: profile.id.zoneID)
                var stamped: [Quest] = []
                stamped.reserveCapacity(all.count)
                for quest in all {
                    if quest.name == nil {
                        do {
                            let template = try await cloudKit.fetch(QuestTemplate.self, id: quest.template.recordID)
                            var updated = quest
                            updated.name = template.name
                            stamped.append(updated)
                        } catch {
                            stamped.append(quest)
                        }
                    } else {
                        stamped.append(quest)
                    }
                }
                return stamped.filter { $0.active && range.contains($0.weekOf) }
            },
            hydrate: { [syncCoordinator, appState, profile] models in
                await syncCoordinator.delegateHandler.hydrateFromQuery(
                    models: models,
                    databaseScope: appState.activeDatabaseScope,
                    zoneID: profile.id.zoneID
                )
            },
            sortedBy: { $0.template.recordID.recordName < $1.template.recordID.recordName }
        )
    }

    /// Cache-first read. On cold cache miss, falls back to a single synchronous
    /// CloudKit query to hydrate. Background ongoing refresh handled by
    /// CKSyncEngine via push notifications.
    func fetchQuestsForFamilyWeek(family: Family, weekOf: Date) async throws -> [Quest] {
        let range = WeekMath.range(for: weekOf, payoutDay: family.payoutDay).range
        return try await CacheFirst.cacheFirst(
            type: .quest,
            family: family,
            cacheService: cacheService,
            appState: appState,
            fetchCache: { [cacheService, range] familyName in
                cacheService.fetchQuests(family: familyName)
                    .filter { $0.isActive && range.contains($0.weekOf) }
            },
            map: { [family] cache in
                cache.toQuest(zoneID: family.id.zoneID)
            },
            query: { [cloudKit, range] in
                let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
                let predicate = NSPredicate(format: "family == %@", familyRef)
                let all = try await cloudKit.query(Quest.self, predicate: predicate, in: family.id.zoneID)
                var stamped: [Quest] = []
                stamped.reserveCapacity(all.count)
                for quest in all where quest.name == nil {
                    do {
                        let template = try await cloudKit.fetch(QuestTemplate.self, id: quest.template.recordID)
                        var updated = quest
                        updated.name = template.name
                        stamped.append(updated)
                    } catch {
                        stamped.append(quest)
                    }
                }
                for quest in all where quest.name != nil {
                    stamped.append(quest)
                }
                return stamped.filter { $0.active && range.contains($0.weekOf) }
            },
            hydrate: { [syncCoordinator, appState, family] models in
                await syncCoordinator.delegateHandler.hydrateFromQuery(
                    models: models,
                    databaseScope: appState.activeDatabaseScope,
                    zoneID: family.id.zoneID
                )
            },
            sortedBy: { $0.assignee.recordID.recordName < $1.assignee.recordID.recordName }
        )
    }

    /// Deactivates uncompleted quests from past weeks on rollover.
    @discardableResult
    func sweepExpiredQuests(family: Family, currentWeekOf: Date) async throws -> [Quest] {
        guard let acting = appState.currentProfile, acting.role.isParent else {
            throw FamilyServiceError.unauthorized
        }
        try ActiveFamilyScopeGuard.requireActiveFamilyScope(
            family: family,
            cloudKit: cloudKit,
            appState: appState
        )

        let familyName = family.id.recordName
        let cache = cacheService

        // WHY: Multi-type sweep with bespoke deferral and payout-week aggregation — intentionally inline, not a single-type CacheFirst flow.
        // Query allowance periods to identify weeks whose payouts have been completed (.paid)
        let cachedAllowance = cache.fetchAllowancePeriods(family: familyName)
        let allowanceScope: CKDatabase.Scope = appState.activeDatabaseScope
        let allowancePeriods: [AllowancePeriod]
        if cache.isCacheAuthoritative(familyRecordName: familyName, type: .allowancePeriod, scope: allowanceScope) {
            allowancePeriods = cachedAllowance.map { $0.toAllowancePeriod(zoneID: family.id.zoneID) }
            // Cache authoritative — paid-week set is complete; clear any prior deferral.
            setSweepDeferred(false)
        } else {
            let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
            let predicate = NSPredicate(format: "family == %@", familyRef)
            do {
                allowancePeriods = try await cloudKit.query(AllowancePeriod.self, predicate: predicate, in: family.id.zoneID)
                setSweepDeferred(false)
            } catch {
                logger.warning("Failed to fetch allowance periods from CloudKit", family: familyName, zone: family.id.zoneID.zoneName)
                // WHY: incomplete paid-week set would mis-expire quests still owed payout — defer expiry until next authoritative sync.
                setSweepDeferred(true)
                toastManager?.show(message: "Quest expiry check deferred — will retry next sync", type: .warning)
                // Keep cache stale — do NOT invalidate freshness; next reconcileCacheFromCloudKit retries automatically.
                return []
            }
        }

        // Preserves raw weekOf timestamps matching the profile's normalized cycle.
        let paidWeeks = Set(allowancePeriods.filter { $0.status == .paid }.map(\.weekOf))

        let allQuests: [Quest] = try await CacheFirst.cacheFirst(
            type: .quest,
            family: family,
            cacheService: cacheService,
            appState: appState,
            fetchCache: { [cacheService] familyName in
                cacheService.fetchQuests(family: familyName).filter(\.isActive)
            },
            map: { [family] cache in
                cache.toQuest(zoneID: family.id.zoneID)
            },
            query: { [cloudKit, family] in
                let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
                let predicate = NSPredicate(format: "family == %@", familyRef)
                return try await cloudKit.query(Quest.self, predicate: predicate, in: family.id.zoneID).filter(\.active)
            },
            hydrate: { [syncCoordinator, appState, family] models in
                await syncCoordinator.delegateHandler.hydrateFromQuery(
                    models: models,
                    databaseScope: appState.activeDatabaseScope,
                    zoneID: family.id.zoneID
                )
            }
        )

        var deactivated: [Quest] = []
        for var quest in allQuests {
            let profileCache = cacheService.fetchProfile(recordName: quest.assignee.recordID.recordName, family: quest.family.recordID.recordName)
            let effectivePayoutDay = PayoutDayResolver.resolved(for: profileCache, family: family)
            let questWeek = WeekMath.startOfWeek(for: quest.weekOf, payoutDay: effectivePayoutDay)
            let currentWeekForAssignee = WeekMath.startOfWeek(for: currentWeekOf, payoutDay: effectivePayoutDay)
            if questWeek < currentWeekForAssignee, paidWeeks.contains(questWeek) {
                quest.active = false
                await cacheService.upsertQuest(quest)
                ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(syncCoordinator, id: quest.id, appState: appState, logger: logger, context: "QuestService.sweepExpiredQuests")
                deactivated.append(quest)
            }
        }
        return deactivated
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

    /// Resolves effective payout day (profile override -> family config -> Sunday default).
    func effectivePayoutDay(for profile: Profile) -> PayoutDay {
        let familyCache = cacheService.fetchFamily(recordName: profile.family.recordID.recordName)
        return PayoutDayResolver.resolved(for: profile, family: familyCache)
    }

    /// Checks if quest matches template carry-forward state without local modifications.
    private func isCarryForwardSuppressible(_ quest: Quest) -> Bool {
        let profileCache = cacheService.fetchProfile(recordName: quest.assignee.recordID.recordName, family: quest.family.recordID.recordName)
        let familyCache = cacheService.fetchFamily(recordName: quest.family.recordID.recordName)
        let assigneePayoutDay = PayoutDayResolver.resolved(for: profileCache, family: familyCache)
        let currentWeekStart = WeekMath.startOfWeek(for: Date(), payoutDay: assigneePayoutDay)
        guard WeekMath.dayBucket(for: quest.weekOf) == WeekMath.dayBucket(for: currentWeekStart) else {
            return false
        }
        return cacheService.fetchQuestTemplates(family: quest.family.recordID.recordName)
            .contains { $0.recordName == quest.template.recordID.recordName && $0.isActive }
    }
}

private extension Logger {
    func warning(_ message: String, family: String, zone: String) {
        log(level: .default, "\(message, privacy: .public) family=\(family, privacy: .private) zone=\(zone, privacy: .private)")
    }

    func info(_ message: String, family: String, zone: String) {
        log(level: .info, "\(message, privacy: .public) family=\(family, privacy: .private) zone=\(zone, privacy: .private)")
    }

    func error(_ message: String, family: String, zone: String) {
        log(level: .error, "\(message, privacy: .public) family=\(family, privacy: .private) zone=\(zone, privacy: .private)")
    }
}

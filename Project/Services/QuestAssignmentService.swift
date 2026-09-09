//
//  QuestAssignmentService.swift
//  LootList
//
//  Created by Ben Mackin on 9/8/26.
//

import CloudKit
import Foundation
import os

/// Assignment lifecycle for quests: assign, update, unassign, week-scoped
/// reads, and expiry sweep. Hero Board claim and revoke stay in
/// `HeroBoardService` as the single source so the server-wins race cannot
/// drift between two writers.
@MainActor
@Observable
final class QuestAssignmentService {
    private let logger = Logger(category: "QuestAssignmentService")
    let cloudKit: any CloudKitServiceProtocol
    var cacheService: CacheService
    var appState: AppState
    var syncCoordinator: any SyncEnqueuing
    let notificationService: NotificationService?
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

    init(
        cloudKit: any CloudKitServiceProtocol,
        cacheService: CacheService,
        appState: AppState,
        syncCoordinator: any SyncEnqueuing,
        notificationService: NotificationService? = nil,
        toastManager: ToastManager? = nil
    ) {
        self.cloudKit = cloudKit
        self.cacheService = cacheService
        self.appState = appState
        self.syncCoordinator = syncCoordinator
        self.notificationService = notificationService
        self.toastManager = toastManager
    }

    private static let staticLogger = Logger(category: "QuestAssignmentService")

    @_disfavoredOverload
    convenience init(
        cloudKit: any CloudKitServiceProtocol,
        cacheService: CacheService? = nil,
        appState: AppState? = nil,
        syncCoordinator: (any SyncEnqueuing)? = nil,
        notificationService: NotificationService? = nil,
        toastManager: ToastManager? = nil
    ) {
        let cache: CacheService
        if let cacheService {
            cache = cacheService
        } else {
            Self.staticLogger.warning("QuestAssignmentService initialized without cacheService; using fallback in-memory cache.")
            cache = CacheService.inMemoryFallback(logger: Self.staticLogger)
        }
        let state = appState ?? AppState()
        // WHY single shared engine: ephemeral delegate+coordinator diverge from ingest.
        let sharedCoord: (any SyncEnqueuing)? = AppDependencies.shared?.syncCoordinator
        if let coord: any SyncEnqueuing = syncCoordinator ?? sharedCoord {
            self.init(
                cloudKit: cloudKit,
                cacheService: cache,
                appState: state,
                syncCoordinator: coord,
                notificationService: notificationService,
                toastManager: toastManager
            )
        } else {
            #if DEBUG
                if TestEnvironment.isRunningUnitOrUITests {
                    Self.staticLogger.warning("QuestAssignmentService initialized without syncCoordinator; using test Noop seam.")
                } else {
                    Self.staticLogger.error("QuestAssignmentService initialized without syncCoordinator and no shared coordinator; falling back to Noop seam.")
                }
                self.init(
                    cloudKit: cloudKit,
                    cacheService: cache,
                    appState: state,
                    syncCoordinator: NoopSyncEnqueuing(),
                    notificationService: notificationService,
                    toastManager: toastManager
                )
            #else
                preconditionFailure("QuestAssignmentService requires a sync coordinator in production")
            #endif
        }
    }

    @discardableResult
    func assignQuest(template: QuestTemplate,
                     assignee: Profile,
                     goldOverride: Int64? = nil,
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
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(syncCoordinator, id: quest.id, appState: appState, logger: logger, context: "QuestAssignmentService.assignQuest")
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
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(syncCoordinator, id: updatedQuest.id, appState: appState, logger: logger, context: "QuestAssignmentService.updateQuest")
        return updatedQuest
    }

    @discardableResult
    func assignQuickQuest(name: String,
                          description: String = "",
                          assignee: Profile,
                          goldReward: Int64,
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
            context: "QuestAssignmentService.assignQuickQuest.template"
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
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(syncCoordinator, id: quest.id, appState: appState, logger: logger, context: "QuestAssignmentService.assignQuickQuest")
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
            ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(syncCoordinator, id: tombstone.id, appState: appState, logger: logger, context: "QuestAssignmentService.unassignQuest")
            return
        }

        // WHY single step: tombstone capture survives row removal across the await.
        await ActiveFamilyScopeGuard.deleteAndEnqueue(
            cacheService: cacheService,
            target: .init(recordID: quest.id, familyRecordName: quest.family.recordID.recordName),
            type: .quest,
            deleteContext: .init(
                coordinator: syncCoordinator,
                appState: appState,
                logger: logger,
                context: "QuestAssignmentService.unassignQuest",
                expectedActiveZone: appState.familyZoneID
            )
        )
    }

    /// Cache-first read. On cold cache miss, falls back to a single synchronous
    /// CloudKit query to hydrate. Background ongoing refresh handled by
    /// CKSyncEngine via push notifications.
    /// WHY: when cache is not authoritative and CloudKit fails, returns stale cache without invalidating freshness — retry occurs on next reconcileCacheFromCloudKit.
    func fetchActiveQuests(profile: Profile, weekOf: Date) async throws -> [Quest] {
        let range = WeekMath.range(for: weekOf, payoutDay: effectivePayoutDay(for: profile)).range
        let family = Family(
            name: "",
            creatorUserRecordName: nil,
            id: CKRecord.ID(recordName: profile.family.recordID.recordName, zoneID: profile.id.zoneID)
        )
        // WHY fail-closed: unknown scope serves cache only without guessing a database.
        guard let scope = DatabaseScopeResolver.resolvedScope(appState: appState) else {
            return cacheService.fetchQuests(family: family.id.recordName)
                .filter { $0.assigneeRecordName == profile.id.recordName && $0.isActive && range.contains($0.weekOf) }
                .map { [profile] cache in cache.toQuest(zoneID: profile.id.zoneID) }
                .sorted { $0.template.recordID.recordName < $1.template.recordID.recordName }
        }
        return try await CacheFirst.cacheFirst(
            type: .quest,
            family: family,
            cacheService: cacheService,
            scope: scope,
            operations: .init(
                fetchCache: { [cacheService, profile, range] familyName in
                    cacheService.fetchQuests(family: familyName)
                        .filter { $0.assigneeRecordName == profile.id.recordName && $0.isActive && range.contains($0.weekOf) }
                },
                map: { [profile] cache in
                    cache.toQuest(zoneID: profile.id.zoneID)
                },
                query: { [cloudKit, profile, logger] in
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
                                logger.warning("Failed to fetch template for quest \(quest.id.recordName, privacy: .private): \(error, privacy: .private)")
                                stamped.append(quest)
                            }
                        } else {
                            stamped.append(quest)
                        }
                    }
                    return stamped.filter { $0.active && range.contains($0.weekOf) }
                },
                hydrate: { [syncCoordinator, scope, profile] models in
                    await syncCoordinator.hydrationHandler.hydrateFromQuery(
                        models: models,
                        databaseScope: scope,
                        zoneID: profile.id.zoneID
                    )
                },
                sortedBy: { $0.template.recordID.recordName < $1.template.recordID.recordName }
            )
        )
    }

    /// Cache-first read. On cold cache miss, falls back to a single synchronous
    /// CloudKit query to hydrate. Background ongoing refresh handled by
    /// CKSyncEngine via push notifications.
    func fetchQuestsForFamilyWeek(family: Family, weekOf: Date) async throws -> [Quest] {
        let range = WeekMath.range(for: weekOf, payoutDay: family.payoutDay).range
        // WHY fail-closed: unknown scope serves cache only without guessing a database.
        guard let scope = DatabaseScopeResolver.resolvedScope(appState: appState) else {
            return cacheService.fetchQuests(family: family.id.recordName)
                .filter { $0.isActive && range.contains($0.weekOf) }
                .map { [family] cache in cache.toQuest(zoneID: family.id.zoneID) }
                .sorted { $0.assignee.recordID.recordName < $1.assignee.recordID.recordName }
        }
        return try await CacheFirst.cacheFirst(
            type: .quest,
            family: family,
            cacheService: cacheService,
            scope: scope,
            operations: .init(
                fetchCache: { [cacheService, range] familyName in
                    cacheService.fetchQuests(family: familyName)
                        .filter { $0.isActive && range.contains($0.weekOf) }
                },
                map: { [family] cache in
                    cache.toQuest(zoneID: family.id.zoneID)
                },
                query: { [cloudKit, range, logger] in
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
                            logger.warning("Failed to fetch template for quest \(quest.id.recordName, privacy: .private): \(error, privacy: .private)")
                            stamped.append(quest)
                        }
                    }
                    for quest in all where quest.name != nil {
                        stamped.append(quest)
                    }
                    return stamped.filter { $0.active && range.contains($0.weekOf) }
                },
                hydrate: { [syncCoordinator, scope, family] models in
                    await syncCoordinator.hydrationHandler.hydrateFromQuery(
                        models: models,
                        databaseScope: scope,
                        zoneID: family.id.zoneID
                    )
                },
                sortedBy: { $0.assignee.recordID.recordName < $1.assignee.recordID.recordName }
            )
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
        // WHY fail-closed: unknown scope defers expiry instead of guessing a database.
        guard let allowanceScope = DatabaseScopeResolver.resolvedScope(appState: appState) else {
            setSweepDeferred(true)
            return []
        }
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

        let scope: CKDatabase.Scope = allowanceScope
        let allQuests: [Quest] = try await CacheFirst.cacheFirst(
            type: .quest,
            family: family,
            cacheService: cacheService,
            scope: scope,
            operations: .init(
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
                hydrate: { [syncCoordinator, scope, family] models in
                    await syncCoordinator.hydrationHandler.hydrateFromQuery(
                        models: models,
                        databaseScope: scope,
                        zoneID: family.id.zoneID
                    )
                }
            )
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
                ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(
                    syncCoordinator,
                    id: quest.id,
                    appState: appState,
                    logger: logger,
                    context: "QuestAssignmentService.sweepExpiredQuests"
                )
                deactivated.append(quest)
            }
        }
        return deactivated
    }

    func sendAssignmentNotification(to assignee: Profile, questName: String) {
        guard let notificationService else { return }
        Task { [logger, notificationService, assignee, questName] in
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

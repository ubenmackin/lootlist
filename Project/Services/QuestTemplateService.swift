//
//  QuestTemplateService.swift
//  LootList
//
//  Created by Ben Mackin on 9/8/26.
//

import CloudKit
import Foundation
import os

/// Template CRUD for quests. Owns `QuestTemplate` lifecycle; assignment and
/// completion flows resolve templates cache-first via this service's rows.
@MainActor
@Observable
final class QuestTemplateService {
    private let logger = Logger(category: "QuestTemplateService")
    let cloudKit: any CloudKitServiceProtocol
    var cacheService: CacheService
    var appState: AppState
    var syncCoordinator: any SyncEnqueuing

    init(
        cloudKit: any CloudKitServiceProtocol,
        cacheService: CacheService,
        appState: AppState,
        syncCoordinator: any SyncEnqueuing
    ) {
        self.cloudKit = cloudKit
        self.cacheService = cacheService
        self.appState = appState
        self.syncCoordinator = syncCoordinator
    }

    private static let staticLogger = Logger(category: "QuestTemplateService")

    @_disfavoredOverload
    convenience init(
        cloudKit: any CloudKitServiceProtocol,
        cacheService: CacheService? = nil,
        appState: AppState? = nil,
        syncCoordinator: (any SyncEnqueuing)? = nil
    ) {
        let cache: CacheService
        if let cacheService {
            cache = cacheService
        } else {
            Self.staticLogger.warning("QuestTemplateService initialized without cacheService; using fallback in-memory cache.")
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
                syncCoordinator: coord
            )
        } else {
            #if DEBUG
                if TestEnvironment.isRunningUnitOrUITests {
                    Self.staticLogger.warning("QuestTemplateService initialized without syncCoordinator; using test Noop seam.")
                } else {
                    Self.staticLogger.error("QuestTemplateService initialized without syncCoordinator and no shared coordinator; falling back to Noop seam.")
                }
                self.init(
                    cloudKit: cloudKit,
                    cacheService: cache,
                    appState: state,
                    syncCoordinator: NoopSyncEnqueuing()
                )
            #else
                preconditionFailure("QuestTemplateService requires a sync coordinator in production")
            #endif
        }
    }

    // MARK: - Quest Templates

    @discardableResult
    func createTemplate(name: String,
                        description: String = "",
                        defaultGold: Int64,
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
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(syncCoordinator, id: template.id, appState: appState, logger: logger, context: "QuestTemplateService.createTemplate")
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
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(syncCoordinator, id: normalized.id, appState: appState, logger: logger, context: "QuestTemplateService.updateTemplate")
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
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(
            syncCoordinator,
            id: deactivated.id,
            appState: appState,
            logger: logger,
            context: "QuestTemplateService.deactivateTemplate"
        )
        return deactivated
    }

    /// Cache-first read. Background refresh handled by CKSyncEngine.
    func fetchTemplates(family: Family) async throws -> [QuestTemplate] {
        // WHY fail-closed: unknown scope serves cache only without guessing a database.
        guard let scope = DatabaseScopeResolver.resolvedScope(appState: appState) else {
            return cacheService.fetchQuestTemplates(family: family.id.recordName)
                .map { [family] cache in cache.toQuestTemplate(zoneID: family.id.zoneID) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        return try await CacheFirst.cacheFirst(
            type: .questTemplate,
            family: family,
            cacheService: cacheService,
            scope: scope,
            operations: .init(
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
                hydrate: { [syncCoordinator, scope, family] models in
                    await syncCoordinator.hydrationHandler.hydrateFromQuery(
                        models: models,
                        databaseScope: scope,
                        zoneID: family.id.zoneID
                    )
                },
                sortedBy: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            )
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

        // WHY fail-closed: unknown scope drops hydrate instead of guessing a database.
        guard let scope = DatabaseScopeResolver.resolvedScope(appState: appState) else { return nil }
        let template = try await cloudKit.fetch(QuestTemplate.self, id: id)
        await syncCoordinator.hydrationHandler.hydrateFromQuery(
            models: [template],
            databaseScope: scope,
            zoneID: id.zoneID
        )
        return template
    }
}

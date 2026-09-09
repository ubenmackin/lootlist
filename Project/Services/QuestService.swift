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

/// Thin facade over the focused quest services. New code should depend on
/// `QuestTemplateService`, `QuestAssignmentService`, `QuestCompletionService`,
/// or `QuestRewardService` directly; this type forwards every legacy entry
/// point so existing call sites keep compiling without behavior change.
@MainActor
@Observable
final class QuestService {
    private let logger = Logger(category: "QuestService")
    let cloudKit: any CloudKitServiceProtocol

    let xpService: XPService
    let notificationService: NotificationService?

    var cacheService: CacheService {
        didSet {
            templateService.cacheService = cacheService
            assignmentService.cacheService = cacheService
            rewardService.cacheService = cacheService
            completionService.cacheService = cacheService
        }
    }

    var treasuryService: TreasuryService? {
        didSet { rewardService.treasuryService = treasuryService }
    }

    var achievementService: AchievementService? {
        didSet { completionService.achievementService = achievementService }
    }

    /// Loot-drop reward surface for quest completions. Set by `AppDependencies`
    /// after `LootDropService` is constructed (it owns `GemService`).
    var lootDropService: LootDropService? {
        didSet { rewardService.lootDropService = lootDropService }
    }

    var syncCoordinator: any SyncEnqueuing {
        didSet {
            templateService.syncCoordinator = syncCoordinator
            assignmentService.syncCoordinator = syncCoordinator
            rewardService.syncCoordinator = syncCoordinator
            completionService.syncCoordinator = syncCoordinator
        }
    }

    var appState: AppState {
        didSet {
            templateService.appState = appState
            assignmentService.appState = appState
            rewardService.appState = appState
            completionService.appState = appState
        }
    }

    let toastManager: ToastManager?

    let templateService: QuestTemplateService
    let assignmentService: QuestAssignmentService
    let rewardService: QuestRewardService
    let completionService: QuestCompletionService

    // WHY: expired-quest deactivation needs a complete paid-week set —
    // incomplete snapshot would mis-expire quests still owed payout; deferral keeps them active until next sync.
    var sweepDeferred: Bool {
        assignmentService.sweepDeferred
    }

    var onSweepDeferred: ((Bool) -> Void)? {
        get { assignmentService.onSweepDeferred }
        set { assignmentService.onSweepDeferred = newValue }
    }

    var cloudKitReference: any CloudKitServiceProtocol {
        cloudKit
    }

    /// Guards against double-submit completions while a save is pending.
    let inFlightCompletions: Mutex<Set<String>>

    /// Record names of quest completions with a verify/reject action currently in flight.
    let inFlightVerifications: Mutex<Set<String>>

    /// Record names of quest completions with a withdrawal action currently in flight.
    let inFlightWithdrawals: Mutex<Set<String>>

    init(cloudKit: any CloudKitServiceProtocol,
         xpService: XPService,
         notificationService: NotificationService? = nil,
         cacheService: CacheService,
         treasuryService: TreasuryService? = nil,
         toastManager: ToastManager? = nil,
         appState: AppState,
         syncCoordinator: any SyncEnqueuing)
    {
        self.cloudKit = cloudKit
        self.xpService = xpService
        self.notificationService = notificationService
        self.cacheService = cacheService
        self.treasuryService = treasuryService
        self.appState = appState
        self.toastManager = toastManager
        self.syncCoordinator = syncCoordinator
        // WHY independent guards: Mutex is noncopyable so facade and completion service cannot share one instance.
        self.inFlightCompletions = Mutex<Set<String>>([])
        self.inFlightVerifications = Mutex<Set<String>>([])
        self.inFlightWithdrawals = Mutex<Set<String>>([])
        let template = QuestTemplateService(
            cloudKit: cloudKit,
            cacheService: cacheService,
            appState: appState,
            syncCoordinator: syncCoordinator
        )
        let assignment = QuestAssignmentService(
            cloudKit: cloudKit,
            cacheService: cacheService,
            appState: appState,
            syncCoordinator: syncCoordinator,
            notificationService: notificationService,
            toastManager: toastManager
        )
        let reward = QuestRewardService(
            cloudKit: cloudKit,
            cacheService: cacheService,
            appState: appState,
            syncCoordinator: syncCoordinator,
            xpService: xpService,
            treasuryService: treasuryService,
            toastManager: toastManager
        )
        let completion = QuestCompletionService(
            cloudKit: cloudKit,
            cacheService: cacheService,
            appState: appState,
            syncCoordinator: syncCoordinator,
            xpService: xpService,
            notificationService: notificationService,
            toastManager: toastManager,
            rewardService: reward
        )
        self.templateService = template
        self.assignmentService = assignment
        self.rewardService = reward
        self.completionService = completion
        self.rewardService.lootDropService = lootDropService
        self.completionService.achievementService = achievementService
    }

    private static let staticLogger = Logger(category: "QuestService")

    @_disfavoredOverload
    convenience init(
        cloudKit: any CloudKitServiceProtocol,
        xpService: XPService,
        notificationService: NotificationService? = nil,
        cacheService: CacheService? = nil,
        treasuryService: TreasuryService? = nil,
        toastManager: ToastManager? = nil,
        appState: AppState? = nil,
        syncCoordinator: (any SyncEnqueuing)? = nil
    ) {
        let cache: CacheService
        if let cacheService {
            cache = cacheService
        } else {
            Self.staticLogger.warning("QuestService initialized without cacheService; using fallback in-memory cache.")
            cache = CacheService.inMemoryFallback(logger: Self.staticLogger)
        }
        let state = appState ?? AppState()
        // WHY single shared engine: ephemeral delegate+coordinator diverge from ingest.
        let sharedCoord: (any SyncEnqueuing)? = AppDependencies.shared?.syncCoordinator
        if let coord: any SyncEnqueuing = syncCoordinator ?? sharedCoord {
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
        } else {
            #if DEBUG
                if TestEnvironment.isRunningUnitOrUITests {
                    Self.staticLogger.warning("QuestService initialized without syncCoordinator; using test Noop seam.")
                } else {
                    Self.staticLogger.error("QuestService initialized without syncCoordinator and no shared coordinator; falling back to Noop seam.")
                }
                self.init(
                    cloudKit: cloudKit,
                    xpService: xpService,
                    notificationService: notificationService,
                    cacheService: cache,
                    treasuryService: treasuryService,
                    toastManager: toastManager,
                    appState: state,
                    syncCoordinator: NoopSyncEnqueuing()
                )
            #else
                // WHY fail-closed: production without engine must not drop writes.
                preconditionFailure("QuestService requires a sync coordinator in production")
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
        try await templateService.createTemplate(
            name: name,
            description: description,
            defaultGold: defaultGold,
            xpReward: xpReward,
            schedule: schedule,
            specificDays: specificDays,
            targetCount: targetCount,
            isAllOrNothing: isAllOrNothing,
            approvalMode: approvalMode,
            createdBy: createdBy,
            family: family
        )
    }

    @discardableResult
    func updateTemplate(_ template: QuestTemplate) async throws -> QuestTemplate {
        try await templateService.updateTemplate(template)
    }

    @discardableResult
    func deactivateTemplate(_ template: QuestTemplate) async throws -> QuestTemplate {
        try await templateService.deactivateTemplate(template)
    }

    /// Cache-first read. Background refresh handled by CKSyncEngine.
    func fetchTemplates(family: Family) async throws -> [QuestTemplate] {
        try await templateService.fetchTemplates(family: family)
    }

    /// Cache-first template fetch with server hydration fallback for local reads.
    func fetchTemplateCached(id: String, familyRecordName: String) async throws -> QuestTemplate? {
        try await templateService.fetchTemplateCached(id: id, familyRecordName: familyRecordName)
    }

    func fetchTemplateCached(id: CKRecord.ID, familyRecordName: String) async throws -> QuestTemplate? {
        try await templateService.fetchTemplateCached(id: id, familyRecordName: familyRecordName)
    }

    // MARK: - Quest Assignment

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
        try await assignmentService.assignQuest(
            template: template,
            assignee: assignee,
            goldOverride: goldOverride,
            xpOverride: xpOverride,
            approvalOverride: approvalOverride,
            isAllOrNothingOverride: isAllOrNothingOverride,
            nameOverride: nameOverride,
            weekOf: weekOf,
            createdBy: createdBy,
            family: family
        )
    }

    @discardableResult
    func updateQuest(_ quest: Quest, newAssigneeRecordName: String? = nil) async throws -> Quest {
        try await assignmentService.updateQuest(quest, newAssigneeRecordName: newAssigneeRecordName)
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
        try await assignmentService.assignQuickQuest(
            name: name,
            description: description,
            assignee: assignee,
            goldReward: goldReward,
            xpReward: xpReward,
            scheduleType: scheduleType,
            specificDays: specificDays,
            targetCount: targetCount,
            isAllOrNothing: isAllOrNothing,
            approvalMode: approvalMode,
            weekOf: weekOf,
            createdBy: createdBy,
            family: family
        )
    }

    func unassignQuest(_ quest: Quest) async throws {
        try await assignmentService.unassignQuest(quest)
    }

    /// Cache-first read. On cold cache miss, falls back to a single synchronous
    /// CloudKit query to hydrate. Background ongoing refresh handled by
    /// CKSyncEngine via push notifications.
    /// WHY: when cache is not authoritative and CloudKit fails, returns stale cache without invalidating freshness — retry occurs on next reconcileCacheFromCloudKit.
    func fetchActiveQuests(profile: Profile, weekOf: Date) async throws -> [Quest] {
        try await assignmentService.fetchActiveQuests(profile: profile, weekOf: weekOf)
    }

    /// Cache-first read. On cold cache miss, falls back to a single synchronous
    /// CloudKit query to hydrate. Background ongoing refresh handled by
    /// CKSyncEngine via push notifications.
    func fetchQuestsForFamilyWeek(family: Family, weekOf: Date) async throws -> [Quest] {
        try await assignmentService.fetchQuestsForFamilyWeek(family: family, weekOf: weekOf)
    }

    /// Deactivates uncompleted quests from past weeks on rollover.
    @discardableResult
    func sweepExpiredQuests(family: Family, currentWeekOf: Date) async throws -> [Quest] {
        try await assignmentService.sweepExpiredQuests(family: family, currentWeekOf: currentWeekOf)
    }

    func sendAssignmentNotification(to assignee: Profile, questName: String) {
        assignmentService.sendAssignmentNotification(to: assignee, questName: questName)
    }

    /// Resolves effective payout day (profile override -> family config -> Sunday default).
    func effectivePayoutDay(for profile: Profile) -> PayoutDay {
        assignmentService.effectivePayoutDay(for: profile)
    }

    // MARK: - Quest Completions & Verification

    @discardableResult
    func markComplete(quest: QuestCache, by profile: Profile, at completedDate: Date = Date()) async throws -> QuestCompletion {
        try await completionService.markComplete(quest: quest, by: profile, at: completedDate)
    }

    @discardableResult
    func markComplete(quest: Quest, by profile: Profile, at completedDate: Date = Date()) async throws -> QuestCompletion {
        try await completionService.markComplete(quest: quest, by: profile, at: completedDate)
    }

    func withdrawCompletion(questLog: QuestCompletion, by profile: Profile) async throws {
        try await completionService.withdrawCompletion(questLog: questLog, by: profile)
    }

    func withdrawCompletion(questLog: QuestCompletionCache, by profile: Profile) async throws {
        try await completionService.withdrawCompletion(questLog: questLog, by: profile)
    }

    @discardableResult
    func verify(questLog: QuestCompletion, by parent: Profile) async throws -> QuestCompletion {
        try await completionService.verify(questLog: questLog, by: parent)
    }

    @discardableResult
    func approve(questLog: QuestCompletion, by parent: Profile) async throws -> QuestCompletion {
        try await completionService.approve(questLog: questLog, by: parent)
    }

    @discardableResult
    func reject(questLog: QuestCompletion, by parent: Profile) async throws -> QuestCompletion {
        try await completionService.reject(questLog: questLog, by: parent)
    }

    /// Strictly-local cached logs for a quest, sorted newest-first.
    func cachedQuestLogs(forQuest quest: Quest) -> [QuestCompletion] {
        completionService.cachedQuestLogs(forQuest: quest)
    }

    // MARK: - Reward Application & XP Banking

    @discardableResult
    func applyReward(for quest: Quest, to hero: Profile, completion: QuestCompletion) async throws -> Int64 {
        try await rewardService.applyReward(for: quest, to: hero, completion: completion)
    }

    // MARK: - Quest Logs & Derived Reads

    func fetchStreak(for profile: Profile) async throws -> Int {
        try await completionService.fetchStreak(for: profile)
    }

    func earnedThisWeek(profile: Profile, weekOf: Date, templatesByID: [String: QuestTemplate]) async throws -> Int64 {
        try await completionService.earnedThisWeek(profile: profile, weekOf: weekOf, templatesByID: templatesByID)
    }

    /// Cache-first read. Background refresh handled by CKSyncEngine via push notifications.
    func fetchQuestLogs(forQuest quest: Quest, useCache: Bool = true) async throws -> [QuestCompletion] {
        try await completionService.fetchQuestLogs(forQuest: quest, useCache: useCache)
    }

    /// Cache-first read. Background refresh handled by CKSyncEngine via push notifications.
    func fetchQuestLogs(for profile: Profile) async throws -> [QuestCompletion] {
        try await completionService.fetchQuestLogs(for: profile)
    }

    /// Cache-first read. Background refresh handled by CKSyncEngine via push notifications.
    func fetchQuestCompletionsForFamily(family: Family) async throws -> [QuestCompletion] {
        try await completionService.fetchQuestCompletionsForFamily(family: family)
    }
}

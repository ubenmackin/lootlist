//
//  GoalService.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import CloudKit
import Foundation
import Observation
import os

// MARK: - GoalAllocation

/// One goal's share of an incoming contribution after FIFO cascade within a
/// bucket. Callers persist these as immutable ledger entries with deterministic
/// IDs (`contrib-{goalRecordName}-{sourceEventID}`).
struct GoalAllocation: Equatable, Sendable {
    let goalRecordName: String
    let profileRecordName: String
    let bucketKind: String
    let allocatedPennies: Int64
}

// MARK: - GoalServiceError

enum GoalServiceError: Error, LocalizedError, Equatable {
    case notFound
    case unauthorized
    case invalidConfig

    var errorDescription: String? {
        switch self {
        case .notFound:
            "Goal not found."
        case .unauthorized:
            "You don't have permission to modify this goal."
        case .invalidConfig:
            "Goal configuration is invalid."
        }
    }
}

// MARK: - GoalService

/// Creates, archives, and completes savings goals with FIFO bucket allocations.
@MainActor
@Observable
final class GoalService {
    private static let staticLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "LootList",
        category: "GoalService"
    )
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "LootList",
        category: "GoalService"
    )

    private let cloudKit: any CloudKitServiceProtocol
    let cacheService: any CacheServicing
    let syncCoordinator: any SyncEnqueuing
    let appState: AppState
    var achievementService: AchievementService?
    var celebrationManager: CelebrationManager?

    init(
        cloudKit: any CloudKitServiceProtocol,
        cacheService: any CacheServicing,
        appState: AppState,
        syncCoordinator: any SyncEnqueuing,
        achievementService: AchievementService? = nil,
        celebrationManager: CelebrationManager? = nil
    ) {
        self.cloudKit = cloudKit
        self.cacheService = cacheService
        self.appState = appState
        self.syncCoordinator = syncCoordinator
        self.achievementService = achievementService
        self.celebrationManager = celebrationManager
    }

    /// Test convenience that supplies in-memory cache and no-op coordinator when callers omit dependencies.
    @_disfavoredOverload
    convenience init(
        cloudKit: any CloudKitServiceProtocol,
        cacheService: (any CacheServicing)? = nil,
        appState: AppState? = nil,
        syncCoordinator: (any SyncEnqueuing)? = nil,
        achievementService: AchievementService? = nil,
        celebrationManager: CelebrationManager? = nil
    ) {
        final class NoopSync: SyncEnqueuing {
            func enqueueSave(recordID _: CKRecord.ID, isOwner _: Bool) {}
            func enqueueDelete(recordID _: CKRecord.ID, isOwner _: Bool) {}
            func batchEnqueueSave(recordIDs _: [CKRecord.ID], isOwner _: Bool) {}
        }
        let cache: any CacheServicing
        if let cacheService {
            cache = cacheService
        } else {
            Self.staticLogger.warning("GoalService initialized without cacheService; using fallback in-memory cache.")
            cache = CacheService.inMemoryFallback(logger: Self.staticLogger)
        }
        let state = appState ?? AppState()
        let coord: any SyncEnqueuing = syncCoordinator ?? NoopSync()
        self.init(cloudKit: cloudKit, cacheService: cache, appState: state, syncCoordinator: coord, achievementService: achievementService, celebrationManager: celebrationManager)
    }

    // MARK: - Deterministic Contribution Identity

    /// `contrib-{goalRecordName}-{sourceEventID}` — CloudKit dedupes the record
    /// name across devices, making every contribution double-run safe.
    static func contributionRecordName(goalRecordName: String, sourceEventID: String) -> String {
        "contrib-\(goalRecordName)-\(sourceEventID)"
    }

    // MARK: - FIFO Allocator (pure, no side effects)

    /// Groups goals by profile and bucket, projecting FIFO allocations from savings entries.
    static func allocate(amountPennies: Int64, goals: [GoalCache]) -> [GoalAllocation] {
        guard amountPennies > 0 else { return [] }
        var remaining = amountPennies
        var result: [GoalAllocation] = []

        // Group by (profile, bucket) — FIFO is within a single bucket.
        let grouped = Dictionary(grouping: goals) {
            "\($0.profileRecordName)|\($0.bucketKind)"
        }

        // Sort groups deterministically by oldest goal creation time so broader goal
        // sets cascade funds in creation order across buckets.
        let sortedGroups = grouped.values.sorted { groupA, groupB in
            let minA = groupA.map(\.createdAt).min() ?? .distantPast
            let minB = groupB.map(\.createdAt).min() ?? .distantPast
            if minA != minB {
                return minA < minB
            }
            let recordA = groupA.filter { $0.createdAt == minA }.map(\.recordName).min() ?? groupA.map(\.recordName).min() ?? ""
            let recordB = groupB.filter { $0.createdAt == minB }.map(\.recordName).min() ?? groupB.map(\.recordName).min() ?? ""
            return recordA < recordB
        }

        for bucketGoals in sortedGroups {
            guard remaining > 0 else { break }

            // Oldest incomplete non-archived goal first.
            let sorted = bucketGoals.sorted {
                if $0.createdAt != $1.createdAt {
                    return $0.createdAt < $1.createdAt
                }
                return $0.recordName < $1.recordName
            }

            for goal in sorted {
                guard remaining > 0 else { break }
                if goal.isArchived {
                    continue
                }

                if goal.completedAt != nil {
                    // Already completed — consume its target from the pool so
                    // the cascade moves past it. The funds were credited when
                    // the goal was marked complete.
                    remaining = max(remaining - goal.targetAmountPennies, 0)
                    continue
                }

                let alloc = min(remaining, goal.targetAmountPennies)
                result.append(GoalAllocation(
                    goalRecordName: goal.recordName,
                    profileRecordName: goal.profileRecordName,
                    bucketKind: goal.bucketKind,
                    allocatedPennies: alloc
                ))
                remaining -= alloc
            }
        }

        return result
    }

    // MARK: - Create Goal

    /// Creates a new savings goal. The acting profile must match the target
    /// profile (hero creates own goals) OR be a parent creating on behalf of a
    /// child. Unauthorized callers get `GoalServiceError.unauthorized`.
    @discardableResult
    func createGoal(name: String,
                    category: String? = nil,
                    emojiIcon: String? = nil,
                    targetAmountPennies: Int64,
                    bucketKind: BucketKind,
                    for targetProfile: Profile,
                    family: Family) async throws -> Goal
    {
        guard let acting = appState.currentProfile else {
            throw GoalServiceError.unauthorized
        }
        try ActiveFamilyScopeGuard.requireActiveFamilyScope(
            family: family,
            cloudKit: cloudKit,
            appState: appState
        )

        // Hero may create own goals; parent may create on behalf of any child.
        if acting.role == .hero {
            guard acting.id == targetProfile.id else {
                throw GoalServiceError.unauthorized
            }
        } else {
            guard acting.role.isParent else {
                throw GoalServiceError.unauthorized
            }
        }

        let id = CKRecord.ID(recordName: UUID().uuidString,
                             zoneID: family.id.zoneID)
        let goal = Goal(
            profile: CKRecord.Reference(recordID: targetProfile.id, action: .none),
            family: CKRecord.Reference(recordID: family.id, action: .none),
            bucketKind: bucketKind,
            name: name,
            category: category,
            emojiIcon: emojiIcon,
            targetAmountPennies: targetAmountPennies,
            createdAt: Date(),
            id: id
        )

        await cacheService.upsertGoal(goal)
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(syncCoordinator, id: goal.id, appState: appState, logger: logger, context: "GoalService.createGoal")

        logger.info("Created goal \"\(name, privacy: .private)\" for profile \(targetProfile.id.recordName, privacy: .private)")

        // Award "First Goal Created" / re-evaluate Goal Getter.
        if let achievementService {
            do {
                try await achievementService.handleGoalCreated(for: targetProfile, family: family)
            } catch {
                logger.error("Failed to evaluate goal creation achievements: \(error, privacy: .private)")
            }
        }

        return goal
    }

    // MARK: - Archive Goal

    /// Toggles `isArchived` on a goal. The acting profile must own the goal
    /// (hero archiving own) OR be a parent (parents may archive any goal).
    @discardableResult
    func archiveGoal(_ goal: Goal, family: Family) async throws -> Goal {
        guard let acting = appState.currentProfile else {
            throw GoalServiceError.unauthorized
        }
        try ActiveFamilyScopeGuard.requireActiveFamilyScope(
            family: family,
            cloudKit: cloudKit,
            appState: appState
        )

        // Parent may archive any goal; hero may archive own goal.
        if acting.role == .hero {
            guard acting.id.recordName == goal.profile.recordID.recordName else {
                throw GoalServiceError.unauthorized
            }
        } else {
            guard acting.role.isParent else {
                throw GoalServiceError.unauthorized
            }
        }

        let updatedGoal: Goal = {
            var copy = goal
            copy.isArchived = true
            return copy
        }()

        await cacheService.upsertGoal(updatedGoal)
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(syncCoordinator, id: updatedGoal.id, appState: appState, logger: logger, context: "GoalService.archiveGoal")

        logger.info("Archived goal \"\(goal.name, privacy: .private)\"")

        return updatedGoal
    }

    /// Archives goal locally and enqueues CloudKit delete.
    func archiveGoal(_ goalCache: GoalCache, familyRecordName: String?) async throws {
        guard let family = appState.family else {
            throw ScopeViolation.noActiveFamily
        }
        if let supplied = familyRecordName, supplied != family.id.recordName {
            throw ScopeViolation.familyMismatch(active: family.id.recordName, supplied: supplied)
        }
        let zoneID = appState.resolvedFamilyZoneID()
        try await archiveGoal(goalCache.toGoal(zoneID: zoneID), family: family)
    }

    // MARK: - Update Goal

    /// Updates an existing savings goal. The acting profile must match the goal's owner
    /// (hero updates own) OR be a parent (parents may update any goal).
    @discardableResult
    func updateGoal(_ goal: Goal,
                    name: String,
                    category: String? = nil,
                    emojiIcon: String? = nil,
                    targetAmountPennies: Int64,
                    bucketKind: BucketKind,
                    family: Family) async throws -> Goal
    {
        guard let acting = appState.currentProfile else {
            throw GoalServiceError.unauthorized
        }
        try ActiveFamilyScopeGuard.requireActiveFamilyScope(
            family: family,
            cloudKit: cloudKit,
            appState: appState
        )

        // Hero may update own goals; parent may update any child's goal.
        if acting.role == .hero {
            guard acting.id.recordName == goal.profile.recordID.recordName else {
                throw GoalServiceError.unauthorized
            }
        } else {
            guard acting.role.isParent else {
                throw GoalServiceError.unauthorized
            }
        }

        var updated = goal
        updated.name = name
        updated.category = category
        updated.emojiIcon = emojiIcon
        updated.targetAmountPennies = targetAmountPennies
        updated.bucketKind = bucketKind.rawValue

        await cacheService.upsertGoal(updated)
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(syncCoordinator, id: updated.id, appState: appState, logger: logger, context: "GoalService.updateGoal")

        logger.info("Updated goal \"\(name, privacy: .private)\" for profile \(goal.profile.recordID.recordName, privacy: .private)")
        return updated
    }

    /// Updates straight from a `GoalCache` row.
    func updateGoal(_ goalCache: GoalCache,
                    draft: GoalDraft,
                    familyRecordName: String?) async throws
    {
        guard let family = appState.family else {
            throw ScopeViolation.noActiveFamily
        }
        if let supplied = familyRecordName, supplied != family.id.recordName {
            throw ScopeViolation.familyMismatch(active: family.id.recordName, supplied: supplied)
        }
        let zoneID = appState.resolvedFamilyZoneID()
        let goal = goalCache.toGoal(zoneID: zoneID)
        try await updateGoal(
            goal,
            name: draft.name,
            category: draft.category,
            emojiIcon: draft.emojiIcon,
            targetAmountPennies: draft.targetAmountPennies,
            bucketKind: draft.bucketKind,
            family: family
        )
    }

    // MARK: - Delete Goal

    /// Deletes a savings goal. The acting profile must match the goal's owner
    /// OR be a parent.
    func deleteGoal(_ goal: Goal, family: Family) async throws {
        guard let acting = appState.currentProfile else {
            throw GoalServiceError.unauthorized
        }
        try ActiveFamilyScopeGuard.requireActiveFamilyScope(
            family: family,
            cloudKit: cloudKit,
            appState: appState
        )

        if acting.role == .hero {
            guard acting.id.recordName == goal.profile.recordID.recordName else {
                throw GoalServiceError.unauthorized
            }
        } else {
            guard acting.role.isParent else {
                throw GoalServiceError.unauthorized
            }
        }

        await cacheService.invalidate(recordName: goal.id.recordName, family: family.id.recordName, type: .goal)
        ActiveFamilyScopeGuard.enqueueDeleteWithCorrectedOwner(syncCoordinator, id: goal.id, appState: appState, logger: logger, context: "GoalService.deleteGoal")

        logger.info("Deleted goal \"\(goal.name, privacy: .private)\"")
    }

    /// Deletes straight from a `GoalCache` row.
    func deleteGoal(_ goalCache: GoalCache, familyRecordName: String?) async throws {
        guard let family = appState.family else {
            throw ScopeViolation.noActiveFamily
        }
        if let supplied = familyRecordName, supplied != family.id.recordName {
            throw ScopeViolation.familyMismatch(active: family.id.recordName, supplied: supplied)
        }
        let zoneID = appState.resolvedFamilyZoneID()
        let goal = goalCache.toGoal(zoneID: zoneID)
        try await deleteGoal(goal, family: family)
    }

    // MARK: - Complete Goal Manually

    /// Marks a goal as completed. Typically automated via contribution cascade
    /// but callable directly for manual completion. Same role rules as archive:
    /// hero completes own; parent completes any.
    @discardableResult
    func completeGoal(_ goal: Goal, family: Family) async throws -> Goal {
        guard let acting = appState.currentProfile else {
            throw GoalServiceError.unauthorized
        }
        try ActiveFamilyScopeGuard.requireActiveFamilyScope(
            family: family,
            cloudKit: cloudKit,
            appState: appState
        )

        if acting.role == .hero {
            guard acting.id.recordName == goal.profile.recordID.recordName else {
                throw GoalServiceError.unauthorized
            }
        } else {
            guard acting.role.isParent else {
                throw GoalServiceError.unauthorized
            }
        }

        let updatedGoal: Goal = {
            var copy = goal
            copy.completedAt = Date()
            return copy
        }()

        await cacheService.upsertGoal(updatedGoal)
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(syncCoordinator, id: updatedGoal.id, appState: appState, logger: logger, context: "GoalService.completeGoal")

        // Centralized celebration hook.
        triggerGoalCompletionFeedback(goalName: goal.name, profile: goal.profile, family: family)

        logger.info("Completed goal \"\(goal.name, privacy: .private)\"")

        return updatedGoal
    }

    // MARK: - Contribute Funds to Goals (FIFO)

    /// Allocates deposit across active goals FIFO, returning created contribution events.
    @discardableResult
    func contributeToBucket(amountPennies: Int64,
                            profile: Profile,
                            family: Family,
                            bucketKind: BucketKind,
                            sourceEventID: String,
                            contributionDate: Date = Date()) async throws -> [GoalAllocation]
    {
        guard amountPennies > 0 else { return [] }
        try ActiveFamilyScopeGuard.requireActiveFamilyScope(
            family: family,
            cloudKit: cloudKit,
            appState: appState
        )

        // Fetch goals scoped to this profile + bucket, ordered by createdAt.
        let activeGoals = cacheService.fetchGoals(
            profileRecordName: profile.id.recordName,
            bucketKind: bucketKind.rawValue,
            familyRecordName: family.id.recordName
        )

        let allocations = Self.allocate(amountPennies: amountPennies, goals: activeGoals)
        guard !allocations.isEmpty else { return [] }

        // Collect all ledger entries first — deterministic IDs preserved via
        // `contrib-{goalRecordName}-{sourceEventID}`; FIFO cascade already
        // resolved by `allocate()` above.
        var ledgerEntries: [LedgerEntry] = []
        ledgerEntries.reserveCapacity(allocations.count)
        for alloc in allocations {
            let recordName = Self.contributionRecordName(
                goalRecordName: alloc.goalRecordName,
                sourceEventID: sourceEventID
            )
            let entry = LedgerEntry(
                profile: CKRecord.Reference(recordID: profile.id, action: .none),
                amount: Double(alloc.allocatedPennies) / 100.0,
                description: "Goal Contribution",
                date: contributionDate,
                source: LedgerSource.goal.rawValue,
                bucketKind: bucketKind.rawValue,
                family: CKRecord.Reference(recordID: family.id, action: .none),
                id: CKRecord.ID(recordName: recordName, zoneID: family.id.zoneID)
            )
            ledgerEntries.append(entry)
            logger.info("Contributed \(alloc.allocatedPennies)p to goal \(alloc.goalRecordName, privacy: .private)")
        }

        // Detect completions before the batch write so `priorContributedPennies`
        // sums from cache before these ledger entries land (read-before-write).
        let completedGoalCaches = detectCompletions(allocations: allocations, goals: activeGoals)
        var completedGoals: [Goal] = []
        completedGoals.reserveCapacity(completedGoalCaches.count)
        for goalCache in completedGoalCaches {
            let domain = goalCache.toGoal(zoneID: family.id.zoneID)
            var updated = domain
            updated.completedAt = contributionDate
            completedGoals.append(updated)
        }

        // Single transaction: one `saveContext()` for all ledger entries + completions.
        if !ledgerEntries.isEmpty || !completedGoals.isEmpty {
            await cacheService.batchUpsertLedgerEntriesAndGoals(
                ledgerEntries: ledgerEntries,
                goals: completedGoals,
                familyRecordName: family.id.recordName
            )
        }

        var allRecordIDs: [CKRecord.ID] = []
        allRecordIDs.reserveCapacity(ledgerEntries.count + completedGoals.count)
        allRecordIDs.append(contentsOf: ledgerEntries.map(\.id))
        allRecordIDs.append(contentsOf: completedGoals.map(\.id))
        if !allRecordIDs.isEmpty {
            ActiveFamilyScopeGuard.batchEnqueueWithCorrectedOwner(syncCoordinator, ids: allRecordIDs, appState: appState, logger: logger, context: "GoalService.contributeToBucket")
        }

        for completed in completedGoals {
            triggerGoalCompletionFeedback(
                goalName: completed.name,
                profile: CKRecord.Reference(recordID: profile.id, action: .none),
                family: family
            )
            logger.info("Goal \"\(completed.name, privacy: .private)\" completed via contribution")
        }

        return allocations
    }

    // MARK: - Completion Detection

    /// Returns GoalCache rows that reached full funding from recent allocations.
    private func detectCompletions(allocations: [GoalAllocation],
                                   goals: [GoalCache]) -> [GoalCache]
    {
        let goalMap = Dictionary(uniqueKeysWithValues: goals.map { ($0.recordName, $0) })
        var completed: [GoalCache] = []

        for alloc in allocations {
            guard let goal = goalMap[alloc.goalRecordName],
                  goal.completedAt == nil,
                  !goal.isArchived
            else { continue }

            // Sum prior contributions for this goal from cache ledger entries.
            let priorPennies = priorContributedPennies(goalRecordName: alloc.goalRecordName,
                                                       profileRecordName: alloc.profileRecordName,
                                                       familyRecordName: goal.familyRecordName)

            let totalAfter = priorPennies + alloc.allocatedPennies
            if totalAfter >= goal.targetAmountPennies {
                completed.append(goal)
            }
        }

        return completed
    }

    /// Sums all contribution ledger entries for a goal so the completion check
    /// accounts for prior payouts and multi-event fills.
    private func priorContributedPennies(goalRecordName: String,
                                         profileRecordName: String,
                                         familyRecordName: String) -> Int64
    {
        let prefix = "contrib-\(goalRecordName)-"
        let entries = cacheService.fetchLedgerEntries(
            profileRecordName: profileRecordName,
            family: familyRecordName
        )

        return entries
            .filter { $0.recordName.hasPrefix(prefix) }
            .reduce(into: Int64(0)) { acc, entry in
                acc += Int64((entry.amount * 100).rounded())
            }
    }

    // MARK: - Celebration Feedback (centralized)

    /// Single helper for goal-completion feedback so haptic + overlay calls
    /// stay centralized and reconcilable. The spec maps `CelebrationOverlay`
    /// (Views/Shared/) and `HapticsService` (Utilities/) to this hook.
    private func triggerGoalCompletionFeedback(goalName _: String,
                                               profile: CKRecord.Reference,
                                               family: Family)
    {
        HapticsService.success()
        // Trigger canvas confetti via CelebrationManager — the overlay modifier
        // on the root view reads isConfettiShowing and presents the CelebrationOverlay.
        celebrationManager?.triggerConfetti()

        // Also notify AchievementService for "Goal Getter" re-evaluation.
        if let achievementService {
            let profileID = profile.recordID
            if let cached = cacheService.fetchProfile(
                recordName: profileID.recordName,
                family: family.id.recordName
            ) {
                let domainProfile = cached.toProfile(zoneID: family.id.zoneID)
                Task {
                    do {
                        try await achievementService.handleGoalCompleted(
                            for: domainProfile,
                            family: family
                        )
                    } catch {
                        logger.error("Failed to evaluate goal completion achievements: \(error, privacy: .private)")
                    }
                }
            }
        }
    }
}

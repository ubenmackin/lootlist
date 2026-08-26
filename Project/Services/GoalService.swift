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

/// Creates, archives, and completes savings goals. Contributions flow through
/// the pure `allocate(amountPennies:goals:)` FIFO allocator so the same cascade
/// logic is testable in isolation and reused by the payout engine.
///
/// Role rules:
/// - **Heroes own their goals:** a child may create, archive, and complete their
///   own goals but not touch another hero's goals.
/// - **Parents may archive any goal** as defense-in-depth moderation.
@MainActor
@Observable
final class GoalService {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "LootList",
        category: "GoalService"
    )

    private let cloudKit: any CloudKitServiceProtocol
    var cacheService: CacheService?
    var syncCoordinator: CKSyncEngineCoordinator?
    var appState: AppState?
    var achievementService: AchievementService?
    var celebrationManager: CelebrationManager?

    init(
        cloudKit: any CloudKitServiceProtocol,
        cacheService: CacheService? = nil,
        appState: AppState? = nil,
        syncCoordinator: CKSyncEngineCoordinator? = nil,
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

    // MARK: - Deterministic Contribution Identity

    /// `contrib-{goalRecordName}-{sourceEventID}` — CloudKit dedupes the record
    /// name across devices, making every contribution double-run safe.
    static func contributionRecordName(goalRecordName: String, sourceEventID: String) -> String {
        "contrib-\(goalRecordName)-\(sourceEventID)"
    }

    // MARK: - FIFO Allocator (pure, no side effects)

    /// Groups goals by `(profileRecordName, bucketKind)`, then within each
    /// group fills the oldest incomplete non-archived goal first. Overflow
    /// cascades to the next goal in creation order. Surplus past all goals is
    /// NOT returned — it stays as unallocated savings in the bucket.
    ///
    /// Completed goals consume their target from the pool but produce no
    /// allocation entry — the funds were already credited when the goal reached
    /// its target. Archived goals are skipped entirely and do not consume funds.
    ///
    /// Callers pre-filter goals to a single `(profile, bucket)` pair so the pool
    /// maps 1:1 to one bucket's incoming funds. Passing a broader set still
    /// produces deterministic results but distributes the single pool across
    /// every `(profile, bucket)` group.
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
            if minA == minB {
                return (groupA.first?.profileRecordName ?? "") < (groupB.first?.profileRecordName ?? "")
            }
            return minA < minB
        }

        for bucketGoals in sortedGroups {
            guard remaining > 0 else { break }

            // Oldest incomplete non-archived goal first.
            let sorted = bucketGoals.sorted { $0.createdAt < $1.createdAt }

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
        guard let appState, let acting = appState.currentProfile else {
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

        await cacheService?.upsertGoal(goal)
        syncCoordinator?.enqueueSave(recordID: goal.id, isOwner: appState.isZoneOwner)

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
        guard let appState, let acting = appState.currentProfile else {
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

        await cacheService?.upsertGoal(updatedGoal)
        syncCoordinator?.enqueueSave(recordID: updatedGoal.id, isOwner: appState.isZoneOwner)

        logger.info("Archived goal \"\(goal.name, privacy: .private)\"")

        return updatedGoal
    }

    /// Archives straight from a `GoalCache` row so view-layer callers never
    /// convert cache models into the domain struct themselves — that
    /// conversion belongs at the service mutation boundary. Delegation to
    /// `archiveGoal(_:family:)` keeps every role and scope guard on the one
    /// canonical write path.
    func archiveGoal(_ goalCache: GoalCache, familyRecordName: String?) async throws {
        guard let appState, let family = appState.family else {
            throw ScopeViolation.noActiveFamily
        }
        if let supplied = familyRecordName, supplied != family.id.recordName {
            throw ScopeViolation.familyMismatch(active: family.id.recordName, supplied: supplied)
        }
        let zoneID = appState.familyZoneID ?? family.id.zoneID
        try await archiveGoal(goalCache.toGoal(zoneID: zoneID), family: family)
    }

    // MARK: - Complete Goal Manually

    /// Marks a goal as completed. Typically automated via contribution cascade
    /// but callable directly for manual completion. Same role rules as archive:
    /// hero completes own; parent completes any.
    @discardableResult
    func completeGoal(_ goal: Goal, family: Family) async throws -> Goal {
        guard let appState, let acting = appState.currentProfile else {
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

        await cacheService?.upsertGoal(updatedGoal)
        syncCoordinator?.enqueueSave(recordID: updatedGoal.id, isOwner: appState.isZoneOwner)

        // Centralized celebration hook.
        triggerGoalCompletionFeedback(goalName: goal.name, profile: goal.profile, family: family)

        logger.info("Completed goal \"\(goal.name, privacy: .private)\"")

        return updatedGoal
    }

    // MARK: - Contribute Funds to Goals (FIFO)

    /// Allocates an incoming bucket deposit across the profile's active
    /// (non-archived) goals in FIFO order for the given bucket. The allocation
    /// result drives immutable ledger entries with deterministic contribution
    /// IDs so CloudKit dedupes them across devices. Returns the allocations so
    /// callers can inspect which goals received funds.
    ///
    /// If a contribution fills the final penny of a goal, the goal is marked
    /// complete and celebration feedback fires. Callers must pass a stable
    /// `sourceEventID` (e.g. a payout period record name) to produce
    /// deterministic contribution record names.
    @discardableResult
    func contributeToBucket(amountPennies: Int64,
                            profile: Profile,
                            family: Family,
                            bucketKind: BucketKind,
                            sourceEventID: String,
                            contributionDate: Date = Date()) async throws -> [GoalAllocation]
    {
        guard amountPennies > 0 else { return [] }
        guard let appState else {
            throw GoalServiceError.unauthorized
        }
        try ActiveFamilyScopeGuard.requireActiveFamilyScope(
            family: family,
            cloudKit: cloudKit,
            appState: appState
        )

        // Fetch goals scoped to this profile + bucket, ordered by createdAt.
        let activeGoals = cacheService?.fetchGoals(
            profileRecordName: profile.id.recordName,
            bucketKind: bucketKind.rawValue,
            familyRecordName: family.id.recordName
        ) ?? []

        let allocations = Self.allocate(amountPennies: amountPennies, goals: activeGoals)

        // Persist each allocation as an immutable ledger entry.
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
                source: "goal",
                bucketKind: bucketKind.rawValue,
                family: CKRecord.Reference(recordID: family.id, action: .none),
                id: CKRecord.ID(recordName: recordName, zoneID: family.id.zoneID)
            )
            await cacheService?.upsertLedgerEntry(entry)
            syncCoordinator?.enqueueSave(recordID: entry.id, isOwner: appState.isZoneOwner)

            logger.info("Contributed \(alloc.allocatedPennies)p to goal \(alloc.goalRecordName, privacy: .private)")
        }

        // Detect completions: if a contribution fills the remaining target
        // exactly, mark the goal complete and celebrate.
        let completedGoalNames = detectCompletions(allocations: allocations, goals: activeGoals)
        for goalCache in completedGoalNames {
            let domain = goalCache.toGoal(zoneID: family.id.zoneID)
            var updated = domain
            updated.completedAt = contributionDate
            await cacheService?.upsertGoal(updated)
            syncCoordinator?.enqueueSave(recordID: updated.id, isOwner: appState.isZoneOwner)

            triggerGoalCompletionFeedback(
                goalName: domain.name,
                profile: CKRecord.Reference(recordID: profile.id, action: .none),
                family: family
            )

            logger.info("Goal \"\(domain.name, privacy: .private)\" completed via contribution")
        }

        return allocations
    }

    // MARK: - Completion Detection

    /// Returns the GoalCache rows that were fully filled by this batch of
    /// allocations. A goal is "completed" when the cumulative contributions
    /// (existing ledger entries + this allocation) reach or exceed its target.
    /// Only goals receiving funds in this batch are checked.
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
        guard let entries = cacheService?.fetchLedgerEntries(
            profileRecordName: profileRecordName,
            family: familyRecordName
        ) else { return 0 }

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
            if let cached = cacheService?.fetchProfile(
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

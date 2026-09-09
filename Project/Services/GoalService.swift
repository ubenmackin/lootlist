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
    case insufficientFunds(available: Int64, requested: Int64)

    var errorDescription: String? {
        switch self {
        case .notFound:
            "Goal not found."
        case .unauthorized:
            "You don't have permission to modify this goal."
        case .invalidConfig:
            "Goal configuration is invalid."
        case let .insufficientFunds(available, requested):
            "You only have \(CurrencyFormatter.string(pennies: available)) saved — that goal needs \(CurrencyFormatter.string(pennies: requested))."
        }
    }
}

// MARK: - GoalService

/// Creates, archives, and completes savings goals with FIFO bucket allocations.
@MainActor
@Observable
final class GoalService {
    private static let staticLogger = Logger(category: "GoalService")
    private let logger = Logger(category: "GoalService")

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
        let cache: any CacheServicing
        if let cacheService {
            cache = cacheService
        } else {
            Self.staticLogger.warning("GoalService initialized without cacheService; using fallback in-memory cache.")
            cache = CacheService.inMemoryFallback(logger: Self.staticLogger)
        }
        let state = appState ?? AppState()
        let coord: any SyncEnqueuing = syncCoordinator ?? NoopSyncEnqueuing()
        self.init(cloudKit: cloudKit, cacheService: cache, appState: state, syncCoordinator: coord, achievementService: achievementService, celebrationManager: celebrationManager)
    }

    // MARK: - Deterministic Contribution Identity

    /// `contrib-{goalRecordName}-{sourceEventID}` — CloudKit dedupes the record
    /// name across devices, making every contribution double-run safe.
    static func contributionRecordName(goalRecordName: String, sourceEventID: String) -> String {
        DeterministicRecordID.contribution(goalRecordName: goalRecordName, sourceEventID: sourceEventID)
    }

    /// `purchase-{goalRecordName}` — CloudKit dedupes the record name across
    /// devices, making the purchase debit double-run safe.
    static func purchaseRecordName(goalRecordName: String) -> String {
        DeterministicRecordID.purchase(goalRecordName: goalRecordName)
    }

    // MARK: - FIFO Allocator (pure, no side effects)

    /// FIFO allocation within a single bucket. Callers must filter to one
    /// profile + bucket via `fetchGoals(profile:bucket:)`; surplus past all
    /// goals sits unallocated in the bucket.
    static func allocate(amountPennies: Int64, goals: [GoalCache], priorContributedPennies: [String: Int64] = [:]) -> [GoalAllocation] {
        guard amountPennies > 0 else { return [] }
        // WHY open only: completed goals already hold their funds and clear via purchase, so new money cascades past them.
        let open = goals.filter(\.isActiveGoal)
        guard !open.isEmpty else { return [] }
        var remaining = amountPennies
        var result: [GoalAllocation] = []

        let sorted = open.sorted {
            if $0.createdAt != $1.createdAt {
                return $0.createdAt < $1.createdAt
            }
            return $0.recordName < $1.recordName
        }

        for goal in sorted {
            guard remaining > 0 else { break }
            // WHY remaining need: earlier payouts already funded part of the target, so only the shortfall draws from new money.
            let prior = priorContributedPennies[goal.recordName] ?? 0
            let remainingNeed = max(goal.targetAmountPennies - prior, 0)
            guard remainingNeed > 0 else { continue }
            let alloc = min(remaining, remainingNeed)
            result.append(GoalAllocation(
                goalRecordName: goal.recordName,
                profileRecordName: goal.profileRecordName,
                bucketKind: goal.bucketKind,
                allocatedPennies: alloc
            ))
            remaining -= alloc
        }

        return result
    }

    // MARK: - Create Goal

    // INVARIANT: Goal rows are family-scoped and must converge across both
    // private and shared database scopes. A local create sweeps both scope
    // caches and stamps freshness for both so a family never observes a
    // partial or stale sibling-scope row after owner/participant transitions.
    // WHY cross-scope sweep is intentional: it guarantees a single family
    // partition converges regardless of which database holds the authoritative
    // zone, preventing divergence where a hero device and parent device would
    // see different goal sets after a role handoff.

    /// Creates a new savings goal. The acting profile must match the target
    /// profile (hero creates own goals) OR be a parent creating on behalf of a
    /// child. Unauthorized callers get `GoalServiceError.unauthorized`.
    @discardableResult
    func createGoal(name: String,
                    category: String? = nil,
                    emojiIcon: String? = nil,
                    targetAmountPennies: Int64,
                    bucketKind: BucketKind,
                    targetDate: Date? = nil,
                    linkURL: String? = nil,
                    imageURL: String? = nil,
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
            targetDate: targetDate,
            linkURL: linkURL,
            imageURL: imageURL,
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
                    targetDate: Date? = nil,
                    linkURL: String? = nil,
                    imageURL: String? = nil,
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
        updated.targetDate = targetDate
        updated.linkURL = linkURL
        updated.imageURL = imageURL

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
            targetDate: draft.targetDate,
            linkURL: draft.linkURL,
            imageURL: draft.imageURL,
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

        let isOwnerForIdentity = ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState)
        let identity = ScopedRecordIdentity(
            databaseScope: DatabaseScopeResolver.scope(isOwner: isOwnerForIdentity),
            zoneID: goal.id.zoneID,
            recordID: goal.id,
            familyRecordName: family.id.recordName
        )
        // WHY invalidate first: a crash between steps must not leave a server-deleted row revived by owner upsert.
        await cacheService.invalidate(identity: identity, type: .goal, expectedActiveZone: appState.familyZoneID)
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

    // MARK: - Mark Purchased (deduct-and-archive)

    /// Deducts the goal target from its bucket, then completes and archives the
    /// goal. Heroes purchase their own goals without parent approval; parents
    /// may purchase any goal.
    @discardableResult
    func markPurchased(_ goal: Goal, family: Family, date: Date = Date()) async throws -> Goal {
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

        guard goal.targetAmountPennies > 0 else {
            throw GoalServiceError.invalidConfig
        }
        guard let bucket = BucketKind(rawValue: goal.bucketKind) else {
            throw GoalServiceError.invalidConfig
        }

        let profileRecordName = goal.profile.recordID.recordName
        let purchaseLedgers = cacheService.fetchLedgerEntries(
            profileRecordName: profileRecordName,
            family: family.id.recordName
        )
        let recordName = Self.purchaseRecordName(goalRecordName: goal.id.recordName)
        // WHY converge on replay: the deterministic ID already debited, so a second tap only ensures the archive flags.
        if IdempotencyGuard.containsDeterministicID(recordName, in: purchaseLedgers) {
            if goal.completedAt != nil, goal.isArchived {
                return goal
            }
            var converged = goal
            converged.completedAt = converged.completedAt ?? date
            converged.isArchived = true
            await cacheService.upsertGoal(converged)
            ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(syncCoordinator, id: converged.id, appState: appState, logger: logger, context: "GoalService.markPurchased")
            return converged
        }
        // WHY archive gate: purchase is only valid on open goals, so an archived goal must not mint a second debit.
        guard !goal.isArchived else {
            throw GoalServiceError.invalidConfig
        }
        let balances = BucketService.bucketBalances(for: purchaseLedgers, profileRecordName: profileRecordName)
        let available = balances[bucket] ?? 0
        let requested = goal.targetAmountPennies
        // WHY pennies comparison: integer balances stay exact with no drift.
        guard available >= requested else {
            throw GoalServiceError.insufficientFunds(available: available, requested: requested)
        }

        let entry = LedgerEntry(
            profile: goal.profile,
            amount: -requested,
            description: "Purchased \(goal.name)",
            date: date,
            source: LedgerSource.purchase.rawValue,
            bucketKind: bucket.rawValue,
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: CKRecord.ID(recordName: recordName, zoneID: family.id.zoneID)
        )
        var updated = goal
        updated.completedAt = updated.completedAt ?? date
        updated.isArchived = true

        // WHY one batch: the debit and the archive flags converge atomically so @Query never shows a deducted-but-visible goal.
        await cacheService.batchUpsertLedgerEntriesAndGoals(
            ledgerEntries: [entry],
            goals: [updated],
            familyRecordName: family.id.recordName
        )
        ActiveFamilyScopeGuard.batchEnqueueWithCorrectedOwner(
            syncCoordinator,
            ids: [entry.id, updated.id],
            appState: appState,
            logger: logger,
            context: "GoalService.markPurchased"
        )

        triggerGoalCompletionFeedback(goalName: goal.name, profile: goal.profile, family: family)

        let formattedAmount = CurrencyFormatter.string(pennies: requested)
        logger.info("Purchased goal \"\(goal.name, privacy: .private)\" for \(formattedAmount, privacy: .public)")

        return updated
    }

    /// Alias keeping the purchase verb discoverable alongside `markPurchased`.
    @discardableResult
    func purchaseGoal(_ goal: Goal, family: Family, date: Date = Date()) async throws -> Goal {
        try await markPurchased(goal, family: family, date: date)
    }

    /// Marks purchased straight from a `GoalCache` row.
    @discardableResult
    func markPurchased(_ goalCache: GoalCache, familyRecordName: String?, date: Date = Date()) async throws -> Goal {
        guard let family = appState.family else {
            throw ScopeViolation.noActiveFamily
        }
        if let supplied = familyRecordName, supplied != family.id.recordName {
            throw ScopeViolation.familyMismatch(active: family.id.recordName, supplied: supplied)
        }
        let zoneID = appState.resolvedFamilyZoneID()
        return try await markPurchased(goalCache.toGoal(zoneID: zoneID), family: family, date: date)
    }

    /// Cache-row alias for the purchase verb.
    @discardableResult
    func purchaseGoal(_ goalCache: GoalCache, familyRecordName: String?, date: Date = Date()) async throws -> Goal {
        try await markPurchased(goalCache, familyRecordName: familyRecordName, date: date)
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

        // WHY remaining need: earlier payouts already funded part of each target, so the cascade tops up only the shortfall.
        var priorMap: [String: Int64] = [:]
        priorMap.reserveCapacity(activeGoals.count)
        for goal in activeGoals {
            priorMap[goal.recordName] = priorContributedPennies(goalRecordName: goal.recordName,
                                                                profileRecordName: profile.id.recordName,
                                                                familyRecordName: family.id.recordName)
        }
        let allocations = Self.allocate(amountPennies: amountPennies, goals: activeGoals, priorContributedPennies: priorMap)
        guard !allocations.isEmpty else { return [] }

        // Collect all ledger entries first — deterministic IDs preserved via
        // `contrib-{goalRecordName}-{sourceEventID}`; FIFO cascade already
        // resolved by `allocate()` above.
        // WHY single-count: bucketKind stays for goal-progress attribution; balances skip source goal.
        var ledgerEntries: [LedgerEntry] = []
        ledgerEntries.reserveCapacity(allocations.count)
        for alloc in allocations {
            let recordName = Self.contributionRecordName(
                goalRecordName: alloc.goalRecordName,
                sourceEventID: sourceEventID
            )
            // WHY cumulative-aware: same event reuses one ID across settlements, so shortfall adds to prior total instead of regressing.
            let existingPennies: Int64 = {
                guard let existing = cacheService.fetchLedgerEntry(recordName: recordName, family: family.id.recordName) else { return 0 }
                return existing.amount
            }()
            let cumulativePennies = existingPennies + alloc.allocatedPennies
            let entry = LedgerEntry(
                profile: CKRecord.Reference(recordID: profile.id, action: .none),
                amount: cumulativePennies,
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
            ActiveFamilyScopeGuard.batchEnqueueWithCorrectedOwner(
                syncCoordinator,
                ids: allRecordIDs,
                appState: appState,
                logger: logger,
                context: "GoalService.contributeToBucket"
            )
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
                  goal.isActiveGoal
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
        let prefix = DeterministicRecordID.contributionPrefix(for: goalRecordName)
        let entries = cacheService.fetchLedgerEntries(
            profileRecordName: profileRecordName,
            family: familyRecordName,
            recordNamePrefix: prefix
        )

        return entries
            .reduce(into: Int64(0)) { acc, entry in
                acc += entry.amount
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
                Task { @MainActor @Sendable [achievementService, domainProfile, family, logger] in
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

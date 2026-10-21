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

    private static let staticLogger = Logger(category: "GoalService")

    /// Test convenience that supplies in-memory cache and no-op coordinator when callers omit dependencies.
    @_disfavoredOverload
    convenience init(
        cloudKit: any CloudKitServiceProtocol,
        // swiftformat:disable:next redundantParens
        cacheService: (any CacheServicing)? = nil,
        appState: AppState? = nil,
        // swiftformat:disable:next redundantParens
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
        let coord: any SyncEnqueuing
        if let resolvedCoord: any SyncEnqueuing = syncCoordinator ?? AppDependencies.shared?.syncCoordinator {
            coord = resolvedCoord
        } else {
            #if DEBUG
                if TestEnvironment.isRunningUnitOrUITests {
                    Self.staticLogger.warning("GoalService initialized without syncCoordinator; using test Noop seam.")
                } else {
                    Self.staticLogger.error("GoalService initialized without syncCoordinator and no shared coordinator; falling back to Noop seam.")
                }
            #else
                Self.staticLogger.fault("GoalService initialized without syncCoordinator and no shared coordinator; falling back to Noop seam.")
            #endif
            coord = NoopSyncEnqueuing()
        }
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

    /// Single-source root for goal-drawdown record names so calculators and services never drift.
    /// WHY nonisolated: pure string identity shared with background calculators without a MainActor hop.
    nonisolated static let drawdownRoot = "drawdown-"

    /// Returns true when `recordName` is any goal-drawdown record.
    nonisolated static func isDrawdownRecord(_ recordName: String) -> Bool {
        recordName.hasPrefix(drawdownRoot)
    }

    /// `drawdown-{goalRecordName}-{sourceEventID}` — CloudKit dedupes the record
    /// name across devices, making every drawdown double-run safe.
    nonisolated static func drawdownRecordName(goalRecordName: String, sourceEventID: String) -> String {
        "\(drawdownRoot)\(goalRecordName)-\(sourceEventID)"
    }

    /// Prefix for a specific goal's drawdown records: `drawdown-{goalRecordName}-`.
    nonisolated static func drawdownPrefix(for goalRecordName: String) -> String {
        "\(drawdownRoot)\(goalRecordName)-"
    }

    /// Extracts the owning goal record name from a contribution or drawdown marker.
    /// WHY single owner: sheet plus grouping parse markers here so prefix plus collision rules never drift.
    nonisolated static func goalRecordName(fromMarkerRecordName marker: String) -> String? {
        // WHY strip first: collision forks append hex-msSuffix layers, so peel before prefix logic.
        let stripped = DeterministicRecordID.stripCollisionExtension(marker)
        let remainder: String
        if DeterministicRecordID.isContributionRecord(stripped) {
            remainder = String(stripped.dropFirst("contrib-".count))
        } else if isDrawdownRecord(stripped) {
            remainder = String(stripped.dropFirst(drawdownRoot.count))
        } else {
            return nil
        }
        guard !remainder.isEmpty else { return nil }
        // WHY prefix search: goal names carry dashes (UUIDs), so the source start owns the split.
        let sourcePrefixes = [
            "period-", "payout-", "rt-", "transfer-", "manual-",
            "deposit-", "withdrawal-", "interest-", "match-", "purchase-",
            "import-", "contrib-", "drawdown-", "reward-"
        ]
        var bestIndex: String.Index?
        for token in sourcePrefixes {
            let needle = "-" + token
            if let found = remainder.range(of: needle)?.lowerBound, bestIndex == nil || found < bestIndex! {
                bestIndex = found
            }
        }
        if let splitAt = bestIndex {
            let goal = String(remainder[..<splitAt])
            return goal.isEmpty ? nil : goal
        }
        // WHY UUID fallback: production goals mint UUIDs, so a 36-char prefix owns the split when sources lack known prefixes.
        if remainder.count > 36 {
            let candidate = String(remainder.prefix(36))
            let isUUID = UUID(uuidString: candidate) != nil
                && remainder[remainder.index(remainder.startIndex, offsetBy: 36)] == "-"
            if isUUID {
                return candidate
            }
        }
        // WHY last-dash fallback: single-segment test sources leave the goal as everything before the final dash.
        guard let lastDash = remainder.lastIndex(of: "-") else { return nil }
        let goal = String(remainder[..<lastDash])
        return goal.isEmpty ? nil : goal
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

    // WHY cross-scope sweep: one family partition converges across both scopes after role handoffs.

    /// Creates a new savings goal. The acting profile must match the target
    /// profile (hero creates own goals) OR be a parent creating on behalf of a
    /// child. Unauthorized callers get `GoalServiceError.unauthorized`.
    @discardableResult
    func createGoal(
        name: String,
        category: String? = nil,
        emojiIcon: String? = nil,
        targetAmountPennies: Int64,
        bucketKind: BucketKind,
        targetDate: Date? = nil,
        linkURL: String? = nil,
        imageURL: String? = nil,
        for targetProfile: Profile,
        family: Family
    ) async throws -> Goal {
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
        Task { [weak self] in await self?.syncCoordinator.sendPendingChanges() }

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
    func updateGoal(
        _ goal: Goal,
        name: String,
        category: String? = nil,
        emojiIcon: String? = nil,
        targetAmountPennies: Int64,
        bucketKind: BucketKind,
        targetDate: Date? = nil,
        linkURL: String? = nil,
        imageURL: String? = nil,
        family: Family
    ) async throws -> Goal {
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
    func updateGoal(_ goalCache: GoalCache, draft: GoalDraft, familyRecordName: String?) async throws {
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

        // WHY single step: tombstone is captured inside the helper so the delete survives row removal.
        await ActiveFamilyScopeGuard.deleteAndEnqueue(
            cacheService: cacheService,
            target: .init(recordID: goal.id, familyRecordName: family.id.recordName),
            type: .goal,
            deleteContext: .init(
                coordinator: syncCoordinator,
                appState: appState,
                logger: logger,
                context: "GoalService.deleteGoal",
                expectedActiveZone: appState.familyZoneID
            )
        )

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

        guard goal.targetAmountPennies > 0, let bucket = BucketKind(rawValue: goal.bucketKind) else {
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
            Task { [weak self] in await self?.syncCoordinator.sendPendingChanges() }
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
        Task { [weak self] in await self?.syncCoordinator.sendPendingChanges() }

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
    func contributeToBucket(
        amountPennies: Int64,
        profile: Profile,
        family: Family,
        bucketKind: BucketKind,
        sourceEventID: String,
        contributionDate: Date = Date()
    ) async throws -> [GoalAllocation] {
        guard amountPennies > 0 else { return [] }
        try ActiveFamilyScopeGuard.requireActiveFamilyScope(
            family: family,
            cloudKit: cloudKit,
            appState: appState
        )

        // Fetch goals scoped to this profile + bucket, ordered by createdAt.
        let activeGoals = cacheService.fetchGoals(profileRecordName: profile.id.recordName, bucketKind: bucketKind.rawValue, familyRecordName: family.id.recordName)

        // WHY remaining need: earlier payouts already funded part of each target, so the cascade tops up only the shortfall.
        var priorMap: [String: Int64] = [:]
        priorMap.reserveCapacity(activeGoals.count)
        for goal in activeGoals {
            priorMap[goal.recordName] = priorContributedPennies(goalRecordName: goal.recordName, profileRecordName: profile.id.recordName, familyRecordName: family.id.recordName)
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
            let recordName = Self.contributionRecordName(goalRecordName: alloc.goalRecordName, sourceEventID: sourceEventID)
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
            Task { [weak self] in await self?.syncCoordinator.sendPendingChanges() }
        }

        for completed in completedGoals {
            triggerGoalCompletionFeedback(goalName: completed.name, profile: CKRecord.Reference(recordID: profile.id, action: .none), family: family)
            logger.info("Goal \"\(completed.name, privacy: .private)\" completed via contribution")
        }

        return allocations
    }

    // MARK: - Draw Down Goals (Reverse-FIFO)

    /// Draws down active goals newest-first to mirror a bucket decrease.
    @discardableResult
    func applyDrawdown(
        amountPennies: Int64,
        profile: Profile,
        family: Family,
        bucketKind: BucketKind,
        sourceEventID: String,
        contributionDate: Date = Date()
    ) async throws -> [GoalAllocation] {
        guard amountPennies > 0 else { return [] }
        try ActiveFamilyScopeGuard.requireActiveFamilyScope(
            family: family,
            cloudKit: cloudKit,
            appState: appState
        )

        let activeGoals = cacheService.fetchGoals(profileRecordName: profile.id.recordName, bucketKind: bucketKind.rawValue, familyRecordName: family.id.recordName)
        // WHY reverse-FIFO: newest goals unwind first so oldest progress survives shortfalls.
        let sorted = activeGoals.filter(\.isActiveGoal).sorted {
            if $0.createdAt != $1.createdAt {
                return $0.createdAt > $1.createdAt
            }
            return $0.recordName > $1.recordName
        }
        guard !sorted.isEmpty else { return [] }

        var remaining = amountPennies
        var allocations: [GoalAllocation] = []
        var ledgerEntries: [LedgerEntry] = []
        for goal in sorted {
            guard remaining > 0 else { break }
            let available = netDrawdownAvailable(goalRecordName: goal.recordName, profileRecordName: goal.profileRecordName,
                                                 familyRecordName: goal.familyRecordName, sourceEventID: sourceEventID)
            guard available > 0 else { continue }
            let debit = min(remaining, available)
            let base = Self.drawdownRecordName(goalRecordName: goal.recordName, sourceEventID: sourceEventID)
            var recordName = base
            var attempt = 0
            var isConverged = false
            while let existing = cacheService.fetchLedgerEntry(recordName: recordName, family: family.id.recordName) {
                if isIdenticalDrawdown(existing, debitPennies: debit, bucketKind: bucketKind, date: contributionDate) {
                    isConverged = true
                    break
                }
                // WHY convergent extension: divergent payloads fork through the shared hex-msSuffix helper so every device agrees on the fallback name.
                let ms = Int64(contributionDate.timeIntervalSince1970 * 1000)
                let payload = "\(base)|\(debit)|\(bucketKind.rawValue)|\(ms)|\(attempt)"
                recordName = DeterministicRecordID.collisionExtendedName(base: base, payload: payload, date: contributionDate)
                attempt += 1
            }
            allocations.append(GoalAllocation(goalRecordName: goal.recordName, profileRecordName: goal.profileRecordName, bucketKind: goal.bucketKind, allocatedPennies: -debit))
            guard !isConverged else {
                remaining -= debit
                continue
            }
            // WHY single-count: bucketKind stays for goal-progress attribution; balances skip source goal.
            let entry = LedgerEntry(
                profile: CKRecord.Reference(recordID: profile.id, action: .none),
                amount: -debit,
                description: "Goal Drawdown",
                date: contributionDate,
                source: LedgerSource.goal.rawValue,
                bucketKind: bucketKind.rawValue,
                family: CKRecord.Reference(recordID: family.id, action: .none),
                id: CKRecord.ID(recordName: recordName, zoneID: family.id.zoneID)
            )
            ledgerEntries.append(entry)
            logger.info("Drew down \(debit)p from goal \(goal.recordName, privacy: .private)")
            remaining -= debit
        }
        guard !ledgerEntries.isEmpty else { return allocations }

        // WHY never-reopen: completed rows already hold funds and clear via purchase, so drawdown leaves completion flags untouched.
        await cacheService.batchUpsertLedgerEntriesAndGoals(
            ledgerEntries: ledgerEntries,
            goals: [],
            familyRecordName: family.id.recordName
        )
        ActiveFamilyScopeGuard.batchEnqueueWithCorrectedOwner(
            syncCoordinator,
            ids: ledgerEntries.map(\.id),
            appState: appState,
            logger: logger,
            context: "GoalService.applyDrawdown"
        )
        Task { [weak self] in await self?.syncCoordinator.sendPendingChanges() }

        return allocations
    }

    // MARK: - Completion Detection

    /// Returns GoalCache rows that reached full funding from recent allocations.
    private func detectCompletions(allocations: [GoalAllocation], goals: [GoalCache]) -> [GoalCache] {
        let goalMap = Dictionary(uniqueKeysWithValues: goals.map { ($0.recordName, $0) })
        var completed: [GoalCache] = []

        for alloc in allocations {
            guard let goal = goalMap[alloc.goalRecordName],
                  goal.isActiveGoal
            else { continue }

            // Sum prior contributions for this goal from cache ledger entries.
            let priorPennies = priorContributedPennies(goalRecordName: alloc.goalRecordName, profileRecordName: alloc.profileRecordName, familyRecordName: goal.familyRecordName)

            let totalAfter = priorPennies + alloc.allocatedPennies
            if totalAfter >= goal.targetAmountPennies {
                completed.append(goal)
            }
        }

        return completed
    }

    /// Net held pennies for a goal so progress nets contributions against drawdowns.
    private func priorContributedPennies(goalRecordName: String, profileRecordName: String, familyRecordName: String) -> Int64 {
        // WHY net held: drawdowns reuse the contribution namespace in reverse, so progress drops by the drawn total.
        let contribPrefix = DeterministicRecordID.contributionPrefix(for: goalRecordName)
        let contribTotal = cacheService.fetchLedgerEntries(profileRecordName: profileRecordName, family: familyRecordName, recordNamePrefix: contribPrefix)
            .reduce(into: Int64(0)) { $0 += $1.amount }
        let drawPrefix = Self.drawdownPrefix(for: goalRecordName)
        let drawTotal = cacheService.fetchLedgerEntries(profileRecordName: profileRecordName, family: familyRecordName, recordNamePrefix: drawPrefix)
            .reduce(into: Int64(0)) { $0 += $1.amount }
        return contribTotal + drawTotal
    }

    /// Net debitable pennies excluding the current drawdown event so retries converge instead of double-debiting.
    private func netDrawdownAvailable(goalRecordName: String, profileRecordName: String, familyRecordName: String, sourceEventID: String) -> Int64 {
        // WHY exclude current: the in-flight event already counts on replay, so only other drawdowns reduce availability.
        let contribPrefix = DeterministicRecordID.contributionPrefix(for: goalRecordName)
        let contribTotal = cacheService.fetchLedgerEntries(profileRecordName: profileRecordName, family: familyRecordName, recordNamePrefix: contribPrefix)
            .reduce(into: Int64(0)) { $0 += $1.amount }
        let prefix = Self.drawdownPrefix(for: goalRecordName)
        let draws = cacheService.fetchLedgerEntries(profileRecordName: profileRecordName, family: familyRecordName, recordNamePrefix: prefix)
        let base = Self.drawdownRecordName(goalRecordName: goalRecordName, sourceEventID: sourceEventID)
        let other = draws
            .filter { !($0.recordName == base || $0.recordName.hasPrefix(base + "-")) }
            .reduce(into: Int64(0)) { $0 += $1.amount }
        return max(contribTotal + other, 0)
    }

    /// WHY convergent: same debit converges, divergent payloads fork via hash extension.
    private func isIdenticalDrawdown(_ existing: LedgerEntryCache, debitPennies: Int64, bucketKind: BucketKind, date: Date) -> Bool {
        guard existing.source == LedgerSource.goal.rawValue,
              existing.bucketKind == bucketKind.rawValue,
              existing.amount == -debitPennies
        else { return false }
        return DeterministicRecordID.isSameMillisecond(existing.date, date)
    }

    // MARK: - Celebration Feedback (centralized)

    /// Single helper for goal-completion feedback so haptic + overlay calls
    /// stay centralized and reconcilable. The spec maps `CelebrationOverlay`
    /// (Views/Shared/) and `HapticsService` (Utilities/) to this hook.
    private func triggerGoalCompletionFeedback(goalName _: String, profile: CKRecord.Reference, family: Family) {
        HapticsService.success()
        // Trigger canvas confetti via CelebrationManager — the overlay modifier
        // on the root view reads isConfettiShowing and presents the CelebrationOverlay.
        celebrationManager?.triggerConfetti()

        // Also notify AchievementService for "Goal Getter" re-evaluation.
        if let achievementService {
            let profileID = profile.recordID
            if let cached = cacheService.fetchProfile(recordName: profileID.recordName, family: family.id.recordName) {
                let domainProfile = cached.toProfile(zoneID: family.id.zoneID)
                Task { [achievementService, domainProfile, family, logger] in
                    do {
                        try await achievementService.handleGoalCompleted(for: domainProfile, family: family)
                    } catch {
                        logger.error("Failed to evaluate goal completion achievements: \(error, privacy: .private)")
                    }
                }
            }
        }
    }
}

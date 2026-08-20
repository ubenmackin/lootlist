//
//  BonusObjectiveService.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import CloudKit
import Foundation
import Synchronization

enum BonusObjectiveType: String, Sendable {
    case completeAllToday
    case earlyBird
    case keepStreak
    case completeTwoQuests
}

struct BonusObjective: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let description: String
    let gemReward: Int
    let type: BonusObjectiveType
}

struct ObjectiveTemplate: Sendable {
    let type: BonusObjectiveType
    let title: String
    let description: String
    let reward: Int
}

enum BonusObjectiveServiceError: Error, Equatable, LocalizedError {
    case invalidObjective
    case objectiveNotComplete
    case unauthorizedProfile
    case authoritativeRecordsUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidObjective:
            "This bonus objective is no longer valid."
        case .objectiveNotComplete:
            "Complete the bonus objective before claiming it."
        case .unauthorizedProfile:
            "You don't have permission to claim this bonus objective."
        case .authoritativeRecordsUnavailable:
            "Your guild data is not available yet. Please try again."
        }
    }
}

@MainActor
@Observable
final class BonusObjectiveService {
    private let cloudKitService: any CloudKitServiceProtocol

    var cacheService: CacheService?
    var appState: AppState?
    var syncCoordinator: CKSyncEngineCoordinator?

    private let inFlightClaims = Mutex<Set<String>>([])

    private static let templates: [ObjectiveTemplate] = [
        ObjectiveTemplate(type: .completeAllToday, title: "Complete All Quests", description: "Complete all of today's assigned quests", reward: 20),
        ObjectiveTemplate(type: .earlyBird, title: "Early Bird", description: "Complete your first quest before noon", reward: 15),
        ObjectiveTemplate(type: .keepStreak, title: "Keep Streak Alive", description: "Keep your streak alive today", reward: 10),
        ObjectiveTemplate(type: .completeTwoQuests, title: "Double Duty", description: "Complete at least 2 quests today", reward: 15)
    ]

    init(cloudKitService: any CloudKitServiceProtocol,
         cacheService: CacheService? = nil,
         appState: AppState? = nil,
         syncCoordinator: CKSyncEngineCoordinator? = nil)
    {
        self.cloudKitService = cloudKitService
        self.cacheService = cacheService
        self.appState = appState
        self.syncCoordinator = syncCoordinator
    }

    /// Selects the daily objective for a profile+date using a **stable,
    /// deterministic** hash. `String.hashValue` is randomized per-process
    /// (SipHash seed since Swift 4.2), so the same profile+date yielded a
    /// different objective on every launch and on every device — which minted
    /// a fresh claim key each relapse, allowing a multi-claim per day.
    /// `djb2` is a classic non-cryptographic hash with no per-process seed,
    /// so the selection is stable across launches and devices. The modulo is
    /// computed in `UInt64` before converting to `Int`, avoiding the
    /// `abs(Int.min)` runtime trap.
    func dailyObjective(for profile: Profile, date: Date = Date()) -> BonusObjective {
        let calendar = Calendar.iso8601UTC
        let dateComponents = calendar.dateComponents([.year, .month, .day], from: date)

        // Deterministic hashing based on date and profile ID
        let dateString = "\(dateComponents.year ?? 0)-\(dateComponents.month ?? 0)-\(dateComponents.day ?? 0)"
        let hashString = "\(profile.id.recordName)-\(dateString)"
        let hash = Self.djb2Hash(hashString)

        let templates = Self.templates
        let index = Int(hash % UInt64(templates.count))
        let selection = templates[index]

        return BonusObjective(
            id: "\(dateString)-\(selection.type.rawValue)",
            title: selection.title,
            description: selection.description,
            gemReward: selection.reward,
            type: selection.type
        )
    }

    func evaluateProgress(
        objective: BonusObjective,
        todayQuests: [QuestCache],
        completions: [QuestCompletionCache],
        date: Date = Date()
    ) -> (isComplete: Bool, progressText: String) {
        let calendar = Calendar.iso8601UTC
        let today = date
        let approvedCompletions = completions.filter { $0.isApproved && $0.wasCompleted(on: today) }

        switch objective.type {
        case .completeAllToday:
            let total = todayQuests.count
            if total == 0 {
                return (false, "0/0") // No quests today
            }
            let completionsByQuest = Dictionary(grouping: approvedCompletions, by: \.questRecordName)
            let completedCount = todayQuests.reduce(into: 0) { count, quest in
                if completionsByQuest[quest.recordName, default: []].count >= quest.targetCount {
                    count += 1
                }
            }
            let isComplete = completedCount >= total
            return (isComplete, "\(min(completedCount, total))/\(total)")

        case .earlyBird:
            let hasCompletedBeforeNoon = approvedCompletions.contains { completion in
                let hour = calendar.component(.hour, from: completion.completedDate)
                return hour < 12
            }
            if hasCompletedBeforeNoon {
                return (true, "1/1")
            } else {
                let currentHour = calendar.component(.hour, from: today)
                if currentHour >= 12 {
                    return (false, "Missed")
                } else {
                    return (false, "0/1")
                }
            }

        case .keepStreak:
            let completedCount = approvedCompletions.count
            let isComplete = completedCount > 0
            return (isComplete, isComplete ? "1/1" : "0/1")

        case .completeTwoQuests:
            let completedCount = Set(approvedCompletions.map(\.questRecordName)).count
            let isComplete = completedCount >= 2
            return (isComplete, "\(min(completedCount, 2))/2")
        }
    }

    func claimObjective(objective: BonusObjective, profile: Profile, gemService: GemService, soundManager: SoundManager) async throws {
        guard let appState else {
            throw BonusObjectiveServiceError.unauthorizedProfile
        }
        try ActiveFamilyScopeGuard.requireAuthenticatedActiveProfile(profile, appState: appState)
        try ActiveFamilyScopeGuard.requireActiveFamilyScope(
            familyRecordName: profile.family.recordID.recordName,
            zoneID: profile.id.zoneID,
            appState: appState,
            cloudKit: cloudKitService
        )

        guard let activeProfile = appState.currentProfile,
              let cacheService
        else {
            throw BonusObjectiveServiceError.authoritativeRecordsUnavailable
        }

        let currentUser = try await cloudKitService.currentUserRecordID()
        guard let cachedProfile = cacheService.fetchProfile(
            recordName: activeProfile.id.recordName,
            family: activeProfile.family.recordID.recordName
        ),
            cachedProfile.isActive,
            cachedProfile.iCloudUserRecordName == currentUser.recordName,
            cachedProfile.familyRecordName == activeProfile.family.recordID.recordName
        else {
            throw BonusObjectiveServiceError.unauthorizedProfile
        }

        var current = cachedProfile.toProfile(zoneID: activeProfile.id.zoneID)
        let now = Date()
        let canonicalObjective = dailyObjective(for: current, date: now)
        guard objective.id == canonicalObjective.id,
              objective.type.rawValue == canonicalObjective.type.rawValue,
              objective.gemReward == canonicalObjective.gemReward,
              objective.title == canonicalObjective.title,
              objective.description == canonicalObjective.description
        else {
            throw BonusObjectiveServiceError.invalidObjective
        }

        let claimKey = "\(current.id.recordName)-\(canonicalObjective.id)"
        let alreadyInFlight = inFlightClaims.withLock { set -> Bool in
            if set.contains(claimKey) {
                return true
            }
            set.insert(claimKey)
            return false
        }
        guard !alreadyInFlight else { return }
        defer { inFlightClaims.withLock { _ = $0.remove(claimKey) } }

        // A synced claim is already settled even when this device has not yet
        // received the completion rows that justified it.
        guard !current.claimedBonusObjectives.contains(canonicalObjective.id) else {
            return
        }

        let familyRecordName = current.family.recordID.recordName
        let payoutDay = current.payoutDay ?? appState.family?.payoutDay ?? .sunday
        let templatesByID = Dictionary(
            uniqueKeysWithValues: cacheService
                .fetchQuestTemplates(family: familyRecordName)
                .filter { $0.familyRecordName == familyRecordName }
                .map { ($0.recordName, $0) }
        )
        let todayQuests = cacheService
            .fetchQuests(family: familyRecordName)
            .filter {
                $0.familyRecordName == familyRecordName
                    && $0.assigneeRecordName == current.id.recordName
                    && $0.isScheduled(
                        on: now,
                        template: templatesByID[$0.templateRecordName],
                        payoutDay: payoutDay
                    )
            }
        let todayQuestIDs = Set(todayQuests.map(\.recordName))
        let completions = cacheService
            .fetchQuestCompletions(family: familyRecordName)
            .filter {
                $0.familyRecordName == familyRecordName
                    && $0.completerRecordName == current.id.recordName
                    && todayQuestIDs.contains($0.questRecordName)
                    && $0.isApproved
                    && $0.wasCompleted(on: now)
            }
        let progress = evaluateProgress(
            objective: canonicalObjective,
            todayQuests: todayQuests,
            completions: completions,
            date: now
        )
        guard progress.isComplete else {
            throw BonusObjectiveServiceError.objectiveNotComplete
        }

        // Stamp the claim on the Profile BEFORE crediting gems so the single
        // upsert inside `GemService.creditGems` carries both the gem increment
        // and the new claim marker (avoids a follow-up upsert overwriting the
        // freshly-credited gemsTotal).
        current.claimedBonusObjectives.append(canonicalObjective.id)

        // Award gems — upserts the profile (with the claimed marker) + enqueues
        // the Profile record for CloudKit sync. The deterministic `eventKey`
        // (`bonus-{objective.id}`) derives an idempotent ledger ID so a
        // cross-device re-claim collapsed by sync can never credit the reward
        // twice — mirroring the `reward-{completionID}` RewardEvent pattern.
        try await gemService.creditGems(
            amount: canonicalObjective.gemReward,
            to: current,
            source: "bonusObjective",
            eventKey: "bonus-\(canonicalObjective.id)",
            detail: canonicalObjective.title
        )

        // Re-resolve the authoritative profile from cache so the session
        // reflects the freshly-credited gems. Assigning the stale
        // `current` copy here would overwrite the `gems` updated inside
        // `creditGems` (which upserted the profile with the new ledger
        // sum) with the pre-credit value.
        if let active = appState.currentProfile, active.id == current.id {
            if let refreshed = cacheService.fetchProfile(recordName: current.id.recordName, family: current.family.recordID.recordName)?.toProfile(zoneID: current.id.zoneID) {
                appState.currentProfile = refreshed
            }
        }

        // Play sound
        soundManager.play(.gemEarned)
    }

    func isClaimed(objective: BonusObjective, profile: Profile) -> Bool {
        let current = resolvedProfile(profile) ?? profile
        return current.claimedBonusObjectives.contains(objective.id)
    }

    // MARK: - Profile resolution

    private func resolvedProfile(_ profile: Profile) -> Profile? {
        guard let cacheService else { return nil }
        let familyRecordName = appState?.family?.id.recordName ?? profile.family.recordID.recordName
        guard let cached = cacheService.fetchProfile(recordName: profile.id.recordName, family: familyRecordName) else { return nil }
        return cached.toProfile(zoneID: profile.id.zoneID)
    }

    /// Stable, non-cryptographic djb2 hash (Bernstein). Deterministic across
    /// process launches and devices — no SipHash per-process seed.
    private static func djb2Hash(_ string: String) -> UInt64 {
        var hash: UInt64 = 5381
        for byte in string.utf8 {
            hash = (hash &<< 5) &+ hash &+ UInt64(byte)
        }
        return hash
    }
}

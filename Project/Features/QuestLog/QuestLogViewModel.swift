//
//  QuestLogViewModel.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
import Observation

@MainActor
@Observable
final class QuestLogViewModel {
    var displayedQuests: [QuestLogRow] = []
    var selectedHero: Profile? { // nil = all heroes
        didSet { applyFilters() }
    }

    var dateRangePreset: DateRangePreset = .allTime {
        didSet { applyFilters() }
    }

    var completionFilter: CompletionFilter = .all {
        didSet { applyFilters() }
    }

    var isLoading: Bool = false

    private let questService: QuestService
    private let familyService: FamilyService
    private let appState: AppState

    private var syncSubscriptionID: UUID?
    private var syncTask: Task<Void, Never>?

    /// All profiles (active + inactive) for name resolution
    private var allProfiles: [Profile] = []
    /// Quick lookup by record ID
    private var profileByID: [CKRecord.ID: Profile] = [:]

    /// In-memory cache of raw CloudKit data for instant filter switching
    private var rawQuests: [Quest] = []
    private var rawCompletionsByQuest: [String: [QuestCompletion]] = [:]

    /// Heroes available for filtering (active profiles with role == .hero).
    var availableHeroes: [Profile] {
        allProfiles.filter { $0.role == .hero }
    }

    init(questService: QuestService, familyService: FamilyService, appState: AppState) {
        self.questService = questService
        self.familyService = familyService
        self.appState = appState
    }

    func subscribeToSyncEvents(_ coordinator: AppSyncCoordinator) {
        guard syncSubscriptionID == nil else { return }
        let (stream, id) = coordinator.subscribe()
        syncSubscriptionID = id
        syncTask = Task { [weak self] in
            for await _ in stream {
                guard let self else { return }
                guard let family = appState.family else { return }
                await load(family: family)
            }
        }
    }

    func unsubscribeFromSyncEvents(_ coordinator: AppSyncCoordinator) {
        syncTask?.cancel()
        syncTask = nil
        if let id = syncSubscriptionID {
            coordinator.unsubscribe(id: id)
            syncSubscriptionID = nil
        }
    }

    // MARK: - Types

    enum DateRangePreset: String, CaseIterable, Identifiable {
        case thisWeek = "This Week"
        case thisMonth = "This Month"
        case thisQuarter = "This Quarter"
        case allTime = "All Time"
        var id: String {
            rawValue
        }

        var dateRange: ClosedRange<Date>? {
            let calendar = Calendar.iso8601UTC
            let now = Date()
            switch self {
            case .thisWeek:
                let start = calendar.date(
                    from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
                ) ?? now
                return start ... now
            case .thisMonth:
                let start = calendar.date(
                    from: calendar.dateComponents([.year, .month], from: now)
                ) ?? now
                return start ... now
            case .thisQuarter:
                let month = calendar.component(.month, from: now)
                let quarterStartMonth = ((month - 1) / 3) * 3 + 1
                var comps = calendar.dateComponents([.year], from: now)
                comps.month = quarterStartMonth
                comps.day = 1
                let start = calendar.date(from: comps) ?? now
                return start ... now
            case .allTime:
                return nil
            }
        }
    }

    enum CompletionFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case completed = "Completed"
        case incomplete = "Incomplete"
        var id: String {
            rawValue
        }
    }

    struct QuestLogRow: Identifiable {
        var id: CKRecord.ID {
            quest.id
        }

        let quest: Quest
        let heroName: String
        let heroIsActive: Bool
        let completionStatus: CompletionStatus
    }

    enum CompletionStatus: Equatable {
        case notStarted
        case pending
        case completed
        case rejected
    }

    // MARK: - Load & Filter

    func load(family: Family) async {
        if rawQuests.isEmpty {
            isLoading = true
        }
        defer { isLoading = false }

        // Fetch ALL profiles (active + inactive) for name resolution
        allProfiles = await (try? familyService.fetchAllProfilesForFamily(family)) ?? []
        profileByID = Dictionary(uniqueKeysWithValues: allProfiles.map { ($0.id, $0) })

        // Fetch quests across all weeks
        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let predicate = NSPredicate(format: "family == %@", familyRef)
        rawQuests = await (try? questService.cloudKitReference.query(
            Quest.self, predicate: predicate
        )) ?? []

        // Single batch fetch for ALL quest completions in the family
        let allCompletions = await (try? questService.fetchQuestCompletionsForFamily(family: family)) ?? []

        rebuildLists(quests: rawQuests, logs: allCompletions)
    }

    func rebuildLists(quests: [Quest], logs: [QuestCompletion]) {
        rawQuests = quests
        var completionsMap: [String: [QuestCompletion]] = [:]
        for completion in logs {
            let questName = completion.quest.recordID.recordName
            completionsMap[questName, default: []].append(completion)
        }
        rawCompletionsByQuest = completionsMap

        applyFilters()
    }

    func applyFilters() {
        let range = dateRangePreset.dateRange
        let filteredByDate: [Quest] = if let range {
            rawQuests.filter { range.contains($0.weekOf) }
        } else {
            rawQuests
        }

        let filteredByHero: [Quest] = if let selectedHero {
            filteredByDate.filter {
                $0.assignee.recordID == selectedHero.id
            }
        } else {
            filteredByDate
        }

        var rows: [QuestLogRow] = []
        for quest in filteredByHero {
            let hero = profileByID[quest.assignee.recordID]
            let heroName = hero?.displayName ?? "Unknown Hero"
            let heroIsActive = hero?.isActive ?? false

            let logs = rawCompletionsByQuest[quest.id.recordName] ?? []
            let status: CompletionStatus = if logs.isEmpty {
                .notStarted
            } else if logs.contains(where: {
                $0.verificationStatus == .verified || $0.verificationStatus == .autoApproved
            }) {
                .completed
            } else if logs.contains(where: { $0.verificationStatus == .rejected }) {
                .rejected
            } else {
                .pending
            }

            switch completionFilter {
            case .all:
                break
            case .completed where status != .completed:
                continue
            case .incomplete where status == .completed:
                continue
            default:
                break
            }

            if !heroIsActive, appState.currentProfile?.role != .guildMaster {
                continue
            }

            rows.append(QuestLogRow(
                quest: quest,
                heroName: heroName,
                heroIsActive: heroIsActive,
                completionStatus: status
            ))
        }

        rows.sort { lhs, rhs in
            if lhs.quest.weekOf != rhs.quest.weekOf {
                return lhs.quest.weekOf > rhs.quest.weekOf
            }
            return lhs.heroName.localizedCaseInsensitiveCompare(rhs.heroName) == .orderedAscending
        }

        displayedQuests = rows
    }
}

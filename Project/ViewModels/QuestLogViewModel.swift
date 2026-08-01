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
    var selectedHero: ProfileCache? { // nil = all heroes
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

    private var allProfiles: [ProfileCache] = []
    private var profileByName: [String: ProfileCache] = [:]

    private var rawQuests: [QuestCache] = []
    private var rawCompletionsByQuest: [String: [QuestCompletionCache]] = [:]

    var availableHeroes: [ProfileCache] {
        allProfiles.filter { $0.roleEnum == .hero }
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
        syncTask = Task {
            for await _ in stream {
                // view's `@Query *.Cache` re-fires `.onChange` → `rebuildLists`.
                // No explicit `load(family:)` here — that would duplicate the
                // `.onChange` path and could diverge on edge rows.
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
        case all = "All Quests"
        case completed = "Completed Only"
        case incomplete = "Unfinished"
        var id: String {
            rawValue
        }
    }

    struct QuestLogRow: Identifiable, Equatable {
        var id: String {
            quest.recordName
        }

        let quest: QuestCache
        let heroName: String
        let heroIsActive: Bool
        let completionStatus: CompletionStatus
        let approvedCount: Int
        let targetCount: Int
        let logs: [QuestCompletionCache]
    }

    enum CompletionStatus: Equatable {
        case notStarted
        case pending
        case inProgress(completedCount: Int, targetCount: Int)
        case completed
        case rejected
    }

    // MARK: - Load & Filter

    func rebuildLists(profiles: [ProfileCache] = [], quests: [QuestCache], logs: [QuestCompletionCache]) {
        if !profiles.isEmpty {
            allProfiles = profiles
            profileByName = Dictionary(uniqueKeysWithValues: profiles.map { ($0.recordName, $0) })
        }
        rawQuests = quests

        var completionsMap: [String: [QuestCompletionCache]] = [:]
        for completion in logs {
            let qName = completion.questRecordName
            completionsMap[qName, default: []].append(completion)
        }
        rawCompletionsByQuest = completionsMap

        applyFilters()
    }

    func applyFilters() {
        let range = dateRangePreset.dateRange
        let filteredByDate: [QuestCache] = if let range {
            rawQuests.filter { range.contains($0.weekOf) }
        } else {
            rawQuests
        }

        let filteredByHero: [QuestCache] = if let selectedHero {
            filteredByDate.filter {
                $0.assigneeRecordName == selectedHero.recordName
            }
        } else {
            filteredByDate
        }

        var rows: [QuestLogRow] = []
        for quest in filteredByHero {
            let hero = profileByName[quest.assigneeRecordName]
            let heroName = hero?.displayName ?? "Unknown Hero"
            let heroIsActive = hero?.isActive ?? false

            let logs = rawCompletionsByQuest[quest.recordName] ?? []
            let approvedLogs = logs.filter {
                $0.verificationStatusEnum == .verified || $0.verificationStatusEnum == .autoApproved
            }
            let target = max(1, quest.targetCount)

            let hasRejectedLog = logs.contains {
                $0.verificationStatusEnum == .rejected
            }

            let status: CompletionStatus = if logs.isEmpty {
                .notStarted
            } else if approvedLogs.count >= target {
                .completed
            } else if hasRejectedLog {
                .rejected
            } else if approvedLogs.count > 0 {
                .inProgress(completedCount: approvedLogs.count, targetCount: target)
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
                completionStatus: status,
                approvedCount: approvedLogs.count,
                targetCount: target,
                logs: logs
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

//
//  QuestLogViewModel.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import Foundation
import Observation

@MainActor
@Observable
final class QuestLogViewModel {
    private(set) var displayedQuests: [QuestLogRow] = []
    var selectedHero: ProfileCache? { // nil = all heroes
        didSet { applyFilters() }
    }

    var dateRangePreset: DateRangePreset = .allTime {
        didSet { applyFilters() }
    }

    var completionFilter: CompletionFilter = .all {
        didSet { applyFilters() }
    }

    private(set) var isLoading: Bool = false

    private let questService: QuestService
    private let familyService: FamilyService
    private let appState: AppState

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

    // MARK: - Types

    /// Date-range filter sharing CalendarScope semantics with treasury and ledger.
    typealias DateRangePreset = CalendarScope

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
        let familyPayoutDay = appState.family?.payoutDay ?? .sunday
        let effectivePayoutDay = selectedHero?.payoutDayEnum ?? familyPayoutDay
        let filteredByDate = rawQuests.filter { dateRangePreset.contains($0.weekOf, payoutDay: effectivePayoutDay) }

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
                $0.verificationStatusEnum == .rejected || $0.verificationStatusEnum == .withdrawn
            }

            let status: CompletionStatus = if logs.isEmpty {
                .notStarted
            } else if GoldCalculation.isFullyCompleted(quest: quest, approvedCount: approvedLogs.count) {
                .completed
            } else if approvedLogs.count > 0 {
                .inProgress(completedCount: approvedLogs.count, targetCount: target)
            } else if hasRejectedLog {
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

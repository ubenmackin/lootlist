//
//  QuestService.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation

enum QuestServiceError: Error, Equatable, Sendable {
    case missingSession

    case alreadyCompleted

    case alreadyResolved(String)

    case missingRecord(String)
}

@MainActor
@Observable
final class QuestService {
    let cloudKit: CloudKitService

    private let xpService: XPService
    let notificationService: NotificationService?

    var cacheService: CacheService?

    var cloudKitReference: CloudKitService {
        cloudKit
    }

    private let calendar: Calendar = .iso8601UTC

    init(cloudKit: CloudKitService,
         xpService: XPService,
         notificationService: NotificationService? = nil)
    {
        self.cloudKit = cloudKit
        self.xpService = xpService
        self.notificationService = notificationService
    }

    convenience init(cloudKit: CloudKitService) {
        self.init(cloudKit: cloudKit, xpService: XPService(cloudKit: cloudKit))
    }

    @discardableResult
    func createTemplate(name: String,
                        description: String,
                        defaultGold: Double,
                        xpReward: Int,
                        schedule: QuestSchedule,
                        specificDays: [String] = [],
                        isAllOrNothing: Bool = false,
                        approvalMode: ApprovalMode = .autoApprove,
                        createdBy: Profile,
                        family: Family) async throws -> QuestTemplate
    {
        let template = QuestTemplate(
            name: name,
            description: description,
            defaultGold: defaultGold,
            xpReward: xpReward,
            scheduleType: schedule,
            specificDays: schedule.requiresSpecificDays ? specificDays : [],
            isAllOrNothing: isAllOrNothing,
            approvalMode: approvalMode,
            createdBy: CKRecord.Reference(recordID: createdBy.id, action: .none),
            family: CKRecord.Reference(recordID: family.id, action: .none)
        )
        let saved = try await cloudKit.save(template)
        cacheService?.upsertQuestTemplate(saved)
        return saved
    }

    @discardableResult
    func updateTemplate(_ template: QuestTemplate) async throws -> QuestTemplate {
        let name = template.id.recordName
        let snapshot = cacheService?.fetchQuestTemplates(family: template.family.recordID.recordName).first(where: { $0.recordName == name })

        cacheService?.upsertQuestTemplate(template)
        do {
            let saved = try await cloudKit.save(template)
            cacheService?.upsertQuestTemplate(saved)
            return saved
        } catch {
            if let snapshot {
                cacheService?.upsertQuestTemplate(snapshot.toQuestTemplate(zoneID: cloudKit.resolvedZoneID))
            } else {
                cacheService?.invalidateQuestTemplate(recordName: name)
            }
            throw error
        }
    }

    @discardableResult
    func deactivateTemplate(_ template: QuestTemplate) async throws -> QuestTemplate {
        var deactivated = template
        deactivated.isActive = false

        let name = template.id.recordName
        let snapshot = cacheService?.fetchQuestTemplates(family: template.family.recordID.recordName).first(where: { $0.recordName == name })

        cacheService?.upsertQuestTemplate(deactivated)
        do {
            let saved = try await cloudKit.save(deactivated)
            cacheService?.upsertQuestTemplate(saved)
            return saved
        } catch {
            if let snapshot {
                cacheService?.upsertQuestTemplate(snapshot.toQuestTemplate(zoneID: cloudKit.resolvedZoneID))
            }
            throw error
        }
    }

    func fetchTemplates(family: Family) async throws -> [QuestTemplate] {
        if let cache = cacheService {
            let familyName = family.id.recordName
            let cached = cache.fetchQuestTemplates(family: familyName)
            if !cached.isEmpty {
                Task { [cloudKit, cacheService] in
                    let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
                    let predicate = NSPredicate(format: "family == %@", familyRef)
                    if let fresh = try? await cloudKit.query(QuestTemplate.self, predicate: predicate) {
                        cacheService?.upsertQuestTemplates(fresh)
                    }
                }
                return cached.map { $0.toQuestTemplate(zoneID: cloudKit.resolvedZoneID) }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
        }

        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let predicate = NSPredicate(format: "family == %@", familyRef)
        let all = try await cloudKit.query(QuestTemplate.self, predicate: predicate)
        cacheService?.upsertQuestTemplates(all)
        return all
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    func assignQuest(template: QuestTemplate,
                     assignee: Profile,
                     goldOverride: Double? = nil,
                     xpOverride: Int? = nil,
                     approvalOverride: ApprovalMode? = nil,
                     nameOverride: String? = nil,
                     weekOf: Date,
                     createdBy: Profile,
                     family: Family) async throws -> Quest
    {
        let normalizedWeek = QuestService.mondayOfWeek(for: weekOf)
        let questName = nameOverride.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            ?? template.name
        let quest = Quest(
            template: CKRecord.Reference(recordID: template.id, action: .none),
            assignee: CKRecord.Reference(recordID: assignee.id, action: .none),
            goldReward: goldOverride ?? template.defaultGold,
            xpReward: xpOverride ?? template.xpReward,
            scheduleType: template.scheduleType,
            isAllOrNothing: template.isAllOrNothing,
            approvalMode: approvalOverride ?? template.approvalMode,
            weekOf: normalizedWeek,
            createdBy: CKRecord.Reference(recordID: createdBy.id, action: .none),
            family: CKRecord.Reference(recordID: family.id, action: .none),
            name: questName,
            descriptionText: template.description
        )
        // Optimistic local write first
        cacheService?.upsertQuest(quest)

        let saved = try await cloudKit.save(quest)
        cacheService?.upsertQuest(saved)
        if let notificationService {
            Task { @Sendable in
                try? await notificationService.send(
                    .questAssigned,
                    to: assignee,
                    title: "⚔️ New Quest Assigned!",
                    body: "You have been assigned '\(questName)'."
                )
            }
        }
        return saved
    }

    @discardableResult
    func updateQuest(_ quest: Quest) async throws -> Quest {
        cacheService?.upsertQuest(quest)
        let saved = try await cloudKit.save(quest)
        cacheService?.upsertQuest(saved)
        return saved
    }

    @discardableResult
    func assignQuickQuest(name: String,
                          description: String = "",
                          assignee: Profile,
                          goldReward: Double,
                          xpReward: Int,
                          scheduleType: QuestSchedule = .weeklyFlexible,
                          specificDays: [String] = [],
                          approvalMode: ApprovalMode = .autoApprove,
                          weekOf: Date,
                          createdBy: Profile,
                          family: Family) async throws -> Quest
    {
        // Generate ad-hoc inactive template so it doesn't clutter routine template list
        let adhocTemplate = try await createTemplate(
            name: name,
            description: description,
            defaultGold: goldReward,
            xpReward: xpReward,
            schedule: scheduleType,
            specificDays: specificDays,
            approvalMode: approvalMode,
            createdBy: createdBy,
            family: family
        )
        _ = try await deactivateTemplate(adhocTemplate)

        let normalizedWeek = QuestService.mondayOfWeek(for: weekOf)
        let quest = Quest(
            template: CKRecord.Reference(recordID: adhocTemplate.id, action: .none),
            assignee: CKRecord.Reference(recordID: assignee.id, action: .none),
            goldReward: goldReward,
            xpReward: xpReward,
            scheduleType: scheduleType,
            isAllOrNothing: false,
            approvalMode: approvalMode,
            weekOf: normalizedWeek,
            createdBy: CKRecord.Reference(recordID: createdBy.id, action: .none),
            family: CKRecord.Reference(recordID: family.id, action: .none),
            name: name,
            descriptionText: description
        )
        cacheService?.upsertQuest(quest)
        let saved = try await cloudKit.save(quest)
        cacheService?.upsertQuest(saved)
        if let notificationService {
            Task { @Sendable in
                try? await notificationService.send(
                    .questAssigned,
                    to: assignee,
                    title: "⚔️ New Quest Assigned!",
                    body: "You have been assigned '\(name)'."
                )
            }
        }
        return saved
    }

    func unassignQuest(_ quest: Quest) async throws {
        cacheService?.invalidateQuest(recordName: quest.id.recordName)
        try await cloudKit.delete(quest.id)
    }

    func fetchActiveQuests(profile: Profile, weekOf: Date) async throws -> [Quest] {
        let range = QuestService.weekRange(for: weekOf)

        // Cache-first: check local cache
        if let cache = cacheService {
            let profileName = profile.id.recordName
            let familyName = profile.family.recordID.recordName
            let cached = cache.fetchQuests(family: familyName, weekInRange: range)
                .filter { $0.assigneeRecordName == profileName && $0.isActive }
            if !cached.isEmpty {
                // Background refresh
                Task { [cloudKit, cacheService] in
                    let assigneeRef = CKRecord.Reference(recordID: profile.id, action: .none)
                    let predicate = NSPredicate(format: "assignee == %@", assigneeRef)
                    if let fresh = try? await cloudKit.query(Quest.self, predicate: predicate) {
                        cacheService?.upsertQuests(fresh)
                    }
                }
                let cachedQuests = cached.map { $0.toQuest(zoneID: cloudKit.resolvedZoneID) }
                var stamped: [Quest] = []
                for quest in cachedQuests {
                    await stamped.append(stampNameIfNeeded(quest))
                }
                return stamped
            }
        }

        let assigneeRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let predicate = NSPredicate(format: "assignee == %@", assigneeRef)
        let all = try await cloudKit.query(Quest.self, predicate: predicate)
        let stampedAll = await stampAllQuests(all)
        cacheService?.upsertQuests(stampedAll)
        return stampedAll
            .filter { $0.active && range.contains($0.weekOf) }
            .sorted { $0.template.recordID.recordName < $1.template.recordID.recordName }
    }

    func fetchQuestsForFamilyWeek(family: Family, weekOf: Date) async throws -> [Quest] {
        let range = QuestService.weekRange(for: weekOf)

        if let cache = cacheService {
            let familyName = family.id.recordName
            let cached = cache.fetchQuests(family: familyName, weekInRange: range)
                .filter(\.isActive)
            if !cached.isEmpty {
                Task { [cloudKit, cacheService] in
                    let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
                    let predicate = NSPredicate(format: "family == %@", familyRef)
                    if let fresh = try? await cloudKit.query(Quest.self, predicate: predicate) {
                        cacheService?.upsertQuests(fresh)
                    }
                }
                let cachedQuests = cached.map { $0.toQuest(zoneID: cloudKit.resolvedZoneID) }
                var stamped: [Quest] = []
                for quest in cachedQuests {
                    await stamped.append(stampNameIfNeeded(quest))
                }
                return stamped
            }
        }

        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let predicate = NSPredicate(format: "family == %@", familyRef)
        let all = try await cloudKit.query(Quest.self, predicate: predicate)
        let stampedAll = await stampAllQuests(all)
        cacheService?.upsertQuests(stampedAll)
        return stampedAll
            .filter { $0.active && range.contains($0.weekOf) }
            .sorted { $0.assignee.recordID.recordName < $1.assignee.recordID.recordName }
    }

    @discardableResult
    func markComplete(quest: Quest, by profile: Profile, at completedDate: Date = Date()) async throws -> QuestCompletion {
        // Correctness gate: must read from CloudKit (not stale cache) to prevent
        // duplicate completions / false "alreadyCompleted". A stale cached pending
        // log could falsely throw alreadyCompleted, and a stale cached empty set
        // could allow a duplicate completion. See `fetchQuestLogs(forQuest:useCache:)` docs.
        let existingLogs = await (try? fetchQuestLogs(forQuest: quest, useCache: false)) ?? []
        if existingLogs.contains(where: { $0.verificationStatus != .rejected }) {
            throw QuestServiceError.alreadyCompleted
        }

        let log = QuestCompletion(
            quest: CKRecord.Reference(recordID: quest.id, action: .none),
            completedBy: CKRecord.Reference(recordID: profile.id, action: .none),
            approvalMode: quest.approvalMode,
            weekOf: quest.weekOf,
            family: quest.family
        )

        var editable = log
        editable.completedDate = completedDate

        // Optimistic local write first
        cacheService?.upsertQuestCompletion(editable)

        let saved = try await cloudKit.save(editable)
        cacheService?.upsertQuestCompletion(saved)

        switch quest.approvalMode {
        case .autoApprove:
            await applyReward(for: quest, to: profile)
        case .parentVerify:
            if let notificationService,
               let parent = try? await cloudKit.fetch(Profile.self, id: quest.createdBy.recordID)
            {
                Task { @Sendable in
                    try? await notificationService.sendQuestNeedsReview(questLog: saved, to: parent)
                }
            }
        }

        return saved
    }

    @discardableResult
    func verify(questLog: QuestCompletion, by parent: Profile) async throws -> QuestCompletion {
        guard questLog.verificationStatus == .pending else {
            throw QuestServiceError.alreadyResolved(questLog.verificationStatus.rawValue)
        }

        var updated = questLog
        updated.verificationStatus = .verified
        updated.verifiedBy = CKRecord.Reference(recordID: parent.id, action: .none)
        updated.verifiedDate = Date()

        let name = questLog.id.recordName
        let snapshot = cacheService?.fetchQuestCompletions(family: questLog.family.recordID.recordName).first(where: { $0.recordName == name })

        cacheService?.upsertQuestCompletion(updated)
        do {
            let saved = try await cloudKit.save(updated)
            cacheService?.upsertQuestCompletion(saved)

            let quest = try await cloudKit.fetch(Quest.self, id: questLog.quest.recordID)
            let hero = try await cloudKit.fetch(Profile.self, id: questLog.completedBy.recordID)
            await applyReward(for: quest, to: hero)

            if let notificationService {
                Task { @Sendable in
                    try? await notificationService.send(
                        .questCompleted,
                        to: hero,
                        title: "🏆 Quest Verified!",
                        body: "Your quest was verified! You earned \(quest.goldReward) gold."
                    )
                }
            }

            return saved
        } catch {
            if let snapshot {
                cacheService?.upsertQuestCompletion(snapshot.toQuestCompletion(zoneID: cloudKit.resolvedZoneID))
            } else {
                cacheService?.invalidateQuestCompletion(recordName: name)
            }
            throw error
        }
    }

    @discardableResult
    func reject(questLog: QuestCompletion, by parent: Profile) async throws -> QuestCompletion {
        guard questLog.verificationStatus == .pending else {
            throw QuestServiceError.alreadyResolved(questLog.verificationStatus.rawValue)
        }

        var updated = questLog
        updated.verificationStatus = .rejected
        updated.verifiedBy = CKRecord.Reference(recordID: parent.id, action: .none)
        updated.verifiedDate = Date()

        let name = questLog.id.recordName
        let snapshot = cacheService?.fetchQuestCompletions(family: questLog.family.recordID.recordName).first(where: { $0.recordName == name })

        cacheService?.upsertQuestCompletion(updated)
        do {
            let saved = try await cloudKit.save(updated)
            cacheService?.upsertQuestCompletion(saved)
            return saved
        } catch {
            if let snapshot {
                cacheService?.upsertQuestCompletion(snapshot.toQuestCompletion(zoneID: cloudKit.resolvedZoneID))
            } else {
                cacheService?.invalidateQuestCompletion(recordName: name)
            }
            throw error
        }
    }

    func generateWeeklyQuests(family: Family,
                              weekOf: Date,
                              createdBy: Profile,
                              heroes: [Profile]) async throws
    {
        let normalizedWeek = QuestService.mondayOfWeek(for: weekOf)

        let templates = try await fetchTemplates(family: family).filter(\.isActive)
        guard !templates.isEmpty, !heroes.isEmpty else { return }

        let existing = try await fetchQuestsForFamilyWeek(family: family, weekOf: normalizedWeek)
        var existingKeys: Set<String> = []
        for quest in existing {
            existingKeys.insert("\(quest.template.recordID.recordName)|\(quest.assignee.recordID.recordName)")
        }

        let weekWeekdayCodes = weekdayCodes(inWeekOf: normalizedWeek)

        for template in templates {
            let scheduleMatches: Bool = switch template.scheduleType {
            case .specificDays:
                !template.specificDays.isEmpty
                    && !Set(template.specificDays).isDisjoint(with: weekWeekdayCodes)
            case .weeklyFlexible:
                true
            }

            guard scheduleMatches else { continue }

            for hero in heroes {
                let key = "\(template.id.recordName)|\(hero.id.recordName)"
                guard !existingKeys.contains(key) else { continue }

                _ = try await assignQuest(
                    template: template,
                    assignee: hero,
                    weekOf: normalizedWeek,
                    createdBy: createdBy,
                    family: family
                )
                existingKeys.insert(key)
            }
        }
    }

    func fetchStreak(for profile: Profile) async throws -> Int {
        let logs = try await fetchQuestLogs(for: profile)
        guard !logs.isEmpty else { return 0 }

        var daySet: Set<Date> = []
        for log in logs where log.verificationStatus == .autoApproved
            || log.verificationStatus == .verified
        {
            if let day = calendar.dateInterval(of: .day, for: log.completedDate)?.start {
                daySet.insert(day)
            }
        }

        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let anchor = daySet.contains(today) ? today
            : (daySet.contains(yesterday) ? yesterday : nil)
        guard let anchor else { return 0 }

        var streak = 0
        var cursor = anchor

        while daySet.contains(cursor) {
            streak += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }
        return streak
    }

    func earnedThisWeek(profile: Profile, weekOf: Date) async throws -> Double {
        let normalizedWeek = QuestService.mondayOfWeek(for: weekOf)
        let logs = try await fetchQuestLogs(for: profile)
            .filter { $0.weekOf == normalizedWeek
                && ($0.verificationStatus == .autoApproved
                    || $0.verificationStatus == .verified)
            }

        guard !logs.isEmpty else { return 0 }

        let questIDs = Array(Set(logs.map(\.quest.recordID)))
        var questMap: [CKRecord.ID: Quest] = [:]

        // Cache-first: build a lookup dictionary from the family's cached
        // quests.  Only quest IDs absent from the cache fall through to the
        // per-ID CloudKit fetch below (genuine cache miss).
        if let cache = cacheService,
           let familyName = logs.first?.family.recordID.recordName
        {
            let zoneID = cloudKit.resolvedZoneID
            for row in cache.fetchQuests(family: familyName) {
                let quest = row.toQuest(zoneID: zoneID)
                questMap[quest.id] = quest
            }
        }

        let missingIDs = questIDs.filter { questMap[$0] == nil }

        // CK fallback ONLY for cache-miss IDs (gracefully skipping deleted/missing quests).
        for questID in missingIDs {
            if let fetched = try? await cloudKit.fetch(Quest.self, id: questID) {
                questMap[questID] = fetched
            }
        }

        var total: Double = 0
        for log in logs {
            if let quest = questMap[log.quest.recordID] {
                total += quest.goldReward
            }
        }
        return total
    }

    func fetchQuestLogs(forQuest quest: Quest, useCache: Bool = true) async throws -> [QuestCompletion] {
        if useCache, let cache = cacheService {
            let questName = quest.id.recordName
            let cached = cache.fetchQuestCompletions(family: quest.family.recordID.recordName)
                .filter { $0.questRecordName == questName }
            if !cached.isEmpty {
                Task { [cloudKit, cacheService] in
                    let questRef = CKRecord.Reference(recordID: quest.id, action: .none)
                    let predicate = NSPredicate(format: "quest == %@", questRef)
                    if let fresh = try? await cloudKit.query(
                        QuestCompletion.self,
                        predicate: predicate,
                        sortDescriptors: [NSSortDescriptor(key: "completedDate", ascending: false)]
                    ) {
                        cacheService?.upsertQuestCompletions(fresh)
                    }
                }
                return cached.map { $0.toQuestCompletion(zoneID: cloudKit.resolvedZoneID) }
                    .sorted { $0.completedDate > $1.completedDate }
            }
        }

        let questRef = CKRecord.Reference(recordID: quest.id, action: .none)
        let predicate = NSPredicate(format: "quest == %@", questRef)
        let all = try await cloudKit.query(
            QuestCompletion.self,
            predicate: predicate,
            sortDescriptors: [NSSortDescriptor(key: "completedDate", ascending: false)]
        )
        cacheService?.upsertQuestCompletions(all)
        return all
    }

    func fetchQuestLogs(for profile: Profile) async throws -> [QuestCompletion] {
        if let cache = cacheService {
            let profileName = profile.id.recordName
            let cached = cache.fetchQuestCompletions(family: profile.family.recordID.recordName)
                .filter { $0.completerRecordName == profileName }
            if !cached.isEmpty {
                Task { [cloudKit, cacheService] in
                    let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
                    let predicate = NSPredicate(format: "completedBy == %@", profileRef)
                    if let fresh = try? await cloudKit.query(
                        QuestCompletion.self,
                        predicate: predicate,
                        sortDescriptors: [NSSortDescriptor(key: "completedDate", ascending: false)]
                    ) {
                        cacheService?.upsertQuestCompletions(fresh)
                    }
                }
                return cached.map { $0.toQuestCompletion(zoneID: cloudKit.resolvedZoneID) }
                    .sorted { $0.completedDate > $1.completedDate }
            }
        }

        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let predicate = NSPredicate(format: "completedBy == %@", profileRef)
        let all = try await cloudKit.query(
            QuestCompletion.self,
            predicate: predicate,
            sortDescriptors: [NSSortDescriptor(key: "completedDate", ascending: false)]
        )
        cacheService?.upsertQuestCompletions(all)
        return all
    }

    // MARK: - Batch Fetch

    func fetchQuestCompletionsForFamily(family: Family) async throws -> [QuestCompletion] {
        if let cache = cacheService {
            let familyName = family.id.recordName
            let cached = cache.fetchQuestCompletions(family: familyName)
            if !cached.isEmpty {
                let zoneID = cloudKit.resolvedZoneID
                Task { [cloudKit, cacheService] in
                    let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
                    let predicate = NSPredicate(format: "family == %@", familyRef)
                    if let completions = try? await cloudKit.query(
                        QuestCompletion.self,
                        predicate: predicate,
                        sortDescriptors: [NSSortDescriptor(key: "completedDate", ascending: false)]
                    ) {
                        cacheService?.upsertQuestCompletions(completions, family: familyName)
                    }
                }
                return cached.map { $0.toQuestCompletion(zoneID: zoneID) }
            }
        }

        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let predicate = NSPredicate(format: "family == %@", familyRef)
        let completions = try await cloudKit.query(
            QuestCompletion.self,
            predicate: predicate,
            sortDescriptors: [NSSortDescriptor(key: "completedDate", ascending: false)]
        )
        cacheService?.upsertQuestCompletions(completions, family: family.id.recordName)
        return completions
    }

    private func fetchFamily(for reference: CKRecord.Reference) async throws -> Family {
        try await cloudKit.fetch(Family.self, id: reference.recordID)
    }

    private func stampNameIfNeeded(_ quest: Quest) async -> Quest {
        guard quest.name == nil else { return quest }
        guard let template = try? await cloudKit.fetch(QuestTemplate.self, id: quest.template.recordID) else {
            return quest
        }
        var updated = quest
        updated.name = template.name
        cacheService?.upsertQuest(updated)
        return updated
    }

    private func stampAllQuests(_ quests: [Quest]) async -> [Quest] {
        var stamped: [Quest] = []
        stamped.reserveCapacity(quests.count)
        for quest in quests {
            await stamped.append(stampNameIfNeeded(quest))
        }
        return stamped
    }

    private func applyReward(for quest: Quest, to hero: Profile) async {
        _ = try? await xpService.addXP(quest.xpReward, to: hero)
    }

    static func mondayOfWeek(for date: Date) -> Date {
        WeekMath.mondayOfWeek(for: date)
    }

    static func weekRange(for date: Date) -> Range<Date> {
        WeekMath.weekRange(starting: mondayOfWeek(for: date))
    }

    private func weekdayCodes(inWeekOf weekOf: Date) -> Set<String> {
        let codes = AppConstants.weekdayCodes
        var found: Set<String> = []
        for offset in 0 ..< 7 {
            let day = calendar.date(
                byAdding: .day, value: offset, to: weekOf
            ) ?? weekOf

            let weekday = calendar.component(.weekday, from: day)
            let index = max(0, min(codes.count - 1, weekday - 1))
            found.insert(codes[index])
        }
        return found
    }
}

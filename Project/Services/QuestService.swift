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

    var toastManager: ToastManager?

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

    @discardableResult
    func createTemplate(name: String,
                        description: String,
                        defaultGold: Double,
                        xpReward: Int,
                        schedule: QuestSchedule,
                        specificDays: [String] = [],
                        targetCount: Int = 1,
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
            targetCount: max(1, targetCount),
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

        let preMutationChangeTag = snapshot?.changeTag
        let snapshotTemplate: QuestTemplate? = snapshot?.toQuestTemplate(zoneID: cloudKit.resolvedZoneID)

        cacheService?.upsertQuestTemplate(template)
        do {
            let saved = try await cloudKit.save(template)
            cacheService?.upsertQuestTemplate(saved)
            return saved
        } catch {
            if handleConcurrentEdit(
                preMutationChangeTag: preMutationChangeTag,
                fetchCurrent: { self.cacheService?.fetchQuestTemplates(family: template.family.recordID.recordName)
                    .first(where: { $0.recordName == name })?.changeTag
                },
                error: error
            ) {
                // Concurrent edit: re-fetch authoritative record, fall back to snapshot, else invalidate.
                if let fresh = try? await cloudKit.fetch(QuestTemplate.self, id: template.id) {
                    cacheService?.upsertQuestTemplate(fresh)
                } else if let snapshotTemplate {
                    cacheService?.upsertQuestTemplate(snapshotTemplate)
                } else {
                    cacheService?.invalidateQuestTemplate(recordName: name)
                }
            } else {
                if let snapshotTemplate {
                    cacheService?.upsertQuestTemplate(snapshotTemplate)
                } else {
                    cacheService?.invalidateQuestTemplate(recordName: name)
                }
                showErrorToast(error)
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

        let preMutationChangeTag = snapshot?.changeTag
        let snapshotTemplate: QuestTemplate? = snapshot?.toQuestTemplate(zoneID: cloudKit.resolvedZoneID)

        cacheService?.upsertQuestTemplate(deactivated)
        do {
            let saved = try await cloudKit.save(deactivated)
            cacheService?.upsertQuestTemplate(saved)
            return saved
        } catch {
            if handleConcurrentEdit(
                preMutationChangeTag: preMutationChangeTag,
                fetchCurrent: { self.cacheService?.fetchQuestTemplates(family: template.family.recordID.recordName)
                    .first(where: { $0.recordName == name })?.changeTag
                },
                error: error
            ) {
                if let fresh = try? await cloudKit.fetch(QuestTemplate.self, id: template.id) {
                    cacheService?.upsertQuestTemplate(fresh)
                } else if let snapshotTemplate {
                    cacheService?.upsertQuestTemplate(snapshotTemplate)
                } else {
                    cacheService?.invalidateQuestTemplate(recordName: name)
                }
            } else {
                if let snapshotTemplate {
                    cacheService?.upsertQuestTemplate(snapshotTemplate)
                } else {
                    cacheService?.invalidateQuestTemplate(recordName: name)
                }
                showErrorToast(error)
            }
            throw error
        }
    }

    /// Cache-first read. Background refresh handled by SyncEngine via push notifications.
    func fetchTemplates(family: Family) async throws -> [QuestTemplate] {
        if let cache = cacheService {
            let familyName = family.id.recordName
            let cached = cache.fetchQuestTemplates(family: familyName)
            if !cached.isEmpty {
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
            targetCount: template.targetCount,
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

        do {
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
        } catch {
            if handleConcurrentEdit(
                preMutationChangeTag: nil,
                fetchCurrent: { self.cacheService?.fetchQuests(family: family.id.recordName)
                    .first(where: { $0.recordName == quest.id.recordName })?.changeTag
                },
                error: error
            ) {
                if let fresh = try? await cloudKit.fetch(Quest.self, id: quest.id) {
                    cacheService?.upsertQuest(fresh)
                } else {
                    cacheService?.invalidateQuest(recordName: quest.id.recordName)
                }
            } else {
                cacheService?.invalidateQuest(recordName: quest.id.recordName)
                showErrorToast(error)
            }
            throw error
        }
    }

    @discardableResult
    func updateQuest(_ quest: Quest) async throws -> Quest {
        let name = quest.id.recordName
        let snapshot = cacheService?.fetchQuests(family: quest.family.recordID.recordName)
            .first(where: { $0.recordName == name })

        let preMutationChangeTag = snapshot?.changeTag
        let snapshotQuest: Quest? = snapshot?.toQuest(zoneID: cloudKit.resolvedZoneID)

        cacheService?.upsertQuest(quest)
        do {
            let saved = try await cloudKit.save(quest)
            cacheService?.upsertQuest(saved)
            return saved
        } catch {
            if handleConcurrentEdit(
                preMutationChangeTag: preMutationChangeTag,
                fetchCurrent: { self.cacheService?.fetchQuests(family: quest.family.recordID.recordName)
                    .first(where: { $0.recordName == name })?.changeTag
                },
                error: error
            ) {
                if let fresh = try? await cloudKit.fetch(Quest.self, id: quest.id) {
                    cacheService?.upsertQuest(fresh)
                } else if let snapshotQuest {
                    cacheService?.upsertQuest(snapshotQuest)
                } else {
                    cacheService?.invalidateQuest(recordName: name)
                }
            } else {
                if let snapshotQuest {
                    cacheService?.upsertQuest(snapshotQuest)
                } else {
                    cacheService?.invalidateQuest(recordName: name)
                }
                showErrorToast(error)
            }
            throw error
        }
    }

    @discardableResult
    func assignQuickQuest(name: String,
                          description: String = "",
                          assignee: Profile,
                          goldReward: Double,
                          xpReward: Int,
                          scheduleType: QuestSchedule = .weeklyFlexible,
                          specificDays: [String] = [],
                          targetCount: Int = 1,
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
            targetCount: targetCount,
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
            targetCount: max(1, targetCount),
            isAllOrNothing: false,
            approvalMode: approvalMode,
            weekOf: normalizedWeek,
            createdBy: CKRecord.Reference(recordID: createdBy.id, action: .none),
            family: CKRecord.Reference(recordID: family.id, action: .none),
            name: name,
            descriptionText: description
        )

        // Optimistic local write first
        cacheService?.upsertQuest(quest)

        do {
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
        } catch {
            if handleConcurrentEdit(
                preMutationChangeTag: nil,
                fetchCurrent: { self.cacheService?.fetchQuests(family: family.id.recordName)
                    .first(where: { $0.recordName == quest.id.recordName })?.changeTag
                },
                error: error
            ) {
                if let fresh = try? await cloudKit.fetch(Quest.self, id: quest.id) {
                    cacheService?.upsertQuest(fresh)
                } else {
                    cacheService?.invalidateQuest(recordName: quest.id.recordName)
                }
                // The deactivated ad-hoc template was already persisted before
                // the quest save; invalidate it too so it doesn't orphan.
                cacheService?.invalidateQuestTemplate(recordName: adhocTemplate.id.recordName)
            } else {
                cacheService?.invalidateQuest(recordName: quest.id.recordName)
                cacheService?.invalidateQuestTemplate(recordName: adhocTemplate.id.recordName)
                showErrorToast(error)
            }
            throw error
        }
    }

    func unassignQuest(_ quest: Quest) async throws {
        cacheService?.invalidateQuest(recordName: quest.id.recordName)
        try await cloudKit.delete(quest.id)
    }

    /// Cache-first read. On cold cache miss, falls back to a single synchronous
    /// CloudKit query to hydrate. Background ongoing refresh handled by
    /// SyncEngine via push notifications.
    func fetchActiveQuests(profile: Profile, weekOf: Date) async throws -> [Quest] {
        let range = QuestService.weekRange(for: weekOf)

        // Cache-first: check local cache
        if let cache = cacheService {
            let profileName = profile.id.recordName
            let familyName = profile.family.recordID.recordName
            let cached = cache.fetchQuests(family: familyName, weekInRange: range)
                .filter { $0.assigneeRecordName == profileName && $0.isActive }
            if !cached.isEmpty {
                return await stampAllQuests(cached.map { $0.toQuest(zoneID: cloudKit.resolvedZoneID) })
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

    /// Cache-first read. On cold cache miss, falls back to a single synchronous
    /// CloudKit query to hydrate. Background ongoing refresh handled by
    /// SyncEngine via push notifications.
    func fetchQuestsForFamilyWeek(family: Family, weekOf: Date) async throws -> [Quest] {
        let range = QuestService.weekRange(for: weekOf)

        if let cache = cacheService {
            let familyName = family.id.recordName
            let cached = cache.fetchQuests(family: familyName, weekInRange: range)
                .filter(\.isActive)
            if !cached.isEmpty {
                return await stampAllQuests(cached.map { $0.toQuest(zoneID: cloudKit.resolvedZoneID) })
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
}

// MARK: - Quest Completions & Verification

extension QuestService {
    @discardableResult
    func markComplete(quest: Quest, by profile: Profile, at completedDate: Date = Date()) async throws -> QuestCompletion {
        // Correctness gate: must read from CloudKit (not stale cache) to prevent
        // duplicate completions / false "alreadyCompleted". A stale cached pending
        // log could falsely throw alreadyCompleted, and a stale cached empty set
        // could allow a duplicate completion. See `fetchQuestLogs(forQuest:useCache:)` docs.
        let existingLogs = await (try? fetchQuestLogs(forQuest: quest, useCache: false)) ?? []
        let nonRejectedCount = existingLogs.filter { $0.verificationStatus != .rejected }.count
        let target = max(1, quest.targetCount)
        if nonRejectedCount >= target {
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

        do {
            let saved = try await cloudKit.save(editable)
            cacheService?.upsertQuestCompletion(saved)

            switch quest.approvalMode {
            case .autoApprove:
                try await applyReward(for: quest, to: profile)
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
        } catch {
            if handleConcurrentEdit(
                preMutationChangeTag: nil,
                fetchCurrent: { self.cacheService?.fetchQuestCompletions(family: quest.family.recordID.recordName)
                    .first(where: { $0.recordName == editable.id.recordName })?.changeTag
                },
                error: error
            ) {
                if let fresh = try? await cloudKit.fetch(QuestCompletion.self, id: editable.id) {
                    cacheService?.upsertQuestCompletion(fresh)
                } else {
                    cacheService?.invalidateQuestCompletion(recordName: editable.id.recordName)
                }
            } else {
                cacheService?.invalidateQuestCompletion(recordName: editable.id.recordName)
                showErrorToast(error)
            }
            throw error
        }
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

        let preMutationChangeTag = snapshot?.changeTag
        let snapshotCompletion: QuestCompletion? = snapshot?.toQuestCompletion(zoneID: cloudKit.resolvedZoneID)

        cacheService?.upsertQuestCompletion(updated)
        do {
            let saved = try await cloudKit.save(updated)
            cacheService?.upsertQuestCompletion(saved)

            let quest = try await cloudKit.fetch(Quest.self, id: questLog.quest.recordID)
            let hero = try await cloudKit.fetch(Profile.self, id: questLog.completedBy.recordID)
            let creditedGold = try await applyReward(for: quest, to: hero)

            if let notificationService {
                Task { @Sendable in
                    let goldText = NumberFormatter.goldFormatter
                        .string(from: NSNumber(value: creditedGold)) ?? "\(creditedGold)"
                    try? await notificationService.send(
                        .questCompleted,
                        to: hero,
                        title: "🏆 Quest Verified!",
                        body: "Your quest was verified! You earned \(goldText) gold."
                    )
                }
            }

            return saved
        } catch {
            if handleConcurrentEdit(
                preMutationChangeTag: preMutationChangeTag,
                fetchCurrent: { self.cacheService?.fetchQuestCompletions(family: questLog.family.recordID.recordName)
                    .first(where: { $0.recordName == name })?.changeTag
                },
                error: error
            ) {
                if let fresh = try? await cloudKit.fetch(QuestCompletion.self, id: questLog.id) {
                    cacheService?.upsertQuestCompletion(fresh)
                } else if let snapshotCompletion {
                    cacheService?.upsertQuestCompletion(snapshotCompletion)
                } else {
                    cacheService?.invalidateQuestCompletion(recordName: name)
                }
            } else {
                if let snapshotCompletion {
                    cacheService?.upsertQuestCompletion(snapshotCompletion)
                } else {
                    cacheService?.invalidateQuestCompletion(recordName: name)
                }
                showErrorToast(error)
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

        let preMutationChangeTag = snapshot?.changeTag
        let snapshotCompletion: QuestCompletion? = snapshot?.toQuestCompletion(zoneID: cloudKit.resolvedZoneID)

        cacheService?.upsertQuestCompletion(updated)
        do {
            let saved = try await cloudKit.save(updated)
            cacheService?.upsertQuestCompletion(saved)
            return saved
        } catch {
            if handleConcurrentEdit(
                preMutationChangeTag: preMutationChangeTag,
                fetchCurrent: { self.cacheService?.fetchQuestCompletions(family: questLog.family.recordID.recordName)
                    .first(where: { $0.recordName == name })?.changeTag
                },
                error: error
            ) {
                if let fresh = try? await cloudKit.fetch(QuestCompletion.self, id: questLog.id) {
                    cacheService?.upsertQuestCompletion(fresh)
                } else if let snapshotCompletion {
                    cacheService?.upsertQuestCompletion(snapshotCompletion)
                } else {
                    cacheService?.invalidateQuestCompletion(recordName: name)
                }
            } else {
                if let snapshotCompletion {
                    cacheService?.upsertQuestCompletion(snapshotCompletion)
                } else {
                    cacheService?.invalidateQuestCompletion(recordName: name)
                }
                showErrorToast(error)
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
        var existingKeys = Set(existing.map { "\($0.template.recordID.recordName)|\($0.assignee.recordID.recordName)" })

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

        let daySet: Set<Date> = Set(logs.compactMap { log -> Date? in
            guard log.verificationStatus == .autoApproved || log.verificationStatus == .verified else { return nil }
            return calendar.dateInterval(of: .day, for: log.completedDate)?.start
        })

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

        // Group approved logs by quest and route gold credit through the
        // shared `GoldCalculation` helper — the same one
        // `TreasuryService.sumGold` uses — so this weekly total and the wallet
        // never disagree on a partially completed quest. The proration is
        // per-quest (approvedCount per quest * goldReward / targetCount,
        // capped by `isAllOrNothing`), so the helper is invoked once per
        // quest with the full approved count for that quest.
        var approvedCountByQuest: [CKRecord.ID: Int] = [:]
        for log in logs {
            approvedCountByQuest[log.quest.recordID, default: 0] += 1
        }

        var total: Double = 0
        for (questID, approvedCount) in approvedCountByQuest {
            if let quest = questMap[questID] {
                total += GoldCalculation.creditAsDouble(for: quest,
                                                        approvedCount: approvedCount)
            }
        }
        return total
    }

    /// Cache-first read. Background refresh handled by SyncEngine via push notifications.
    func fetchQuestLogs(forQuest quest: Quest, useCache: Bool = true) async throws -> [QuestCompletion] {
        if useCache, let cache = cacheService {
            let questName = quest.id.recordName
            let cached = cache.fetchQuestCompletions(family: quest.family.recordID.recordName)
                .filter { $0.questRecordName == questName }
            if !cached.isEmpty {
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

    /// Cache-first read. Background refresh handled by SyncEngine via push notifications.
    func fetchQuestLogs(for profile: Profile) async throws -> [QuestCompletion] {
        if let cache = cacheService {
            let profileName = profile.id.recordName
            let cached = cache.fetchQuestCompletions(family: profile.family.recordID.recordName)
                .filter { $0.completerRecordName == profileName }
            if !cached.isEmpty {
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

    /// Cache-first read. Background refresh handled by SyncEngine via push notifications.
    func fetchQuestCompletionsForFamily(family: Family) async throws -> [QuestCompletion] {
        if let cache = cacheService {
            let familyName = family.id.recordName
            let cached = cache.fetchQuestCompletions(family: familyName)
            if !cached.isEmpty {
                let zoneID = cloudKit.resolvedZoneID
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

    /// Detects a concurrent edit and surfaces the canonical warning toast.
    /// Returns `true` when a concurrent edit is found — callers then run
    /// their per-type rollback (fresh re-fetch / snapshot restore / invalidate).
    @discardableResult
    private func handleConcurrentEdit(
        preMutationChangeTag: String?,
        fetchCurrent: @escaping () -> String?,
        error: Error
    ) -> Bool {
        let detected = ConcurrentEditDetector.detectConcurrentEdit(
            preMutationChangeTag: preMutationChangeTag,
            fetchCurrent: fetchCurrent,
            error: error
        )
        if detected {
            toastManager?.show(
                message: "Data was modified by another device. Refresh to see the latest.",
                type: .warning
            )
        }
        return detected
    }

    private func showErrorToast(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        toastManager?.show(message: message, type: .error)
    }

    /// Gold credit routes through the shared `GoldCalculation` helper — the
    /// same one `TreasuryService.sumGold` uses — so the reward step and the
    /// wallet never disagree on a partially completed quest. The persisted
    /// `QuestCompletion` record remains the credit TreasuryService sums; no
    /// parallel wallet write happens here.
    @discardableResult
    private func applyReward(for quest: Quest, to hero: Profile) async throws -> Double {
        try await xpService.addXP(quest.xpReward, to: hero)

        // Bypass cache the same way `markComplete` does so a stale local set
        // can't under- or over-credit the proration.
        let logs = await (try? fetchQuestLogs(forQuest: quest, useCache: false)) ?? []
        let approvedCount = logs.filter { $0.verificationStatus != .rejected }.count

        return GoldCalculation.creditAsDouble(for: quest, approvedCount: approvedCount)
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
            let day = calendar.date(byAdding: .day, value: offset, to: weekOf) ?? weekOf
            let weekday = calendar.component(.weekday, from: day)
            let index = max(0, min(codes.count - 1, weekday - 1))
            found.insert(codes[index])
        }
        return found
    }
}

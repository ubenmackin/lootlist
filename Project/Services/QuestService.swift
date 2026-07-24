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
        return try await cloudKit.save(template)
    }

    @discardableResult
    func updateTemplate(_ template: QuestTemplate) async throws -> QuestTemplate {
        try await cloudKit.save(template)
    }

    @discardableResult
    func deactivateTemplate(_ template: QuestTemplate) async throws -> QuestTemplate {
        var deactivated = template
        deactivated.isActive = false
        return try await cloudKit.save(deactivated)
    }

    func fetchTemplates(family: Family) async throws -> [QuestTemplate] {
        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let predicate = NSPredicate(format: "family == %@", familyRef)
        let all = try await cloudKit.query(QuestTemplate.self, predicate: predicate)
        return all
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    func assignQuest(template: QuestTemplate,
                     assignee: Profile,
                     goldOverride: Double? = nil,
                     xpOverride: Int? = nil,
                     approvalOverride: ApprovalMode? = nil,
                     weekOf: Date,
                     createdBy: Profile,
                     family: Family) async throws -> Quest
    {
        let normalizedWeek = startOfWeek(for: weekOf)
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
            name: template.name,
            descriptionText: template.description
        )
        let saved = try await cloudKit.save(quest)
        if let notificationService {
            Task { @Sendable in
                try? await notificationService.send(
                    .questAssigned,
                    to: assignee,
                    title: "⚔️ New Quest Assigned!",
                    body: "You have been assigned '\(template.name)'."
                )
            }
        }
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

        let normalizedWeek = startOfWeek(for: weekOf)
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
        let saved = try await cloudKit.save(quest)
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
        try await cloudKit.delete(quest.id)
    }

    func fetchActiveQuests(profile: Profile, weekOf: Date) async throws -> [Quest] {
        let normalizedWeek = startOfWeek(for: weekOf)
        let assigneeRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let predicate = NSPredicate(
            format: "assignee == %@ AND weekOf == %@",
            assigneeRef, normalizedWeek as CVarArg
        )
        let all = try await cloudKit.query(Quest.self, predicate: predicate)
        return all
            .filter(\.active)
            .sorted { $0.template.recordID.recordName < $1.template.recordID.recordName }
    }

    func fetchQuestsForFamilyWeek(family: Family, weekOf: Date) async throws -> [Quest] {
        let normalizedWeek = startOfWeek(for: weekOf)
        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let predicate = NSPredicate(
            format: "family == %@ AND weekOf == %@",
            familyRef, normalizedWeek as CVarArg
        )
        let all = try await cloudKit.query(Quest.self, predicate: predicate)
        return all
            .filter(\.active)
            .sorted { $0.assignee.recordID.recordName < $1.assignee.recordID.recordName }
    }

    @discardableResult
    func markComplete(quest: Quest, by profile: Profile, at completedDate: Date = Date()) async throws -> QuestCompletion {
        let existingLogs = try await fetchQuestLogs(forQuest: quest)
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
        let saved = try await cloudKit.save(editable)

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
        let saved = try await cloudKit.save(updated)

        let quest = try await cloudKit.fetch(Quest.self, id: questLog.quest.recordID)
        let hero = try await cloudKit.fetch(Profile.self, id: questLog.completedBy.recordID)
        try await applyReward(for: quest, to: hero)

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
        return try await cloudKit.save(updated)
    }

    func generateWeeklyQuests(family: Family,
                              weekOf: Date,
                              createdBy: Profile,
                              heroes: [Profile]) async throws
    {
        let normalizedWeek = startOfWeek(for: weekOf)

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
        let normalizedWeek = startOfWeek(for: weekOf)
        let logs = try await fetchQuestLogs(for: profile)
            .filter { $0.weekOf == normalizedWeek
                && ($0.verificationStatus == .autoApproved
                    || $0.verificationStatus == .verified)
            }

        guard !logs.isEmpty else { return 0 }

        // Batch-fetch all referenced Quest records in a single query (N+1 fix).
        let questIDs = Array(Set(logs.map(\.quest.recordID)))
        let predicate = NSPredicate(format: "recordID IN %@", questIDs)
        let quests = try await cloudKit.query(Quest.self, predicate: predicate)
        let questMap = Dictionary(uniqueKeysWithValues: quests.map { ($0.id, $0) })

        var total: Double = 0
        for log in logs {
            if let quest = questMap[log.quest.recordID] {
                total += quest.goldReward
            }
        }
        return total
    }

    func fetchQuestLogs(forQuest quest: Quest) async throws -> [QuestCompletion] {
        let questRef = CKRecord.Reference(recordID: quest.id, action: .none)
        let predicate = NSPredicate(format: "quest == %@", questRef)
        return try await cloudKit.query(
            QuestCompletion.self,
            predicate: predicate,
            sortDescriptors: [NSSortDescriptor(key: "completedDate", ascending: false)]
        )
    }

    func fetchQuestLogs(for profile: Profile) async throws -> [QuestCompletion] {
        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let predicate = NSPredicate(format: "completedBy == %@", profileRef)
        return try await cloudKit.query(
            QuestCompletion.self,
            predicate: predicate,
            sortDescriptors: [NSSortDescriptor(key: "completedDate", ascending: false)]
        )
    }

    private func fetchFamily(for reference: CKRecord.Reference) async throws -> Family {
        try await cloudKit.fetch(Family.self, id: reference.recordID)
    }

    private func applyReward(for quest: Quest, to hero: Profile) async throws {
        _ = try await xpService.addXP(quest.xpReward, to: hero)
    }

    private func startOfWeek(for date: Date) -> Date {
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return calendar.date(from: components) ?? date
    }

    private func weekdayCodes(inWeekOf weekOf: Date) -> Set<String> {
        let codes = ["sunday", "monday", "tuesday", "wednesday",
                     "thursday", "friday", "saturday"]
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

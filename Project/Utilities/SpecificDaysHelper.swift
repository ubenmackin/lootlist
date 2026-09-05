//
//  SpecificDaysHelper.swift
//  LootList
//
//  Created by Ben Mackin on 9/04/26.
//

import CloudKit
import Foundation

enum SpecificDaysHelper: Sendable {
    /// WHY cache-only template map: payout math stays cache-first so offline settlements still resolve day counts.
    @MainActor
    static func templatesByID(cache: any CacheServicing, familyName: String, zoneID: CKRecordZone.ID) -> [String: QuestTemplate] {
        let caches = cache.fetchQuestTemplates(family: familyName)
        return Dictionary(uniqueKeysWithValues: caches.map { ($0.recordName, $0.toQuestTemplate(zoneID: zoneID)) })
    }

    static func templatesByID(_ caches: [QuestTemplateCache]) -> [String: QuestTemplateCache] {
        Dictionary(uniqueKeysWithValues: caches.map { ($0.recordName, $0) })
    }

    static func specificDays(for quest: QuestCache, templatesByID: [String: QuestTemplateCache]) -> [String] {
        templatesByID[quest.templateRecordName]?.specificDays ?? []
    }

    static func orderedDays(_ days: [String]) -> [String] {
        // WHY WeekMath owns the weekday cycle: week ordering routes via WeekMath so day sorting cannot diverge.
        WeekMath.orderedDays(days)
    }

    static func isDayChecklist(quest: QuestCache, specificDays: [String]) -> Bool {
        quest.scheduleTypeEnum == .specificDays && !specificDays.isEmpty
    }

    static func isDayChecklist(quest: QuestCache, templatesByID: [String: QuestTemplateCache]) -> Bool {
        isDayChecklist(quest: quest, specificDays: specificDays(for: quest, templatesByID: templatesByID))
    }

    static func effectiveTarget(for quest: QuestCache, specificDays: [String]) -> Int {
        if isDayChecklist(quest: quest, specificDays: specificDays) {
            return specificDays.count
        }
        return max(1, quest.targetCount)
    }

    static func effectiveTarget(for quest: QuestCache, templatesByID: [String: QuestTemplateCache]) -> Int {
        effectiveTarget(for: quest, specificDays: specificDays(for: quest, templatesByID: templatesByID))
    }

    static func specificDays(for quest: Quest, templatesByID: [String: QuestTemplate]) -> [String] {
        templatesByID[quest.template.recordID.recordName]?.specificDays ?? []
    }

    /// WHY day count wins: legacy quest rows keep stale targetCount after template gains days.
    static func effectiveTarget(for quest: Quest, specificDays: [String]) -> Int {
        if quest.scheduleType == .specificDays, !specificDays.isEmpty {
            return specificDays.count
        }
        return max(1, quest.targetCount)
    }

    static func effectiveTarget(for quest: Quest, templatesByID: [String: QuestTemplate]) -> Int {
        effectiveTarget(for: quest, specificDays: specificDays(for: quest, templatesByID: templatesByID))
    }

    static func isMultiPart(quest: QuestCache, specificDays: [String]) -> Bool {
        quest.targetCount > 1 || isDayChecklist(quest: quest, specificDays: specificDays)
    }

    static func isMultiPart(quest: QuestCache, templatesByID: [String: QuestTemplateCache]) -> Bool {
        isMultiPart(quest: quest, specificDays: specificDays(for: quest, templatesByID: templatesByID))
    }

    static func isScheduledToday(quest: QuestCache, specificDays: [String], todayCode: String) -> Bool {
        guard quest.scheduleTypeEnum == .specificDays else { return false }
        return specificDays.contains(todayCode)
    }

    static func isScheduledToday(quest: QuestCache, templatesByID: [String: QuestTemplateCache], todayCode: String) -> Bool {
        isScheduledToday(
            quest: quest,
            specificDays: specificDays(for: quest, templatesByID: templatesByID),
            todayCode: todayCode
        )
    }

    static func dueText(for quest: QuestCache, templatesByID: [String: QuestTemplateCache], todayCode: String) -> String {
        guard quest.scheduleTypeEnum == .specificDays else { return "This Week" }
        return dueText(specificDays: specificDays(for: quest, templatesByID: templatesByID), todayCode: todayCode)
    }

    static func dueText(specificDays days: [String], todayCode: String) -> String {
        if days.isEmpty {
            return "This Week"
        }
        return dayState(orderedDays: orderedDays(days), todayCode: todayCode)
    }

    static func headerDayState(orderedDays days: [String], todayCode: String) -> String {
        dayState(orderedDays: days, todayCode: todayCode)
    }

    static func dayState(orderedDays days: [String], todayCode: String) -> String {
        if days.contains(todayCode) {
            return "Due Today"
        }
        if let next = WeekMath.nextWeekdayCode(after: todayCode, candidates: days) {
            return "Due \(WeekMath.shortName(for: next))"
        }
        // WHY wrap: no future day this week, show next week's first scheduled day.
        return "Due \(WeekMath.shortName(for: WeekMath.orderedDays(days).first ?? todayCode))"
    }

    static func dayState(for code: String, todayCode: String) -> String {
        code == todayCode ? "Due Today" : "Due \(WeekMath.shortName(for: code))"
    }
}

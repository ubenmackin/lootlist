//
//  SpecificDaysHelper.swift
//  LootList
//
//  Created by Ben Mackin on 9/04/26.
//

import Foundation

/// Single source for day-checklist derivation so hub, chores, and cards agree on slots.
enum SpecificDaysHelper: Sendable {
    /// Template days for a quest, empty when no template row or no scheduled days.
    static func specificDays(for quest: QuestCache, templatesByID: [String: QuestTemplateCache]) -> [String] {
        templatesByID[quest.templateRecordName]?.specificDays ?? []
    }

    /// Weekday-ordered days using the canonical weekday cycle.
    static func orderedDays(_ days: [String]) -> [String] {
        let order = AppConstants.weekdayCodes
        return days.sorted {
            (order.firstIndex(of: $0) ?? Int.max) < (order.firstIndex(of: $1) ?? Int.max)
        }
    }

    /// Checklist when the quest runs on specific days with at least one scheduled day.
    static func isDayChecklist(quest: QuestCache, specificDays: [String]) -> Bool {
        quest.scheduleTypeEnum == .specificDays && !specificDays.isEmpty
    }

    static func isDayChecklist(quest: QuestCache, templatesByID: [String: QuestTemplateCache]) -> Bool {
        isDayChecklist(quest: quest, specificDays: specificDays(for: quest, templatesByID: templatesByID))
    }

    /// Slot count for progress and credit; day count wins so stale targetCount cannot under-count.
    static func effectiveTarget(for quest: QuestCache, specificDays: [String]) -> Int {
        if isDayChecklist(quest: quest, specificDays: specificDays) {
            return specificDays.count
        }
        return max(1, quest.targetCount)
    }

    static func effectiveTarget(for quest: QuestCache, templatesByID: [String: QuestTemplateCache]) -> Int {
        effectiveTarget(for: quest, specificDays: specificDays(for: quest, templatesByID: templatesByID))
    }

    /// Template days for a domain quest, empty when no template row or no scheduled days.
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

    /// Segmented card when repeat count or day checklist needs per-part rows.
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

    /// Due copy for hub rows; past days stay actionable as makeup within the week.
    static func dueText(for quest: QuestCache, templatesByID: [String: QuestTemplateCache], todayCode: String) -> String {
        guard quest.scheduleTypeEnum == .specificDays else { return "This Week" }
        return dueText(specificDays: specificDays(for: quest, templatesByID: templatesByID), todayCode: todayCode)
    }

    static func dueText(specificDays days: [String], todayCode: String) -> String {
        if days.isEmpty {
            return "This Week"
        }
        if days.contains(todayCode) {
            return "Due Today"
        }
        if let next = WeekMath.nextWeekdayCode(after: todayCode, candidates: days) {
            return "Due \(WeekMath.shortName(for: next))"
        }
        return "Due \(WeekMath.shortName(for: orderedDays(days).last ?? todayCode))"
    }

    /// Day state for checklist headers; mirrors dueText without the non-checklist fallback.
    static func headerDayState(orderedDays: [String], todayCode: String) -> String {
        if orderedDays.contains(todayCode) {
            return "Due Today"
        }
        if let next = WeekMath.nextWeekdayCode(after: todayCode, candidates: orderedDays) {
            return "Due \(WeekMath.shortName(for: next))"
        }
        return "Due \(WeekMath.shortName(for: orderedDays.last ?? todayCode))"
    }

    static func dayState(for code: String, todayCode: String) -> String {
        code == todayCode ? "Due Today" : "Due \(WeekMath.shortName(for: code))"
    }
}

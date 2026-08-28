//
//  CacheService+Batches.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import Foundation
import os
import SwiftData

// MARK: - Batch Upserts

@MainActor
extension CacheService {
    private func existingByRecordName<T: CacheMergeable>(_: T.Type, family: String?) -> [String: T]? {
        guard let context else { return nil }
        do {
            let descriptor = T.fetchDescriptor(familyRecordName: family)
            var existing = try context.fetch(descriptor)
            if let family, !family.isEmpty {
                let unscoped = T.fetchDescriptor(familyRecordName: nil)
                let allRows = try context.fetch(unscoped)
                for row in allRows where row.familyRecordName.isEmpty {
                    existing.append(row)
                }
            }
            return Dictionary(existing.map { ($0.recordName, $0) }, uniquingKeysWith: { current, _ in current })
        } catch {
            logger.error("Failed to fetch \(String(describing: T.self), privacy: .public) by record name: \(error, privacy: .private)")
            return nil
        }
    }

    /// Single private generic — all batch wrappers route through here.
    private func batchUpsert<T: CacheMergeable>(_: T.Type, items: [T.DomainModel], familyRecordName: String?) {
        if let familyRecordName {
            guard let context else { return }
            guard let existingMap = existingByRecordName(T.self, family: familyRecordName) else { return }
            for item in items {
                let name = item.id.recordName
                let itemFamily = T(from: item).familyRecordName
                if !itemFamily.isEmpty, itemFamily != familyRecordName {
                    logFamilyMismatch(
                        action: "Explicit family mismatch ignoring batch upsert for",
                        entityName: String(describing: T.self),
                        recordName: name,
                        requestedFamily: familyRecordName,
                        actualFamily: itemFamily
                    )
                    continue
                }
                if let cached = existingMap[name] {
                    guard cached.familyRecordName.isEmpty
                        || cached.familyRecordName == familyRecordName
                    else {
                        logger.warning(
                            """
                            Scope mismatch ignoring batch upsert for \
                            \(String(describing: T.self), privacy: .public) \
                            \(name, privacy: .private): existing=\
                            \(cached.familyRecordName, privacy: .private) expected=\
                            \(familyRecordName, privacy: .private)
                            """
                        )
                        continue
                    }
                    T.apply(cached, from: item)
                } else {
                    context.insert(T(from: item))
                }
            }
            saveContext()
            return
        }
        // Nil scope — group by family to keep each family's save isolated.
        if T.self == FamilyCache.self {
            guard let context else { return }
            guard let existingMap = existingByRecordName(T.self, family: nil) else { return }
            for item in items {
                let name = item.id.recordName
                if let cached = existingMap[name] {
                    T.apply(cached, from: item)
                } else {
                    context.insert(T(from: item))
                }
            }
            saveContext()
            return
        }
        let grouped = Dictionary(grouping: items) { T(from: $0).familyRecordName }
        for (family, group) in grouped {
            batchUpsert(T.self, items: group, familyRecordName: family.isEmpty ? nil : family)
        }
    }

    private func purgeMissing<T: CacheMergeable>(_: T.Type, validRecordNames: Set<String>, familyRecordName: String?) {
        guard !validRecordNames.isEmpty else { return }
        guard let context else { return }
        let family: String? = (T.self == FamilyCache.self) ? nil : familyRecordName
        if T.self != FamilyCache.self, family == nil || family?.isEmpty == true {
            return
        }
        do {
            let existing = try context.fetch(T.fetchDescriptor(familyRecordName: family))
            for cached in existing where !validRecordNames.contains(cached.recordName) {
                context.delete(cached)
            }
            saveContext()
        } catch {
            logger.error("Failed to fetch \(T.self, privacy: .private) for purgeMissing: \(error, privacy: .private)")
        }
    }

    /// Batch mutations ride the background writer; `isServerSync: false`
    /// preserves the legacy batch merge semantics for local-first writes.
    func upsertQuests(_ quests: [Quest], family: String? = nil) async {
        if let backgroundWriter {
            await backgroundWriter.upsertDomainModels(quests, type: QuestCache.self, familyRecordName: family, isServerSync: false)
        } else {
            batchUpsert(QuestCache.self, items: quests, familyRecordName: family)
        }
    }

    func upsertProfiles(_ profiles: [Profile], family: String? = nil) async {
        if let backgroundWriter {
            await backgroundWriter.upsertDomainModels(profiles, type: ProfileCache.self, familyRecordName: family, isServerSync: false)
        } else {
            batchUpsert(ProfileCache.self, items: profiles, familyRecordName: family)
        }
    }

    func upsertQuestCompletions(_ completions: [QuestCompletion], family: String? = nil) async {
        if let backgroundWriter {
            await backgroundWriter.upsertDomainModels(completions, type: QuestCompletionCache.self, familyRecordName: family, isServerSync: false)
        } else {
            batchUpsert(QuestCompletionCache.self, items: completions, familyRecordName: family)
        }
    }

    func upsertQuestTemplates(_ templates: [QuestTemplate], family: String? = nil) async {
        if let backgroundWriter {
            await backgroundWriter.upsertDomainModels(templates, type: QuestTemplateCache.self, familyRecordName: family, isServerSync: false)
        } else {
            batchUpsert(QuestTemplateCache.self, items: templates, familyRecordName: family)
        }
    }

    func upsertLedgerEntries(_ entries: [LedgerEntry], family: String? = nil) async {
        if let backgroundWriter {
            await backgroundWriter.upsertDomainModels(entries, type: LedgerEntryCache.self, familyRecordName: family, isServerSync: false)
        } else {
            batchUpsert(LedgerEntryCache.self, items: entries, familyRecordName: family)
        }
    }

    func upsertAllowancePeriods(_ periods: [AllowancePeriod], family: String? = nil) async {
        if let backgroundWriter {
            await backgroundWriter.upsertDomainModels(periods, type: AllowancePeriodCache.self, familyRecordName: family, isServerSync: false)
        } else {
            batchUpsert(AllowancePeriodCache.self, items: periods, familyRecordName: family)
        }
    }

    func upsertAchievements(_ achievements: [Achievement], family: String? = nil) async {
        if let backgroundWriter {
            await backgroundWriter.upsertDomainModels(achievements, type: AchievementCache.self, familyRecordName: family, isServerSync: false)
        } else {
            batchUpsert(AchievementCache.self, items: achievements, familyRecordName: family)
        }
    }

    func upsertProfileAchievements(_ pas: [ProfileAchievement], family: String? = nil) async {
        if let backgroundWriter {
            await backgroundWriter.upsertDomainModels(pas, type: ProfileAchievementCache.self, familyRecordName: family, isServerSync: false)
        } else {
            batchUpsert(ProfileAchievementCache.self, items: pas, familyRecordName: family)
        }
    }

    func upsertNotificationPreferences(_ prefs: [NotificationPreference], family: String? = nil) async {
        if let backgroundWriter {
            await backgroundWriter.upsertDomainModels(prefs, type: NotificationPreferenceCache.self, familyRecordName: family, isServerSync: false)
        } else {
            batchUpsert(
                NotificationPreferenceCache.self,
                items: prefs,
                familyRecordName: family
            )
        }
    }

    func upsertGemLedgers(_ entries: [GemLedger], family: String? = nil) async {
        if let backgroundWriter {
            await backgroundWriter.upsertDomainModels(entries, type: GemLedgerCache.self, familyRecordName: family, isServerSync: false)
        } else {
            batchUpsert(GemLedgerCache.self, items: entries, familyRecordName: family)
        }
    }

    func upsertRewardEvents(_ events: [RewardEvent], family: String? = nil) async {
        if let backgroundWriter {
            await backgroundWriter.upsertDomainModels(events, type: RewardEventCache.self, familyRecordName: family, isServerSync: false)
        } else {
            batchUpsert(RewardEventCache.self, items: events, familyRecordName: family)
        }
    }

    func upsertGoals(_ goals: [Goal], family: String? = nil) async {
        if let backgroundWriter {
            await backgroundWriter.upsertDomainModels(goals, type: GoalCache.self, familyRecordName: family, isServerSync: false)
        } else {
            batchUpsert(GoalCache.self, items: goals, familyRecordName: family)
        }
    }
}

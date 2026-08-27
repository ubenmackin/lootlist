//
//  CacheService+Upserts.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import Foundation
import os
import SwiftData

// MARK: - Single-Record Upserts & Gem Transactions

extension CacheService {
    func logFamilyMismatch(
        action: String,
        entityName: String,
        recordName: String,
        requestedFamily: String,
        actualFamily: String
    ) {
        logger.warning(
            """
            \(action, privacy: .public) \(entityName, privacy: .public) \
            \(recordName, privacy: .private): requested=\
            \(requestedFamily, privacy: .private) actual=\
            \(actualFamily, privacy: .private)
            """
        )
        #if DEBUG
            toastManager?.show(message: "DEBUG: \(entityName) family mismatch (\(requestedFamily) vs \(actualFamily))", type: .warning)
        #endif
    }

    private func applyUpsert<T: CacheMergeable>(
        _ domain: T.DomainModel,
        type _: T.Type,
        recordName: String,
        familyRecordName: String?,
        isServerSync: Bool,
        entityName: String
    ) {
        guard let context else { return }
        let descriptor = T.fetchDescriptor(familyRecordName: familyRecordName)
        do {
            if let existing = try context.fetch(descriptor).first(where: {
                $0.recordName == recordName
            }) {
                if let familyRecordName, !existing.familyRecordName.isEmpty,
                   existing.familyRecordName != familyRecordName
                {
                    logger.warning(
                        """
                        Scope mismatch ignoring upsert for \(entityName, privacy: .public) \
                        \(recordName, privacy: .private): existing=\
                        \(existing.familyRecordName, privacy: .private) expected=\
                        \(familyRecordName, privacy: .private)
                        """
                    )
                    return
                }
                T.apply(existing, from: domain, isServerSync: isServerSync)
            } else if let familyRecordName, !familyRecordName.isEmpty {
                let unscopedDescriptor = T.fetchDescriptor(familyRecordName: nil)
                if let legacyRow = try context.fetch(unscopedDescriptor).first(where: { $0.recordName == recordName }),
                   legacyRow.familyRecordName.isEmpty
                {
                    T.apply(legacyRow, from: domain, isServerSync: isServerSync)
                    logger.info("Repaired empty-family legacy \(entityName, privacy: .public) \(recordName, privacy: .private) → family \(familyRecordName, privacy: .private)")
                } else {
                    context.insert(T(from: domain))
                }
            } else {
                context.insert(T(from: domain))
            }
        } catch {
            logger.error("Failed to fetch \(entityName, privacy: .public) for upsert \(recordName, privacy: .private): \(error, privacy: .private)")
            return
        }
        saveContext()
    }

    /// Single-record mutations ride the background writer so SwiftData work
    /// never runs on the main actor; the retained main-actor bodies serve only
    /// in-memory stores (unit/UI tests) and not-yet-migrated callers.
    func upsertQuest(_ quest: Quest, family familyRecordName: String? = nil, isServerSync: Bool = false) async {
        if let backgroundWriter {
            await backgroundWriter.upsertDomainModel(
                quest,
                type: QuestCache.self,
                familyRecordName: familyRecordName ?? quest.family.recordID.recordName,
                isServerSync: isServerSync
            )
        } else {
            upsertQuestOnMainActor(quest, family: familyRecordName, isServerSync: isServerSync)
        }
    }

    private func upsertQuestOnMainActor(_ quest: Quest, family familyRecordName: String?, isServerSync: Bool) {
        if let explicit = familyRecordName, explicit != quest.family.recordID.recordName {
            logFamilyMismatch(
                action: "Explicit family mismatch rejecting",
                entityName: "Quest upsert",
                recordName: quest.id.recordName,
                requestedFamily: explicit,
                actualFamily: quest.family.recordID.recordName
            )
            return
        }
        applyUpsert(
            quest,
            type: QuestCache.self,
            recordName: quest.id.recordName,
            familyRecordName: familyRecordName ?? quest.family.recordID.recordName,
            isServerSync: isServerSync,
            entityName: "Quest"
        )
    }

    func upsertProfile(_ profile: Profile, family familyRecordName: String? = nil, isServerSync: Bool = false) async {
        if let backgroundWriter {
            await backgroundWriter.upsertDomainModel(
                profile,
                type: ProfileCache.self,
                familyRecordName: familyRecordName ?? profile.family.recordID.recordName,
                isServerSync: isServerSync
            )
        } else {
            upsertProfileOnMainActor(profile, family: familyRecordName, isServerSync: isServerSync)
        }
    }

    private func upsertProfileOnMainActor(_ profile: Profile, family familyRecordName: String?, isServerSync: Bool) {
        if let explicit = familyRecordName, explicit != profile.family.recordID.recordName {
            logFamilyMismatch(
                action: "Explicit family mismatch rejecting",
                entityName: "Profile upsert",
                recordName: profile.id.recordName,
                requestedFamily: explicit,
                actualFamily: profile.family.recordID.recordName
            )
            return
        }
        applyUpsert(
            profile,
            type: ProfileCache.self,
            recordName: profile.id.recordName,
            familyRecordName: familyRecordName ?? profile.family.recordID.recordName,
            isServerSync: isServerSync,
            entityName: "Profile"
        )
    }

    func upsertQuestCompletion(_ completion: QuestCompletion, family familyRecordName: String? = nil, isServerSync: Bool = false) async {
        if let backgroundWriter {
            await backgroundWriter.upsertDomainModel(
                completion,
                type: QuestCompletionCache.self,
                familyRecordName: familyRecordName ?? completion.family.recordID.recordName,
                isServerSync: isServerSync
            )
        } else {
            upsertQuestCompletionOnMainActor(completion, family: familyRecordName, isServerSync: isServerSync)
        }
    }

    private func upsertQuestCompletionOnMainActor(_ completion: QuestCompletion, family familyRecordName: String?, isServerSync: Bool) {
        if let explicit = familyRecordName, explicit != completion.family.recordID.recordName {
            logFamilyMismatch(
                action: "Explicit family mismatch rejecting",
                entityName: "QuestCompletion upsert",
                recordName: completion.id.recordName,
                requestedFamily: explicit,
                actualFamily: completion.family.recordID.recordName
            )
            return
        }
        applyUpsert(
            completion,
            type: QuestCompletionCache.self,
            recordName: completion.id.recordName,
            familyRecordName: familyRecordName ?? completion.family.recordID.recordName,
            isServerSync: isServerSync,
            entityName: "QuestCompletion"
        )
    }

    func upsertQuestTemplate(_ template: QuestTemplate, family familyRecordName: String? = nil, isServerSync: Bool = false) async {
        if let backgroundWriter {
            await backgroundWriter.upsertDomainModel(
                template,
                type: QuestTemplateCache.self,
                familyRecordName: familyRecordName ?? template.family.recordID.recordName,
                isServerSync: isServerSync
            )
        } else {
            upsertQuestTemplateOnMainActor(template, family: familyRecordName, isServerSync: isServerSync)
        }
    }

    private func upsertQuestTemplateOnMainActor(_ template: QuestTemplate, family familyRecordName: String?, isServerSync: Bool) {
        if let explicit = familyRecordName, explicit != template.family.recordID.recordName {
            logFamilyMismatch(
                action: "Explicit family mismatch rejecting",
                entityName: "QuestTemplate upsert",
                recordName: template.id.recordName,
                requestedFamily: explicit,
                actualFamily: template.family.recordID.recordName
            )
            return
        }
        applyUpsert(
            template,
            type: QuestTemplateCache.self,
            recordName: template.id.recordName,
            familyRecordName: familyRecordName ?? template.family.recordID.recordName,
            isServerSync: isServerSync,
            entityName: "QuestTemplate"
        )
    }

    func upsertFamily(_ family: Family, isServerSync: Bool = false) async {
        if let backgroundWriter {
            await backgroundWriter.upsertDomainModel(family, type: FamilyCache.self, familyRecordName: nil, isServerSync: isServerSync)
        } else {
            upsertFamilyOnMainActor(family, isServerSync: isServerSync)
        }
    }

    private func upsertFamilyOnMainActor(_ family: Family, isServerSync: Bool) {
        applyUpsert(family, type: FamilyCache.self, recordName: family.id.recordName, familyRecordName: nil, isServerSync: isServerSync, entityName: "Family")
    }

    func upsertLedgerEntry(_ entry: LedgerEntry, family familyRecordName: String? = nil, isServerSync: Bool = false) async {
        if let backgroundWriter {
            await backgroundWriter.upsertDomainModel(
                entry,
                type: LedgerEntryCache.self,
                familyRecordName: familyRecordName ?? entry.family.recordID.recordName,
                isServerSync: isServerSync
            )
        } else {
            upsertLedgerEntryOnMainActor(entry, family: familyRecordName, isServerSync: isServerSync)
        }
    }

    private func upsertLedgerEntryOnMainActor(_ entry: LedgerEntry, family familyRecordName: String?, isServerSync: Bool) {
        if let explicit = familyRecordName, explicit != entry.family.recordID.recordName {
            logFamilyMismatch(
                action: "Explicit family mismatch rejecting",
                entityName: "LedgerEntry upsert",
                recordName: entry.id.recordName,
                requestedFamily: explicit,
                actualFamily: entry.family.recordID.recordName
            )
            return
        }
        applyUpsert(
            entry,
            type: LedgerEntryCache.self,
            recordName: entry.id.recordName,
            familyRecordName: familyRecordName ?? entry.family.recordID.recordName,
            isServerSync: isServerSync,
            entityName: "LedgerEntry"
        )
    }

    func upsertAllowancePeriod(_ period: AllowancePeriod, family familyRecordName: String? = nil, isServerSync: Bool = false) async {
        if let backgroundWriter {
            await backgroundWriter.upsertDomainModel(
                period,
                type: AllowancePeriodCache.self,
                familyRecordName: familyRecordName ?? period.family.recordID.recordName,
                isServerSync: isServerSync
            )
        } else {
            upsertAllowancePeriodOnMainActor(period, family: familyRecordName, isServerSync: isServerSync)
        }
    }

    private func upsertAllowancePeriodOnMainActor(_ period: AllowancePeriod, family familyRecordName: String?, isServerSync: Bool) {
        if let explicit = familyRecordName, explicit != period.family.recordID.recordName {
            logFamilyMismatch(
                action: "Explicit family mismatch rejecting",
                entityName: "AllowancePeriod upsert",
                recordName: period.id.recordName,
                requestedFamily: explicit,
                actualFamily: period.family.recordID.recordName
            )
            return
        }
        applyUpsert(
            period,
            type: AllowancePeriodCache.self,
            recordName: period.id.recordName,
            familyRecordName: familyRecordName ?? period.family.recordID.recordName,
            isServerSync: isServerSync,
            entityName: "AllowancePeriod"
        )
    }

    func upsertAchievement(_ achievement: Achievement, family familyRecordName: String? = nil, isServerSync: Bool = false) async {
        if let backgroundWriter {
            await backgroundWriter.upsertDomainModel(
                achievement,
                type: AchievementCache.self,
                familyRecordName: familyRecordName ?? achievement.family.recordID.recordName,
                isServerSync: isServerSync
            )
        } else {
            upsertAchievementOnMainActor(achievement, family: familyRecordName, isServerSync: isServerSync)
        }
    }

    private func upsertAchievementOnMainActor(_ achievement: Achievement, family familyRecordName: String?, isServerSync: Bool) {
        if let explicit = familyRecordName, explicit != achievement.family.recordID.recordName {
            logFamilyMismatch(
                action: "Explicit family mismatch rejecting",
                entityName: "Achievement upsert",
                recordName: achievement.id.recordName,
                requestedFamily: explicit,
                actualFamily: achievement.family.recordID.recordName
            )
            return
        }
        applyUpsert(
            achievement,
            type: AchievementCache.self,
            recordName: achievement.id.recordName,
            familyRecordName: familyRecordName ?? achievement.family.recordID.recordName,
            isServerSync: isServerSync,
            entityName: "Achievement"
        )
    }

    func upsertNotificationPreference(_ pref: NotificationPreference, family familyRecordName: String? = nil, isServerSync: Bool = false) async {
        if let backgroundWriter {
            await backgroundWriter.upsertDomainModel(
                pref,
                type: NotificationPreferenceCache.self,
                familyRecordName: familyRecordName ?? pref.family.recordID.recordName,
                isServerSync: isServerSync
            )
        } else {
            upsertNotificationPreferenceOnMainActor(pref, family: familyRecordName, isServerSync: isServerSync)
        }
    }

    private func upsertNotificationPreferenceOnMainActor(_ pref: NotificationPreference, family familyRecordName: String?, isServerSync: Bool) {
        if let explicit = familyRecordName, explicit != pref.family.recordID.recordName {
            logFamilyMismatch(
                action: "Explicit family mismatch rejecting",
                entityName: "NotificationPreference upsert",
                recordName: pref.id.recordName,
                requestedFamily: explicit,
                actualFamily: pref.family.recordID.recordName
            )
            return
        }
        applyUpsert(
            pref,
            type: NotificationPreferenceCache.self,
            recordName: pref.id.recordName,
            familyRecordName: familyRecordName ?? pref.family.recordID.recordName,
            isServerSync: isServerSync,
            entityName: "NotificationPreference"
        )
    }

    func upsertGemLedger(_ entry: GemLedger, family familyRecordName: String? = nil, isServerSync: Bool = false) async {
        if let backgroundWriter {
            await backgroundWriter.upsertDomainModel(
                entry,
                type: GemLedgerCache.self,
                familyRecordName: familyRecordName ?? entry.family.recordID.recordName,
                isServerSync: isServerSync
            )
        } else {
            upsertGemLedgerOnMainActor(entry, family: familyRecordName, isServerSync: isServerSync)
        }
    }

    private func upsertGemLedgerOnMainActor(_ entry: GemLedger, family familyRecordName: String?, isServerSync: Bool) {
        if let explicit = familyRecordName, explicit != entry.family.recordID.recordName {
            logFamilyMismatch(
                action: "Explicit family mismatch rejecting",
                entityName: "GemLedger upsert",
                recordName: entry.id.recordName,
                requestedFamily: explicit,
                actualFamily: entry.family.recordID.recordName
            )
            return
        }
        applyUpsert(
            entry,
            type: GemLedgerCache.self,
            recordName: entry.id.recordName,
            familyRecordName: familyRecordName ?? entry.family.recordID.recordName,
            isServerSync: isServerSync,
            entityName: "GemLedger"
        )
    }

    func upsertRewardEvent(_ event: RewardEvent, family familyRecordName: String? = nil, isServerSync: Bool = false) async {
        if let backgroundWriter {
            await backgroundWriter.upsertDomainModel(
                event,
                type: RewardEventCache.self,
                familyRecordName: familyRecordName ?? event.family.recordID.recordName,
                isServerSync: isServerSync
            )
        } else {
            upsertRewardEventOnMainActor(event, family: familyRecordName, isServerSync: isServerSync)
        }
    }

    private func upsertRewardEventOnMainActor(_ event: RewardEvent, family familyRecordName: String?, isServerSync: Bool) {
        if let explicit = familyRecordName, explicit != event.family.recordID.recordName {
            logFamilyMismatch(
                action: "Explicit family mismatch rejecting",
                entityName: "RewardEvent upsert",
                recordName: event.id.recordName,
                requestedFamily: explicit,
                actualFamily: event.family.recordID.recordName
            )
            return
        }
        applyUpsert(
            event,
            type: RewardEventCache.self,
            recordName: event.id.recordName,
            familyRecordName: familyRecordName ?? event.family.recordID.recordName,
            isServerSync: isServerSync,
            entityName: "RewardEvent"
        )
    }

    func upsertGoal(_ goal: Goal, family familyRecordName: String? = nil, isServerSync: Bool = false) async {
        if let backgroundWriter {
            await backgroundWriter.upsertDomainModel(
                goal,
                type: GoalCache.self,
                familyRecordName: familyRecordName ?? goal.family.recordID.recordName,
                isServerSync: isServerSync
            )
        } else {
            upsertGoalOnMainActor(goal, family: familyRecordName, isServerSync: isServerSync)
        }
    }

    private func upsertGoalOnMainActor(_ goal: Goal, family familyRecordName: String?, isServerSync: Bool) {
        if let explicit = familyRecordName, explicit != goal.family.recordID.recordName {
            logFamilyMismatch(
                action: "Explicit family mismatch rejecting",
                entityName: "Goal upsert",
                recordName: goal.id.recordName,
                requestedFamily: explicit,
                actualFamily: goal.family.recordID.recordName
            )
            return
        }
        applyUpsert(
            goal,
            type: GoalCache.self,
            recordName: goal.id.recordName,
            familyRecordName: familyRecordName ?? goal.family.recordID.recordName,
            isServerSync: isServerSync,
            entityName: "Goal"
        )
    }

    /// Batch upserts ledger entries and goals in one transaction.
    /// WHY: canonical grouped-family batch lives on BackgroundCacheActor via
    /// batchUpsertWithoutSave with isServerSync=false and single saveContext();
    /// this wrapper delegates there to avoid duplicating grouping, fan-out, and
    /// family-mismatch logic. In-memory/test stores coalesce via withBatch so
    /// only one main-context save fires, preserving deterministic IDs and FIFO.
    func batchUpsertLedgerEntriesAndGoals(
        ledgerEntries: [LedgerEntry],
        goals: [Goal],
        familyRecordName: String? = nil
    ) async {
        guard !ledgerEntries.isEmpty || !goals.isEmpty else { return }
        if let backgroundWriter {
            _ = await backgroundWriter.batchUpsertLedgerEntriesAndGoals(
                ledgerEntries: ledgerEntries,
                goals: goals,
                familyRecordName: familyRecordName
            )
            return
        }
        // WHY: in-memory fallback keeps the same single-save, isServerSync=false
        // contract via withBatch tight-loop; no grouped fan-out duplication.
        withBatch {
            for entry in ledgerEntries {
                let fam = familyRecordName ?? entry.family.recordID.recordName
                if let explicit = familyRecordName, explicit != entry.family.recordID.recordName {
                    logFamilyMismatch(
                        action: "Explicit family mismatch rejecting",
                        entityName: "LedgerEntry batch upsert",
                        recordName: entry.id.recordName,
                        requestedFamily: explicit,
                        actualFamily: entry.family.recordID.recordName
                    )
                    continue
                }
                applyUpsert(
                    entry,
                    type: LedgerEntryCache.self,
                    recordName: entry.id.recordName,
                    familyRecordName: fam,
                    isServerSync: false,
                    entityName: "LedgerEntry"
                )
            }
            for goal in goals {
                let fam = familyRecordName ?? goal.family.recordID.recordName
                if let explicit = familyRecordName, explicit != goal.family.recordID.recordName {
                    logFamilyMismatch(
                        action: "Explicit family mismatch rejecting",
                        entityName: "Goal batch upsert",
                        recordName: goal.id.recordName,
                        requestedFamily: explicit,
                        actualFamily: goal.family.recordID.recordName
                    )
                    continue
                }
                applyUpsert(
                    goal,
                    type: GoalCache.self,
                    recordName: goal.id.recordName,
                    familyRecordName: fam,
                    isServerSync: false,
                    entityName: "Goal"
                )
            }
        }
    }

    func upsertProfileAchievement(_ pa: ProfileAchievement, family familyRecordName: String? = nil, isServerSync: Bool = false) async {
        if let backgroundWriter {
            await backgroundWriter.upsertDomainModel(
                pa,
                type: ProfileAchievementCache.self,
                familyRecordName: familyRecordName ?? pa.family.recordID.recordName,
                isServerSync: isServerSync
            )
        } else {
            upsertProfileAchievementOnMainActor(pa, family: familyRecordName, isServerSync: isServerSync)
        }
    }

    private func upsertProfileAchievementOnMainActor(_ pa: ProfileAchievement, family familyRecordName: String?, isServerSync: Bool) {
        if let explicit = familyRecordName, explicit != pa.family.recordID.recordName {
            logFamilyMismatch(
                action: "Explicit family mismatch rejecting",
                entityName: "ProfileAchievement upsert",
                recordName: pa.id.recordName,
                requestedFamily: explicit,
                actualFamily: pa.family.recordID.recordName
            )
            return
        }
        applyUpsert(
            pa,
            type: ProfileAchievementCache.self,
            recordName: pa.id.recordName,
            familyRecordName: familyRecordName ?? pa.family.recordID.recordName,
            isServerSync: isServerSync,
            entityName: "ProfileAchievement"
        )
    }

    func removePhantomRewardEvent(recordName: String, family: String) async {
        if let backgroundWriter {
            await backgroundWriter.deleteByNameAndFamily(
                type: RewardEventCache.self,
                recordName: recordName,
                familyRecordName: family
            )
        } else {
            removePhantomRewardEventOnMainActor(recordName: recordName, family: family)
        }
    }

    private func removePhantomRewardEventOnMainActor(recordName: String, family: String) {
        deleteByNameAndFamily(RewardEventCache.self, recordName: recordName, familyRecordName: family)
    }

    /// Balance and ledger row mutate in one pass on the background writer so a
    /// failed save can never split them; the main-actor fallback keeps the same
    /// transactional pairing for in-memory stores.
    func applyGemDebit(profile: Profile, ledger: GemLedger) async {
        if let backgroundWriter {
            await backgroundWriter.applyGemDebit(profile: profile, ledger: ledger)
        } else {
            applyGemDebitOnMainActor(profile: profile, ledger: ledger)
        }
    }

    private func applyGemDebitOnMainActor(profile: Profile, ledger: GemLedger) {
        withBatch {
            upsertProfileOnMainActor(profile, family: nil, isServerSync: true)
            upsertGemLedgerOnMainActor(ledger, family: nil, isServerSync: true)
        }
    }

    func atomicallyApplyGemCredit(ledger: GemLedger, to profile: Profile) async -> Bool {
        if let backgroundWriter {
            return await backgroundWriter.atomicallyApplyGemCredit(ledger: ledger, to: profile)
        }
        return atomicallyApplyGemCreditOnMainActor(ledger: ledger, profile: profile)
    }

    private func atomicallyApplyGemCreditOnMainActor(ledger: GemLedger, profile: Profile) -> Bool {
        guard let context else { return false }
        guard sharedGemCreditPrepare(context: context, ledger: ledger, profile: profile) else {
            return false
        }
        return saveContext()
    }
}

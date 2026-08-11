//
//  QuestService.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
import os
import Synchronization

enum QuestServiceError: Error, Equatable, Sendable {
    case missingSession

    case alreadyCompleted

    case alreadyInFlight

    case alreadyResolved(String)

    case missingRecord(String)
}

@MainActor
@Observable
final class QuestService {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "QuestService")
    let cloudKit: any CloudKitServiceProtocol

    let xpService: XPService
    let notificationService: NotificationService?

    var cacheService: CacheService?
    var treasuryService: TreasuryService?
    var achievementService: AchievementService?

    /// The active session's app state, used to resolve the acting profile for
    /// privileged quest verification. Wired by `AppDependencies`; optional so
    /// read-only callers (tests) need not set it.
    var appState: AppState?

    let toastManager: ToastManager?

    var cloudKitReference: any CloudKitServiceProtocol {
        cloudKit
    }

    let calendar: Calendar = .iso8601UTC

    /// Record names of quests with a completion save currently in flight.
    /// Local double-submit guard: a second `markComplete` tap for the
    /// same quest while a save is pending is a no-op/toast instead of a
    /// duplicate write. Actor-safe via `Mutex`; entries are inserted
    /// before the optimistic write and released when the save settles.
    let inFlightCompletions = Mutex<Set<String>>([])

    init(cloudKit: any CloudKitServiceProtocol,
         xpService: XPService,
         notificationService: NotificationService? = nil,
         cacheService: CacheService? = nil,
         treasuryService: TreasuryService? = nil,
         toastManager: ToastManager? = nil,
         appState: AppState? = nil)
    {
        self.cloudKit = cloudKit
        self.xpService = xpService
        self.notificationService = notificationService
        self.cacheService = cacheService
        self.treasuryService = treasuryService
        self.appState = appState
        self.toastManager = toastManager
    }

    // MARK: - Quest Templates

    @discardableResult
    func createTemplate(name: String,
                        description: String = "",
                        defaultGold: Double,
                        xpReward: Int,
                        schedule: QuestSchedule = .weeklyFlexible,
                        specificDays: [String] = [],
                        targetCount: Int = 1,
                        isAllOrNothing: Bool = false,
                        approvalMode: ApprovalMode = .autoApprove,
                        createdBy: Profile,
                        family: Family) async throws -> QuestTemplate
    {
        // Privileged mutation: a QuestTemplate is a parent-authored artifact.
        // The acting profile resolved from the authenticated session must
        // match the caller-supplied creator's identity AND hold a parent
        // role (Guild Master / Ranger).
        guard let acting = appState?.currentProfile,
              acting.id == createdBy.id,
              acting.role.isParent
        else {
            throw FamilyServiceError.unauthorized
        }

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
        // Register the optimistic window so a background sync skips this row.
        let registry = cacheService?.inFlightRegistry
        await registry?.register(template.id.recordName)

        cacheService?.upsertQuestTemplate(template)
        do {
            let saved = try await cloudKit.save(template)
            cacheService?.upsertQuestTemplate(saved)
            await registry?.deregister(template.id.recordName)
            return saved
        } catch {
            // All-or-nothing is mirrored by the recovery wrapper: a brand-new
            // template has no pre-mutation snapshot, so the concurrent-edit
            // cascade (re-fetch / snapshot restore) falls back to invalidating
            // the phantom row, and `.notFound` never resurrects a deleted
            // record. The optimistic registration is released only here.
            await handleSaveFailure(
                recordID: template.id,
                fetchCurrentTag: {
                    self.cacheService?.fetchQuestTemplates(family: template.family.recordID.recordName)
                        .first(where: { $0.recordName == template.id.recordName })?.changeTag
                },
                upsert: { self.cacheService?.upsertQuestTemplate($0) },
                invalidate: { self.cacheService?.invalidateQuestTemplate(recordName: $0) },
                error: error
            )
            await registry?.deregister(template.id.recordName)
            throw error
        }
    }

    @discardableResult
    func updateTemplate(_ template: QuestTemplate) async throws -> QuestTemplate {
        // Privileged mutation: editing a QuestTemplate is parent-only. The
        // acting profile resolved from the authenticated session must hold a
        // parent role (Guild Master / Ranger).
        guard let acting = appState?.currentProfile,
              acting.role.isParent
        else {
            throw FamilyServiceError.unauthorized
        }

        let name = template.id.recordName
        let snapshot = cacheService?.fetchQuestTemplates(family: template.family.recordID.recordName).first(where: { $0.recordName == name })

        let preMutationChangeTag = snapshot?.changeTag
        // changeTag rehydrated from cache row per toX(zoneID:), safe for use in ConcurrentEditDetector.
        let snapshotTemplate: QuestTemplate? = snapshot?.toQuestTemplate(zoneID: cloudKit.resolvedZoneID)

        // Register the optimistic window so a background sync skips this row.
        let registry = cacheService?.inFlightRegistry
        await registry?.register(name)

        cacheService?.upsertQuestTemplate(template)
        do {
            let saved = try await cloudKit.save(template)
            cacheService?.upsertQuestTemplate(saved)
            await registry?.deregister(name)
            return saved
        } catch {
            await handleSaveFailure(
                recordID: template.id,
                preMutationChangeTag: preMutationChangeTag,
                snapshot: snapshotTemplate,
                fetchCurrentTag: { self.cacheService?.fetchQuestTemplates(family: template.family.recordID.recordName)
                    .first(where: { $0.recordName == name })?.changeTag
                },
                upsert: { self.cacheService?.upsertQuestTemplate($0) },
                invalidate: { self.cacheService?.invalidateQuestTemplate(recordName: $0) },
                error: error
            )
            await registry?.deregister(name)
            throw error
        }
    }

    @discardableResult
    func deactivateTemplate(_ template: QuestTemplate) async throws -> QuestTemplate {
        // Privileged mutation: deactivating a QuestTemplate is parent-only.
        // The acting profile resolved from the authenticated session must
        // hold a parent role (Guild Master / Ranger).
        guard let acting = appState?.currentProfile,
              acting.role.isParent
        else {
            throw FamilyServiceError.unauthorized
        }

        var deactivated = template
        deactivated.isActive = false

        let name = template.id.recordName
        let snapshot = cacheService?.fetchQuestTemplates(family: template.family.recordID.recordName).first(where: { $0.recordName == name })

        let preMutationChangeTag = snapshot?.changeTag
        // changeTag rehydrated from cache row per toX(zoneID:), safe for use in ConcurrentEditDetector.
        let snapshotTemplate: QuestTemplate? = snapshot?.toQuestTemplate(zoneID: cloudKit.resolvedZoneID)

        // Register the optimistic window so a background sync skips this row.
        let registry = cacheService?.inFlightRegistry
        await registry?.register(name)

        cacheService?.upsertQuestTemplate(deactivated)
        do {
            let saved = try await cloudKit.save(deactivated)
            cacheService?.upsertQuestTemplate(saved)
            await registry?.deregister(name)
            return saved
        } catch {
            await handleSaveFailure(
                recordID: template.id,
                preMutationChangeTag: preMutationChangeTag,
                snapshot: snapshotTemplate,
                fetchCurrentTag: { self.cacheService?.fetchQuestTemplates(family: template.family.recordID.recordName)
                    .first(where: { $0.recordName == name })?.changeTag
                },
                upsert: { self.cacheService?.upsertQuestTemplate($0) },
                invalidate: { self.cacheService?.invalidateQuestTemplate(recordName: $0) },
                error: error
            )
            await registry?.deregister(name)
            throw error
        }
    }

    /// Cache-first read. Background refresh handled by SyncEngine via push notifications.
    func fetchTemplates(family: Family) async throws -> [QuestTemplate] {
        if let cache = cacheService {
            let familyName = family.id.recordName
            let cached = cache.fetchQuestTemplates(family: familyName)
            if !cached.isEmpty, cache.isCacheFresh(familyRecordName: familyName, type: .questTemplate) {
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
        // Privileged mutation: assigning a quest grants future gold/XP to
        // another profile. The acting profile resolved from the authenticated
        // session must match the caller-supplied creator's identity AND hold
        // a parent role (Guild Master / Ranger).
        guard let acting = appState?.currentProfile,
              acting.id == createdBy.id,
              acting.role.isParent
        else {
            throw FamilyServiceError.unauthorized
        }

        let payoutDay = assignee.payoutDay ?? family.payoutDay
        let normalizedWeek = WeekMath.startOfWeek(for: weekOf, payoutDay: payoutDay)

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

        // Register the optimistic window so a background sync skips this row.
        let registry = cacheService?.inFlightRegistry
        await registry?.register(quest.id.recordName)

        // Optimistic local write first
        cacheService?.upsertQuest(quest)

        do {
            let saved = try await cloudKit.save(quest)
            cacheService?.upsertQuest(saved)
            sendAssignmentNotification(to: assignee, questName: questName)
            await registry?.deregister(quest.id.recordName)
            return saved
        } catch {
            await handleSaveFailure(
                recordID: quest.id,
                fetchCurrentTag: { self.cacheService?.fetchQuests(family: family.id.recordName)
                    .first(where: { $0.recordName == quest.id.recordName })?.changeTag
                },
                upsert: { self.cacheService?.upsertQuest($0) },
                invalidate: { self.cacheService?.invalidateQuest(recordName: $0) },
                error: error
            )
            await registry?.deregister(quest.id.recordName)
            throw error
        }
    }

    @discardableResult
    func updateQuest(_ quest: Quest) async throws -> Quest {
        // Privileged mutation: editing a quest's assignments is parent-only.
        // The acting profile resolved from the authenticated session must
        // hold a parent role (Guild Master / Ranger).
        guard let acting = appState?.currentProfile,
              acting.role.isParent
        else {
            throw FamilyServiceError.unauthorized
        }

        let name = quest.id.recordName
        let snapshot = cacheService?.fetchQuests(family: quest.family.recordID.recordName)
            .first(where: { $0.recordName == name })

        let preMutationChangeTag = snapshot?.changeTag
        // changeTag rehydrated from cache row per toX(zoneID:), safe for use in ConcurrentEditDetector.
        let snapshotQuest: Quest? = snapshot?.toQuest(zoneID: cloudKit.resolvedZoneID)

        // Register the optimistic window so a background sync skips this row.
        let registry = cacheService?.inFlightRegistry
        await registry?.register(name)

        cacheService?.upsertQuest(quest)
        do {
            let saved = try await cloudKit.save(quest)
            cacheService?.upsertQuest(saved)
            await registry?.deregister(name)
            return saved
        } catch {
            await handleSaveFailure(
                recordID: quest.id,
                preMutationChangeTag: preMutationChangeTag,
                snapshot: snapshotQuest,
                fetchCurrentTag: { self.cacheService?.fetchQuests(family: quest.family.recordID.recordName)
                    .first(where: { $0.recordName == name })?.changeTag
                },
                upsert: { self.cacheService?.upsertQuest($0) },
                invalidate: { self.cacheService?.invalidateQuest(recordName: $0) },
                error: error
            )
            await registry?.deregister(name)
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
        // Privileged mutation: assigning a quick quest grants future gold/XP
        // to another profile. The acting profile resolved from the
        // authenticated session must match the caller-supplied creator's
        // identity AND hold a parent role (Guild Master / Ranger).
        guard let acting = appState?.currentProfile,
              acting.id == createdBy.id,
              acting.role.isParent
        else {
            throw FamilyServiceError.unauthorized
        }

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

        let payoutDay = assignee.payoutDay ?? family.payoutDay
        let normalizedWeek = WeekMath.startOfWeek(for: weekOf, payoutDay: payoutDay)

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

        // Register the optimistic window so a background sync skips this row.
        let registry = cacheService?.inFlightRegistry
        await registry?.register(quest.id.recordName)

        // Optimistic local write first
        cacheService?.upsertQuest(quest)

        do {
            let saved = try await cloudKit.save(quest)
            cacheService?.upsertQuest(saved)
            sendAssignmentNotification(to: assignee, questName: name)
            await registry?.deregister(quest.id.recordName)
            return saved
        } catch {
            await handleSaveFailure(
                recordID: quest.id,
                fetchCurrentTag: { self.cacheService?.fetchQuests(family: family.id.recordName)
                    .first(where: { $0.recordName == quest.id.recordName })?.changeTag
                },
                upsert: { self.cacheService?.upsertQuest($0) },
                invalidate: { self.cacheService?.invalidateQuest(recordName: $0) },
                error: error
            )
            // The deactivated ad-hoc template was already persisted before
            // the quest save; invalidate it too so it doesn't orphan.
            cacheService?.invalidateQuestTemplate(recordName: adhocTemplate.id.recordName)
            await registry?.deregister(quest.id.recordName)
            throw error
        }
    }

    func unassignQuest(_ quest: Quest) async throws {
        // Privileged mutation: removing a quest is parent-only, except the
        // quest's own assignee may unassign their assignment (self-service
        // cleanup when a hero leaves the family). A non-parent stranger
        // cannot unassign another hero's quest.
        guard let acting = appState?.currentProfile,
              acting.role.isParent || acting.id == quest.assignee.recordID
        else {
            throw FamilyServiceError.unauthorized
        }

        // Carry-forward suppression tombstone. The weekly carry-forward engine
        // replants `(template, assignee)` pairs from previous-week rows, and
        // its idempotency gate only sees current-week quests — so a hard
        // delete of a carried-forward quest would let the next run silently
        // resurrect the very quest the parent just removed. When a parent
        // unassigns a quest the engine could re-create (current carry window +
        // backing template still active), keep the row with `active == false`
        // instead of deleting it: the retained row occupies the pair in the
        // engine's idempotency gate for this week only, is invisible to every
        // active-quest query, and becomes an ordinary carry-forward source on
        // week rollover — the suppression never leaks past the current carry
        // window. Hero self-service unassigns and removals the engine cannot
        // re-create (off-window, inactive or gone template — Quick Create and
        // roster cleanup) stay hard deletes.
        if acting.role.isParent, isCarryForwardSuppressible(quest) {
            var tombstone = quest
            tombstone.active = false

            let name = quest.id.recordName
            let snapshot = cacheService?.fetchQuests(family: quest.family.recordID.recordName)
                .first(where: { $0.recordName == name })

            let preMutationChangeTag = snapshot?.changeTag
            // changeTag rehydrated from cache row per toX(zoneID:), safe for use in ConcurrentEditDetector.
            let snapshotQuest: Quest? = snapshot?.toQuest(zoneID: cloudKit.resolvedZoneID)

            // Register the optimistic window so a background sync skips this row.
            let registry = cacheService?.inFlightRegistry
            await registry?.register(name)

            cacheService?.upsertQuest(tombstone)
            do {
                let saved = try await cloudKit.save(tombstone)
                cacheService?.upsertQuest(saved)
                await registry?.deregister(name)
                return
            } catch {
                await handleSaveFailure(
                    recordID: quest.id,
                    preMutationChangeTag: preMutationChangeTag,
                    snapshot: snapshotQuest,
                    fetchCurrentTag: { self.cacheService?.fetchQuests(family: quest.family.recordID.recordName)
                        .first(where: { $0.recordName == name })?.changeTag
                    },
                    upsert: { self.cacheService?.upsertQuest($0) },
                    invalidate: { self.cacheService?.invalidateQuest(recordName: $0) },
                    error: error
                )
                await registry?.deregister(name)
                throw error
            }
        }

        let name = quest.id.recordName
        let snapshot = cacheService?.fetchQuests(family: quest.family.recordID.recordName)
            .first(where: { $0.recordName == name })

        let preMutationChangeTag = snapshot?.changeTag
        // changeTag rehydrated from cache row per toX(zoneID:), safe for use in ConcurrentEditDetector.
        let snapshotQuest: Quest? = snapshot?.toQuest(zoneID: cloudKit.resolvedZoneID)

        // Register the optimistic window so a background sync skips this row.
        let registry = cacheService?.inFlightRegistry
        await registry?.register(name)

        cacheService?.invalidateQuest(recordName: name)
        do {
            try await cloudKit.delete(quest.id)
            await registry?.deregister(name)
        } catch {
            await handleSaveFailure(
                recordID: quest.id,
                preMutationChangeTag: preMutationChangeTag,
                snapshot: snapshotQuest,
                fetchCurrentTag: { self.cacheService?.fetchQuests(family: quest.family.recordID.recordName)
                    .first(where: { $0.recordName == name })?.changeTag
                },
                upsert: { self.cacheService?.upsertQuest($0) },
                invalidate: { self.cacheService?.invalidateQuest(recordName: $0) },
                error: error
            )
            await registry?.deregister(name)
            throw error
        }
    }

    /// Cache-first read. On cold cache miss, falls back to a single synchronous
    /// CloudKit query to hydrate. Background ongoing refresh handled by
    /// SyncEngine via push notifications.
    func fetchActiveQuests(profile: Profile, weekOf: Date) async throws -> [Quest] {
        let range = QuestService.weekRange(for: weekOf, payoutDay: effectivePayoutDay(for: profile))

        // Cache-first: check local cache
        if let cache = cacheService {
            let profileName = profile.id.recordName
            let familyName = profile.family.recordID.recordName
            let cached = cache.fetchQuests(family: familyName, weekInRange: range)
                .filter { $0.assigneeRecordName == profileName && $0.isActive && range.contains($0.weekOf) }
            if !cached.isEmpty, cache.isCacheFresh(familyRecordName: familyName, type: .quest) {
                return cached.map { $0.toQuest(zoneID: cloudKit.resolvedZoneID) }
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
        let range = QuestService.weekRange(for: weekOf, payoutDay: family.payoutDay)

        if let cache = cacheService {
            let familyName = family.id.recordName
            let cached = cache.fetchQuests(family: familyName, weekInRange: range)
                .filter { $0.isActive && range.contains($0.weekOf) }
            if !cached.isEmpty, cache.isCacheFresh(familyRecordName: familyName, type: .quest) {
                return cached.map { $0.toQuest(zoneID: cloudKit.resolvedZoneID) }
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

    /// Deactivates uncompleted quests from past weeks whose payouts have been
    /// finalized, so they no longer appear on primary active quest views. The
    /// current week is never swept: a mid-week early payout finalizes the week's
    /// earnings but must not retire quests the hero is still completing.
    @discardableResult
    func sweepExpiredQuests(family: Family, currentWeekOf: Date) async throws -> [Quest] {
        guard let acting = appState?.currentProfile, acting.role.isParent else {
            return []
        }

        let familyName = family.id.recordName
        let normalizedCurrentWeek = WeekMath.startOfWeek(for: currentWeekOf, payoutDay: family.payoutDay)

        // Query allowance periods to identify weeks whose payouts have been completed (.paid)
        let allowancePeriods: [AllowancePeriod]
        if let cache = cacheService {
            allowancePeriods = cache.fetchAllowancePeriods(family: familyName)
                .map { $0.toAllowancePeriod(zoneID: cloudKit.resolvedZoneID) }
        } else {
            let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
            let predicate = NSPredicate(format: "family == %@", familyRef)
            allowancePeriods = await (try? cloudKit.query(AllowancePeriod.self, predicate: predicate)) ?? []
        }

        let paidWeeks = Set(allowancePeriods.filter { $0.status == .paid }.map { Calendar.iso8601UTC.startOfDay(for: $0.weekOf) })

        let allQuests: [Quest]
        if let cache = cacheService, cache.isCacheFresh(familyRecordName: familyName, type: .quest) {
            allQuests = cache.fetchQuests(family: familyName)
                .filter(\.isActive)
                .map { $0.toQuest(zoneID: cloudKit.resolvedZoneID) }
        } else {
            let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
            let predicate = NSPredicate(format: "family == %@", familyRef)
            allQuests = try await cloudKit.query(Quest.self, predicate: predicate)
                .filter(\.active)
        }

        var deactivated: [Quest] = []
        for var quest in allQuests {
            let questWeekStart = Calendar.iso8601UTC.startOfDay(for: quest.weekOf)
            // A quest is retired only when its week has both ended (a past week)
            // and been finalized by a payout. Requiring the week to be past is
            // what keeps a mid-week early payout — which marks the current week's
            // period .paid — from deactivating quests the hero is still on.
            if questWeekStart < normalizedCurrentWeek, paidWeeks.contains(questWeekStart) {
                quest.active = false
                cacheService?.upsertQuest(quest)
                do {
                    let saved = try await cloudKit.save(quest)
                    cacheService?.upsertQuest(saved)
                    deactivated.append(saved)
                } catch {
                    logger.error("Failed to deactivate expired quest \(quest.id.recordName, privacy: .public): \(error, privacy: .public)")
                }
            }
        }
        return deactivated
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

    func sendAssignmentNotification(to assignee: Profile, questName: String) {
        guard let notificationService else { return }
        Task { @Sendable [logger] in
            do {
                try await notificationService.send(
                    .questAssigned,
                    to: assignee,
                    title: "⚔️ New Quest Assigned!",
                    body: "You have been assigned '\(questName)'."
                )
            } catch {
                logger.error("Failed to send assignment notification: \(error, privacy: .public)")
            }
        }
    }

    func handleSaveFailure<T: CloudKitRecord>(
        recordID: CKRecord.ID,
        preMutationChangeTag: String? = nil,
        snapshot: T? = nil,
        fetchCurrentTag: @escaping () -> String?,
        upsert: (T) -> Void,
        invalidate: (String) -> Void,
        error: Error
    ) async {
        await OptimisticFailureHandler.handleSaveFailure(
            recordID: recordID,
            preMutationChangeTag: preMutationChangeTag,
            snapshot: snapshot,
            cloudKit: cloudKit,
            toastManager: toastManager,
            fetchCurrentTag: fetchCurrentTag,
            upsert: upsert,
            invalidate: invalidate,
            error: error
        )
    }

    static func startOfWeek(for date: Date, payoutDay: PayoutDay = .sunday) -> Date {
        WeekMath.startOfWeek(for: date, payoutDay: payoutDay)
    }

    static func mondayOfWeek(for date: Date) -> Date {
        WeekMath.mondayOfWeek(for: date)
    }

    static func weekRange(for date: Date, payoutDay: PayoutDay = .sunday) -> Range<Date> {
        WeekMath.weekRange(starting: startOfWeek(for: date, payoutDay: payoutDay))
    }

    /// Resolves the effective payout day a profile's quests bucket by: the
    /// profile's own override wins, then the family's configured payout day
    /// (read from the local cache when present), falling back to the
    /// backward-compatible Sunday default when unknown. Mirrors the write-path
    /// normalization in `assignQuest`/`assignQuickQuest` so reads bucket by the
    /// same cycle the stored `weekOf` values were normalized to.
    func effectivePayoutDay(for profile: Profile) -> PayoutDay {
        if let profilePayoutDay = profile.payoutDay {
            return profilePayoutDay
        }
        let familyRecordName = profile.family.recordID.recordName
        if !familyRecordName.isEmpty,
           let familyCache = cacheService?.fetchFamily(recordName: familyRecordName),
           let familyPayoutDay = familyCache.payoutDayEnum
        {
            return familyPayoutDay
        }
        return .sunday
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

    /// True when `quest` is exactly what the weekly carry-forward engine would
    /// re-create after a hard delete: a removal from the current carry window
    /// whose backing template is still active. Mirrors the engine's own source
    /// filter (`activeTemplates`) from the same cache, day-normalized with the
    /// assignee's effective payout day — the same cycle `assignQuest` buckets
    /// the quest's `weekOf` into. Quick Create quests (inactive ad-hoc
    /// templates) and roster-cleanup quests (template gone) fail this check and
    /// keep the plain hard-delete semantics, since the engine can never re-create
    /// them in the first place.
    private func isCarryForwardSuppressible(_ quest: Quest) -> Bool {
        let assigneePayoutDay = cacheService?.fetchProfile(recordName: quest.assignee.recordID.recordName)?.payoutDayEnum
            ?? cacheService?.fetchFamily(recordName: quest.family.recordID.recordName)?.payoutDayEnum
            ?? .sunday
        let currentWeekStart = WeekMath.startOfWeek(for: Date(), payoutDay: assigneePayoutDay)
        guard Calendar.iso8601UTC.startOfDay(for: quest.weekOf) == Calendar.iso8601UTC.startOfDay(for: currentWeekStart) else {
            return false
        }
        return cacheService?.fetchQuestTemplates(family: quest.family.recordID.recordName)
            .contains { $0.recordName == quest.template.recordID.recordName && $0.isActive } ?? false
    }
}

//
//  QuestService.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
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
    let cloudKit: CloudKitService

    let xpService: XPService
    let notificationService: NotificationService?

    var cacheService: CacheService?
    var treasuryService: TreasuryService?

    var toastManager: ToastManager?

    var cloudKitReference: CloudKitService {
        cloudKit
    }

    let calendar: Calendar = .iso8601UTC

    /// Record names of quests with a completion save currently in flight.
    /// Local double-submit guard: a second `markComplete` tap for the
    /// same quest while a save is pending is a no-op/toast instead of a
    /// duplicate write. Actor-safe via `Mutex`; entries are inserted
    /// before the optimistic write and released when the save settles.
    let inFlightCompletions = Mutex<Set<String>>([])

    init(cloudKit: CloudKitService,
         xpService: XPService,
         notificationService: NotificationService? = nil)
    {
        self.cloudKit = cloudKit
        self.xpService = xpService
        self.notificationService = notificationService
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
            cacheService?.invalidateQuestTemplate(recordName: template.id.recordName)
            await registry?.deregister(template.id.recordName)
            throw error
        }
    }

    @discardableResult
    func updateTemplate(_ template: QuestTemplate) async throws -> QuestTemplate {
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
                .filter { $0.assigneeRecordName == profileName && $0.isActive }
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
                .filter(\.isActive)
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
    func handleConcurrentEdit(
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

    func showErrorToast(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        toastManager?.show(message: message, type: .error)
    }

    func sendAssignmentNotification(to assignee: Profile, questName: String) {
        guard let notificationService else { return }
        Task { @Sendable in
            try? await notificationService.send(
                .questAssigned,
                to: assignee,
                title: "⚔️ New Quest Assigned!",
                body: "You have been assigned '\(questName)'."
            )
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
        // A `.notFound` from `cloudKit.save` is definitive evidence of a
        // concurrent delete — CloudKitService wraps `CKError.unknownItem`
        // (and zone/constraint variants) into `.notFound` when the record no
        // longer exists server-side. Restoring the pre-mutation snapshot would
        // resurrect a record that another device deleted ("zombie quest"), so
        // invalidate instead; the next sync pass confirms the absence. This
        // branch runs BEFORE the changeTag-based detector because a concurrent
        // deletion also removes the cached row, making `fetchCurrentTag` nil
        // and signal 2 silently false — `.notFound` is the unambiguous signal.
        if let serviceError = error as? CloudKitServiceError,
           case .notFound = serviceError
        {
            invalidate(recordID.recordName)
            showErrorToast(error)
            return
        }

        if handleConcurrentEdit(
            preMutationChangeTag: preMutationChangeTag,
            fetchCurrent: fetchCurrentTag,
            error: error
        ) {
            if let fresh = try? await cloudKit.fetch(T.self, id: recordID) {
                upsert(fresh)
            } else if let snapshot {
                upsert(snapshot)
            } else {
                invalidate(recordID.recordName)
            }
        } else {
            if let snapshot {
                upsert(snapshot)
            } else {
                invalidate(recordID.recordName)
            }
            showErrorToast(error)
        }
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
}

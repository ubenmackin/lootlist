//
//  QuestCompletionCache.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
import SwiftData

@Model
final class QuestCompletionCache: FamilyScopedCache, CacheMergeable {
    typealias DomainModel = QuestCompletion

    #Index<QuestCompletionCache>([\.familyRecordName, \.recordName], [\.familyRecordName, \.completerRecordName, \.questRecordName, \.weekOf])

    var recordName: String
    var questRecordName: String
    var familyRecordName: String
    var completerRecordName: String
    var completedDate: Date
    var weekOf: Date
    var verificationStatus: String
    var approvalMode: String
    var verifiedByRecordName: String?
    var verifiedDate: Date?
    /// Cached copy of `QuestCompletion.xpCredited` (the per-record XP-credit
    /// idempotency marker). Synced via `update(from:)`/`toQuestCompletion(zoneID:)`
    /// so a reward-step re-run can detect an already-settled completion.
    var xpCredited: Int?
    var changeTag: String?
    var encodedSystemFields: Data?
    var sourceZoneName: String?
    var sourceZoneOwnerName: String?
    var sourceDatabaseScope: String?

    var verificationStatusEnum: VerificationStatus? {
        VerificationStatus(rawValue: verificationStatus)
    }

    var approvalModeEnum: ApprovalMode? {
        ApprovalMode(rawValue: approvalMode)
    }

    var isApproved: Bool {
        verificationStatusEnum == .verified || verificationStatusEnum == .autoApproved
    }

    func wasCompleted(on date: Date) -> Bool {
        Calendar.iso8601UTC.isDate(completedDate, inSameDayAs: date)
    }

    init(recordName: String,
         questRecordName: String,
         familyRecordName: String,
         completerRecordName: String,
         completedDate: Date,
         weekOf: Date,
         verificationStatus: String,
         approvalMode: String,
         verifiedByRecordName: String?,
         verifiedDate: Date?,
         xpCredited: Int? = nil,
         changeTag: String? = nil,
         encodedSystemFields: Data? = nil,
         sourceZoneName: String? = nil,
         sourceZoneOwnerName: String? = nil,
         sourceDatabaseScope: String? = nil)
    {
        self.recordName = recordName
        self.questRecordName = questRecordName
        self.familyRecordName = familyRecordName
        self.completerRecordName = completerRecordName
        self.completedDate = completedDate
        self.weekOf = weekOf
        self.verificationStatus = verificationStatus
        self.approvalMode = approvalMode
        self.verifiedByRecordName = verifiedByRecordName
        self.verifiedDate = verifiedDate
        self.xpCredited = xpCredited
        self.changeTag = changeTag
        self.encodedSystemFields = encodedSystemFields
        self.sourceZoneName = sourceZoneName
        self.sourceZoneOwnerName = sourceZoneOwnerName
        self.sourceDatabaseScope = sourceDatabaseScope
    }

    convenience init(from completion: QuestCompletion) {
        let derivedApprovalMode: ApprovalMode = (completion.verificationStatus == .autoApproved)
            ? .autoApprove
            : .parentVerify
        self.init(
            recordName: completion.id.recordName,
            questRecordName: completion.quest.recordID.recordName,
            familyRecordName: completion.family.recordID.recordName,
            completerRecordName: completion.completedBy.recordID.recordName,
            completedDate: completion.completedDate,
            weekOf: completion.weekOf,
            verificationStatus: completion.verificationStatus.rawValue,
            approvalMode: derivedApprovalMode.rawValue,
            verifiedByRecordName: completion.verifiedBy?.recordID.recordName,
            verifiedDate: completion.verifiedDate,
            xpCredited: completion.xpCredited
        )
        applySystemFields(from: completion)
    }

    // MARK: - CacheMergeable

    func update(from completion: QuestCompletion, isServerSync: Bool = false) {
        questRecordName = completion.quest.recordID.recordName
        familyRecordName = completion.family.recordID.recordName
        completerRecordName = completion.completedBy.recordID.recordName
        completedDate = completion.completedDate
        weekOf = completion.weekOf
        verificationStatus = completion.verificationStatus.rawValue
        approvalMode = (completion.verificationStatus == .autoApproved)
            ? ApprovalMode.autoApprove.rawValue
            : ApprovalMode.parentVerify.rawValue
        verifiedByRecordName = completion.verifiedBy?.recordID.recordName
        verifiedDate = completion.verifiedDate
        xpCredited = isServerSync ? (xpCredited ?? completion.xpCredited) : completion.xpCredited
        applySystemFields(from: completion, isServerSync: isServerSync)
    }

    static func fetchDescriptor(familyRecordName: String?) -> FetchDescriptor<QuestCompletionCache> {
        if let familyRecordName {
            return FetchDescriptor<QuestCompletionCache>(predicate: #Predicate { $0.familyRecordName == familyRecordName })
        }
        return FetchDescriptor<QuestCompletionCache>()
    }

    static func fetchDescriptor(recordName: String) -> FetchDescriptor<QuestCompletionCache> {
        FetchDescriptor<QuestCompletionCache>(predicate: #Predicate { $0.recordName == recordName })
    }

    static func fetchDescriptor(recordName: String, familyRecordName: String) -> FetchDescriptor<QuestCompletionCache> {
        FetchDescriptor<QuestCompletionCache>(predicate: #Predicate { $0.recordName == recordName && $0.familyRecordName == familyRecordName })
    }

    // MARK: - Family Predicates

    /// WHY single source: views share the family isolation boundary so store filtering never drifts.
    static func familyPredicate(familyRecordName: String) -> Predicate<QuestCompletionCache> {
        let targetFamily = familyRecordName
        return #Predicate<QuestCompletionCache> { $0.familyRecordName == targetFamily }
    }

    /// WHY single source: hero-scoped reads push family+completer to the store instead of scanning.
    static func completerPredicate(familyRecordName: String, completerRecordName: String) -> Predicate<QuestCompletionCache> {
        let targetFamily = familyRecordName
        let targetCompleter = completerRecordName
        return #Predicate<QuestCompletionCache> {
            $0.familyRecordName == targetFamily && $0.completerRecordName == targetCompleter
        }
    }

    /// WHY single source: detail screens scope to one quest within the family partition.
    static func questPredicate(familyRecordName: String, questRecordName: String) -> Predicate<QuestCompletionCache> {
        let targetFamily = familyRecordName
        let targetQuest = questRecordName
        return #Predicate<QuestCompletionCache> {
            $0.familyRecordName == targetFamily && $0.questRecordName == targetQuest
        }
    }

    /// WHY single source: the badge count shares the pending definition with no extra fetch.
    static func pendingPredicate(familyRecordName: String) -> Predicate<QuestCompletionCache> {
        let targetFamily = familyRecordName
        let pendingStatus = VerificationStatus.pending.rawValue
        return #Predicate<QuestCompletionCache> {
            $0.familyRecordName == targetFamily && $0.verificationStatus == pendingStatus
        }
    }

    /// WHY fail-closed: empty scope returns zero rows via the index, never an unscoped scan.
    static func emptyPredicate() -> Predicate<QuestCompletionCache> {
        #Predicate<QuestCompletionCache> { $0.familyRecordName == "__empty__" }
    }
}

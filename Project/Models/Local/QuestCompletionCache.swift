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
    @Attribute(.externalStorage) var encodedSystemFields: Data?
    var sourceZoneName: String?
    var sourceZoneOwnerName: String?
    var sourceDatabaseScope: String?

    var verificationStatusEnum: VerificationStatus? {
        VerificationStatus(rawValue: verificationStatus)
    }

    var approvalModeEnum: ApprovalMode? {
        ApprovalMode(rawValue: approvalMode)
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
            xpCredited: completion.xpCredited,
            changeTag: completion.changeTag,
            encodedSystemFields: completion.encodedSystemFields,
            sourceZoneName: completion.id.zoneID.zoneName,
            sourceZoneOwnerName: completion.id.zoneID.ownerName,
            sourceDatabaseScope: inferDatabaseScope(from: completion.id.zoneID)
        )
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
        xpCredited = completion.xpCredited
        changeTag = completion.changeTag
        sourceZoneName = completion.id.zoneID.zoneName
        sourceZoneOwnerName = completion.id.zoneID.ownerName
        sourceDatabaseScope = inferDatabaseScope(from: completion.id.zoneID)
        if isServerSync, completion.encodedSystemFields != nil {
            encodedSystemFields = completion.encodedSystemFields
        }
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
}

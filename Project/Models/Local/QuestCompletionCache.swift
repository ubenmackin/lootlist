//
//  QuestCompletionCache.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import Foundation
import SwiftData

@Model
final class QuestCompletionCache: FamilyScopedCache {
    #Index<QuestCompletionCache>([\.familyRecordName, \.completerRecordName, \.questRecordName, \.weekOf])

    @Attribute(.unique) var recordName: String
    var questRecordName: String
    var familyRecordName: String
    var completerRecordName: String
    var completedDate: Date
    var weekOf: Date
    var verificationStatus: String
    var approvalMode: String
    var verifiedByRecordName: String?
    var verifiedDate: Date?
    var changeTag: String?

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
         changeTag: String? = nil)
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
        self.changeTag = changeTag
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
            changeTag: completion.changeTag
        )
    }
}

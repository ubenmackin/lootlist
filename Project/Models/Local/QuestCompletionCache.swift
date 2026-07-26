//
//  QuestCompletionCache.swift
//  LootList
//
//

import Foundation
import SwiftData

@Model
final class QuestCompletionCache {
    #Index<QuestCompletionCache>([\.familyRecordName], [\.questRecordName], [\.completerRecordName], [\.weekOf])

    @Attribute(.unique) var recordName: String
    var questRecordName: String
    var familyRecordName: String
    var completerRecordName: String
    var completedDate: Date
    var weekOf: Date
    var verificationStatus: String
    var verifiedByRecordName: String?
    var verifiedDate: Date?

    init(recordName: String,
         questRecordName: String,
         familyRecordName: String,
         completerRecordName: String,
         completedDate: Date,
         weekOf: Date,
         verificationStatus: String,
         verifiedByRecordName: String?,
         verifiedDate: Date?)
    {
        self.recordName = recordName
        self.questRecordName = questRecordName
        self.familyRecordName = familyRecordName
        self.completerRecordName = completerRecordName
        self.completedDate = completedDate
        self.weekOf = weekOf
        self.verificationStatus = verificationStatus
        self.verifiedByRecordName = verifiedByRecordName
        self.verifiedDate = verifiedDate
    }

    /// Creates a cache entry from a CloudKit `QuestCompletion` model.
    convenience init(from completion: QuestCompletion) {
        self.init(
            recordName: completion.id.recordName,
            questRecordName: completion.quest.recordID.recordName,
            familyRecordName: completion.family.recordID.recordName,
            completerRecordName: completion.completedBy.recordID.recordName,
            completedDate: completion.completedDate,
            weekOf: completion.weekOf,
            verificationStatus: completion.verificationStatus.rawValue,
            verifiedByRecordName: completion.verifiedBy?.recordID.recordName,
            verifiedDate: completion.verifiedDate
        )
    }
}

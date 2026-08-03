//
//  Quest.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation

struct Quest: Identifiable, Equatable, Sendable {
    static let recordType: String = "Quest"

    let id: CKRecord.ID

    /// Server-owned CloudKit change tag captured on read for cache-staleness
    /// checks. Not authored locally — `toRecord()` does not stamp this field.
    var changeTag: String?

    var template: CKRecord.Reference

    var assignee: CKRecord.Reference

    var goldReward: Double
    var xpReward: Int

    /// Monotonic per-quest total of XP already banked by the reward step.
    /// Server-authoritative and synced across family devices: the quest record
    /// is the shared XP-credit ledger, so two devices completing the same
    /// quest concurrently are capped by the same banked total (security
    /// remediation, finding 2). Written ONLY via the change-tag CAS path in
    /// `QuestService` — nothing else mutates this field.
    var xpBanked: Int = 0

    var rarity: QuestRarity {
        QuestRarity.from(xp: xpReward)
    }

    var scheduleType: QuestSchedule

    var targetCount: Int

    var isAllOrNothing: Bool

    var approvalMode: ApprovalMode

    var active: Bool

    var weekOf: Date

    var createdBy: CKRecord.Reference

    var family: CKRecord.Reference

    var name: String?
    var descriptionText: String?

    var displayName: String {
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            return name
        }
        // Legacy fallback for Quests with nil name (pre-backfill).
        // Defense-in-depth stamping in QuestService also catches these at read time.
        let templateID = template.recordID.recordName
        if templateID.count > 6 {
            return "Quest \(templateID.suffix(6))"
        }
        return "Quest \(templateID)"
    }

    var displayDescription: String {
        descriptionText ?? ""
    }

    init(record: CKRecord) throws {
        guard record.recordType == Self.recordType else {
            throw CKDecodingError.unexpectedRecordType(expected: Self.recordType,
                                                       actual: record.recordType)
        }
        id = record.recordID
        changeTag = record.recordChangeTag

        guard let template = record["template"] as? CKRecord.Reference else {
            throw CKDecodingError.missingField("template")
        }
        self.template = template

        guard let assignee = record["assignee"] as? CKRecord.Reference else {
            throw CKDecodingError.missingField("assignee")
        }
        self.assignee = assignee

        goldReward = try record.extract("goldReward")
        xpReward = try record.extract("xpReward")
        xpBanked = record.extractOptional("xpBanked") ?? 0

        let scheduleRaw = record.extractOptional("scheduleType") ?? QuestSchedule.weeklyFlexible.rawValue
        scheduleType = QuestSchedule(rawValue: scheduleRaw) ?? .weeklyFlexible

        targetCount = record.extractOptional("targetCount") ?? 1

        isAllOrNothing = record.bool(forKey: "isAllOrNothing", default: false)

        guard let approvalRaw: String = record.extractOptional("approvalMode"),
              let approvalMode = ApprovalMode(rawValue: approvalRaw)
        else {
            throw CKDecodingError.missingField("approvalMode")
        }
        self.approvalMode = approvalMode

        active = record.bool(forKey: "active", default: true)

        guard let weekOf = record["weekOf"] as? Date else {
            throw CKDecodingError.missingField("weekOf")
        }
        self.weekOf = weekOf

        guard let createdBy = record["createdBy"] as? CKRecord.Reference else {
            throw CKDecodingError.missingField("createdBy")
        }
        self.createdBy = createdBy

        guard let family = record["family"] as? CKRecord.Reference else {
            throw CKDecodingError.missingField("family")
        }
        self.family = family

        name = record.extractOptional("name")
        descriptionText = record.extractOptional("descriptionText")
    }

    func toRecord() -> CKRecord {
        let record = CKRecord(recordType: Self.recordType, recordID: id)
        record["template"] = template as CKRecordValue
        record["assignee"] = assignee as CKRecordValue
        record["goldReward"] = goldReward as CKRecordValue
        record["xpReward"] = xpReward as CKRecordValue
        record["xpBanked"] = xpBanked as CKRecordValue
        record["scheduleType"] = scheduleType.rawValue as CKRecordValue
        record["targetCount"] = targetCount as CKRecordValue
        record["isAllOrNothing"] = isAllOrNothing as CKRecordValue
        record["approvalMode"] = approvalMode.rawValue as CKRecordValue
        record["active"] = active as CKRecordValue
        record["weekOf"] = weekOf as CKRecordValue
        record["createdBy"] = createdBy as CKRecordValue
        record["family"] = family as CKRecordValue
        if let name {
            record["name"] = name as CKRecordValue
        }
        if let descriptionText {
            record["descriptionText"] = descriptionText as CKRecordValue
        }
        return record
    }

    init(template: CKRecord.Reference,
         assignee: CKRecord.Reference,
         goldReward: Double,
         xpReward: Int,
         scheduleType: QuestSchedule,
         targetCount: Int = 1,
         isAllOrNothing: Bool = false,
         approvalMode: ApprovalMode = .autoApprove,
         weekOf: Date,
         createdBy: CKRecord.Reference,
         family: CKRecord.Reference,
         name: String? = nil,
         descriptionText: String? = nil,
         xpBanked: Int = 0,
         id: CKRecord.ID = CKRecord.ID(recordName: UUID().uuidString))
    {
        self.id = id
        self.template = template
        self.assignee = assignee
        self.goldReward = goldReward
        self.xpReward = xpReward
        self.xpBanked = xpBanked
        self.scheduleType = scheduleType
        self.targetCount = targetCount
        self.isAllOrNothing = isAllOrNothing
        self.approvalMode = approvalMode
        active = true
        self.weekOf = weekOf
        self.createdBy = createdBy
        self.family = family
        self.name = name
        self.descriptionText = descriptionText
    }
}

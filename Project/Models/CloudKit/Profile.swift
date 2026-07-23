import CloudKit
import Foundation

struct Profile: Identifiable, Equatable, Sendable {
    static let recordType: String = "Profile"

    let id: CKRecord.ID

    var displayName: String
    var avatarClass: AvatarClass
    var avatarPresetID: String
    var role: UserRole
    var xp: Int
    var level: Int

    var iCloudUserID: CKRecord.ID

    var family: CKRecord.Reference

    var isActive: Bool

    init(record: CKRecord) throws {
        guard record.recordType == Self.recordType else {
            throw CKDecodingError.unexpectedRecordType(expected: Self.recordType,
                                                       actual: record.recordType)
        }
        id = record.recordID

        guard let displayName = record["displayName"] as? String else {
            throw CKDecodingError.missingField("displayName")
        }
        self.displayName = displayName

        guard let avatarClassRaw = record["avatarClass"] as? String,
              let avatarClass = AvatarClass(rawValue: avatarClassRaw)
        else {
            throw CKDecodingError.missingField("avatarClass")
        }
        self.avatarClass = avatarClass

        guard let avatarPresetID = record["avatarPresetID"] as? String else {
            throw CKDecodingError.missingField("avatarPresetID")
        }
        self.avatarPresetID = avatarPresetID

        guard let roleRaw = record["role"] as? String,
              let role = UserRole(rawValue: roleRaw)
        else {
            throw CKDecodingError.missingField("role")
        }
        self.role = role

        guard let xp = record["xp"] as? Int else {
            throw CKDecodingError.missingField("xp")
        }
        self.xp = xp

        guard let level = record["level"] as? Int else {
            throw CKDecodingError.missingField("level")
        }
        self.level = level

        guard let iCloudUserIDStr = record["iCloudUserID"] as? String else {
            throw CKDecodingError.missingField("iCloudUserID")
        }
        iCloudUserID = CKRecord.ID(recordName: iCloudUserIDStr)

        guard let familyRef = record["family"] as? CKRecord.Reference else {
            throw CKDecodingError.missingField("family")
        }
        family = familyRef

        isActive = (record["isActive"] as? Bool) ?? false
    }

    func toRecord() -> CKRecord {
        let record = CKRecord(recordType: Self.recordType, recordID: id)
        record["displayName"] = displayName as CKRecordValue
        record["avatarClass"] = avatarClass.rawValue as CKRecordValue
        record["avatarPresetID"] = avatarPresetID as CKRecordValue
        record["role"] = role.rawValue as CKRecordValue
        record["xp"] = xp as CKRecordValue
        record["level"] = level as CKRecordValue
        record["iCloudUserID"] = iCloudUserID.recordName as CKRecordValue
        record["family"] = family as CKRecordValue
        record["isActive"] = isActive as CKRecordValue
        return record
    }

    init(displayName: String,
         avatarClass: AvatarClass,
         avatarPresetID: String,
         role: UserRole,
         iCloudUserID: CKRecord.ID,
         family: CKRecord.Reference,
         id: CKRecord.ID = CKRecord.ID(recordName: UUID().uuidString))
    {
        self.id = id
        self.displayName = displayName
        self.avatarClass = avatarClass
        self.avatarPresetID = avatarPresetID
        self.role = role
        xp = 0
        level = 1
        self.iCloudUserID = iCloudUserID
        self.family = family
        isActive = true
    }
}

extension Profile: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

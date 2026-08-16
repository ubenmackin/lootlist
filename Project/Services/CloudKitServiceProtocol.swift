//
//  CloudKitServiceProtocol.swift
//  LootList
//
//  Created by Ben Mackin on 7/31/26.
//

import CloudKit
import Foundation

/// Decoded domain model envelope used to cross the `@MainActor → BackgroundCacheActor`
/// boundary without carrying non-Sendable `CKRecord`. Parsing happens canonically
/// on the `@MainActor` side via `ParsedRecord.parse(record:)` (inside `CKSyncEngineDelegateHandler`);
/// only Sendable domain structs travel across.
enum ParsedRecord: Sendable {
    case family(Family)
    case profile(Profile)
    case quest(Quest)
    case questTemplate(QuestTemplate)
    case questCompletion(QuestCompletion)
    case ledgerEntry(LedgerEntry)
    case allowancePeriod(AllowancePeriod)
    case achievement(Achievement)
    case profileAchievement(ProfileAchievement)
    case notificationPreference(NotificationPreference)
    case rewardEvent(RewardEvent)
    /// System record types (e.g. cloudkit.share) that should be skipped without counting as parse failures.
    case ignoredSystemRecord(recordType: String, recordName: String)
    /// Fallback for unknown record types or records that failed to parse.
    case parseFailure(recordType: String, recordName: String)

    var recordName: String {
        switch self {
        case let .family(model): model.id.recordName
        case let .profile(model): model.id.recordName
        case let .quest(model): model.id.recordName
        case let .questTemplate(model): model.id.recordName
        case let .questCompletion(model): model.id.recordName
        case let .ledgerEntry(model): model.id.recordName
        case let .allowancePeriod(model): model.id.recordName
        case let .achievement(model): model.id.recordName
        case let .profileAchievement(model): model.id.recordName
        case let .notificationPreference(model): model.id.recordName
        case let .rewardEvent(model): model.id.recordName
        case let .ignoredSystemRecord(_, name): name
        case let .parseFailure(_, name): name
        }
    }

    var cachedRecordType: CachedRecordType? {
        switch self {
        case .family: .family
        case .profile: .profile
        case .quest: .quest
        case .questTemplate: .questTemplate
        case .questCompletion: .questCompletion
        case .ledgerEntry: .ledgerEntry
        case .allowancePeriod: .allowancePeriod
        case .achievement: .achievement
        case .profileAchievement: .profileAchievement
        case .notificationPreference: .notificationPreference
        case .rewardEvent: nil
        case .ignoredSystemRecord: nil
        case .parseFailure: nil
        }
    }

    static func parse(record: CKRecord) -> ParsedRecord {
        do {
            switch record.recordType {
            case Family.recordType:
                return try .family(Family(record: record))
            case Profile.recordType:
                return try .profile(Profile(record: record))
            case Quest.recordType:
                return try .quest(Quest(record: record))
            case QuestTemplate.recordType:
                return try .questTemplate(QuestTemplate(record: record))
            case QuestCompletion.recordType:
                return try .questCompletion(QuestCompletion(record: record))
            case LedgerEntry.recordType:
                return try .ledgerEntry(LedgerEntry(record: record))
            case AllowancePeriod.recordType:
                return try .allowancePeriod(AllowancePeriod(record: record))
            case Achievement.recordType:
                return try .achievement(Achievement(record: record))
            case ProfileAchievement.recordType:
                return try .profileAchievement(ProfileAchievement(record: record))
            case NotificationPreference.recordType:
                return try .notificationPreference(NotificationPreference(record: record))
            case RewardEvent.recordType:
                return try .rewardEvent(RewardEvent(record: record))
            case "cloudkit.share", CKRecord.SystemType.share:
                return .ignoredSystemRecord(recordType: record.recordType, recordName: record.recordID.recordName)
            default:
                if record.recordType.hasPrefix("cloudkit.") {
                    return .ignoredSystemRecord(recordType: record.recordType, recordName: record.recordID.recordName)
                }
                return .parseFailure(recordType: record.recordType, recordName: record.recordID.recordName)
            }
        } catch {
            return .parseFailure(recordType: record.recordType, recordName: record.recordID.recordName)
        }
    }
}

/// Lightweight mirror of a `CKShare` participant's identity and acceptance
/// status, consumed by the share-reconciliation pass. `CKShare.Participant`
/// cannot be synthesized with a chosen acceptance status in unit tests, so the
/// reconciler reads this testable form rather than the raw participant object.
struct ShareParticipantStatus: Sendable, Equatable {
    let identityKey: String?
    let recordName: String?
    let isRemoved: Bool

    init(identityKey: String? = nil, recordName: String?, isRemoved: Bool) {
        self.identityKey = identityKey
        self.recordName = recordName
        self.isRemoved = isRemoved
    }
}

/// Canonical identity key resolution for a `CKShare.Participant`. Prefixes
/// identity tokens so record names, emails, phone numbers, and participant IDs
/// stay disambiguated across fetches, dictionary keys, and cross-layer revocation matching.
enum ShareParticipantKey {
    static func key(for participant: CKShare.Participant) -> String? {
        if let recordName = participant.userIdentity.userRecordID?.recordName {
            return "record:\(recordName)"
        }
        if let email = participant.userIdentity.lookupInfo?.emailAddress {
            return "email:\(email)"
        }
        if let phone = participant.userIdentity.lookupInfo?.phoneNumber {
            return "phone:\(phone)"
        }
        if !participant.participantID.isEmpty {
            return "participantID:\(participant.participantID)"
        }
        return nil
    }
}

@MainActor
protocol CloudKitServiceProtocol: CloudKitServicing, AnyObject, Sendable {
    static var defaultContainer: CKContainer { get }
    var container: CKContainer { get }

    var activeFamilyZoneID: CKRecordZone.ID? { get set }
    var activeIsOwner: Bool { get set }
    var resolvedZoneID: CKRecordZone.ID { get }

    var database: CKDatabase? { get }
    var privateDatabase: CKDatabase? { get }
    var sharedDatabase: CKDatabase? { get }
    var activeFamilyDatabase: CKDatabase? { get }

    func database(isOwner: Bool) -> CKDatabase?

    func save<T: CloudKitRecord>(_ entity: T, in zoneID: CKRecordZone.ID?, using db: CKDatabase?) async throws -> T
    func fetch<T: CloudKitRecord>(_ type: T.Type, id: CKRecord.ID, using db: CKDatabase?) async throws -> T
    func query<T: CloudKitRecord>(_ type: T.Type, predicate: NSPredicate, in zoneID: CKRecordZone.ID?, sortDescriptors: [NSSortDescriptor]?, using db: CKDatabase?) async throws
        -> [T]
    func delete(_ recordID: CKRecord.ID, in zoneID: CKRecordZone.ID?, using db: CKDatabase?) async throws
    func delete(_ entity: some CloudKitRecord, using db: CKDatabase?) async throws

    func ensureZoneExists(_ zoneID: CKRecordZone.ID) async throws

    func createShare(for rootRecordID: CKRecord.ID, role: UserRole) async throws -> CKShare
    func fetchOrCreateShare(for rootRecordID: CKRecord.ID, role: UserRole) async throws -> CKShare
    func acceptShare(metadata: CKShare.Metadata) async throws
    func removeParticipant(iCloudUserRecordName: String, from rootRecordID: CKRecord.ID) async throws
    /// Aggregated `CKShare` participants across all role shares for the family
    /// root, deduplicated by identity. Used to render the in-app Invitations
    /// panel (pending invites and their acceptance state).
    func fetchShareParticipants(for rootRecordID: CKRecord.ID) async throws -> [CKShare.Participant]
    /// Removes a specific participant (matched by identity) from the family
    /// shares. Covers pending invites that have no iCloud user record name yet.
    func removeParticipant(_ participant: CKShare.Participant, from rootRecordID: CKRecord.ID) async throws

    /// Lightweight view of each participant's identity and acceptance status
    /// across all role shares. The share-reconciliation pass reads this instead
    /// of raw `CKShare.Participant` objects so its suspicious-departure logic
    /// stays unit-testable (statuses can be synthesized in tests).
    func fetchShareParticipantStatuses(for rootRecordID: CKRecord.ID) async throws -> [ShareParticipantStatus]

    /// Maps each share participant's stable identity key or record name to the
    /// target `UserRole` decoded from the title of the `CKShare` they belong to.
    func fetchShareParticipantRoles(for rootRecordID: CKRecord.ID) async throws -> [String: UserRole]

    func processAbandonedZonesQueue(appState: AppState) async
    func currentUserRecordID() async throws -> CKRecord.ID
    func fetchPrivateZones() async throws -> [CKRecordZone]
    func fetchSharedZones() async throws -> [CKRecordZone]
    func deleteZone(_ zoneID: CKRecordZone.ID) async throws
    func seedMockRecords(_ models: [any CloudKitRecord])
}

/// Convenience overloads; protocol requirements live above.
extension CloudKitServiceProtocol {
    func save<T: CloudKitRecord>(
        _ entity: T,
        in zoneID: CKRecordZone.ID? = nil,
        using db: CKDatabase? = nil
    ) async throws -> T {
        try await save(entity, in: zoneID, using: db)
    }

    func fetch<T: CloudKitRecord>(
        _ type: T.Type,
        id: CKRecord.ID,
        using db: CKDatabase? = nil
    ) async throws -> T {
        try await fetch(type, id: id, using: db)
    }

    func query<T: CloudKitRecord>(
        _ type: T.Type,
        predicate: NSPredicate = NSPredicate(value: true),
        in zoneID: CKRecordZone.ID? = nil,
        sortDescriptors: [NSSortDescriptor]? = nil,
        using db: CKDatabase? = nil
    ) async throws -> [T] {
        try await query(type, predicate: predicate, in: zoneID, sortDescriptors: sortDescriptors, using: db)
    }

    func delete(_ recordID: CKRecord.ID, in zoneID: CKRecordZone.ID? = nil, using db: CKDatabase? = nil) async throws {
        try await delete(recordID, in: zoneID, using: db)
    }

    func delete(_ entity: some CloudKitRecord, using db: CKDatabase? = nil) async throws {
        let record = entity.toRecord()
        try await delete(record.recordID, in: record.recordID.zoneID, using: db)
    }
}

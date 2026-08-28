//
//  CloudKitServiceProtocol.swift
//  LootList
//
//  Created by Ben Mackin on 7/31/26.
//

import CloudKit
import Foundation

/// Decoded domain model envelope used to cross the `@MainActor → BackgroundCacheActor` boundary without
/// carrying non-Sendable `CKRecord`.
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
    case gemLedger(GemLedger)
    case rewardEvent(RewardEvent)
    case goal(Goal)
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
        case let .gemLedger(model): model.id.recordName
        case let .rewardEvent(model): model.id.recordName
        case let .goal(model): model.id.recordName
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
        case .gemLedger: .gemLedger
        case .rewardEvent: .rewardEvent
        case .goal: .goal
        case .ignoredSystemRecord: nil
        case .parseFailure: nil
        }
    }

    static func parse(record: CKRecord) -> ParsedRecord {
        do {
            if let core = try parseCoreRecord(record) {
                return core
            }
            if let gamification = try parseGamificationRecord(record) {
                return gamification
            }
            if record.recordType == "cloudkit.share" || record.recordType == CKRecord.SystemType.share || record.recordType.hasPrefix("cloudkit.") {
                return .ignoredSystemRecord(recordType: record.recordType, recordName: record.recordID.recordName)
            }
            return .parseFailure(recordType: record.recordType, recordName: record.recordID.recordName)
        } catch {
            return .parseFailure(recordType: record.recordType, recordName: record.recordID.recordName)
        }
    }

    private static func parseCoreRecord(_ record: CKRecord) throws -> ParsedRecord? {
        switch record.recordType {
        case Family.recordType:
            try .family(Family(record: record))
        case Profile.recordType:
            try .profile(Profile(record: record))
        case Quest.recordType:
            try .quest(Quest(record: record))
        case QuestTemplate.recordType:
            try .questTemplate(QuestTemplate(record: record))
        case QuestCompletion.recordType:
            try .questCompletion(QuestCompletion(record: record))
        case LedgerEntry.recordType:
            try .ledgerEntry(LedgerEntry(record: record))
        case AllowancePeriod.recordType:
            try .allowancePeriod(AllowancePeriod(record: record))
        default:
            nil
        }
    }

    private static func parseGamificationRecord(_ record: CKRecord) throws -> ParsedRecord? {
        switch record.recordType {
        case Achievement.recordType:
            try .achievement(Achievement(record: record))
        case ProfileAchievement.recordType:
            try .profileAchievement(ProfileAchievement(record: record))
        case NotificationPreference.recordType:
            try .notificationPreference(NotificationPreference(record: record))
        case GemLedger.recordType:
            try .gemLedger(GemLedger(record: record))
        case RewardEvent.recordType:
            try .rewardEvent(RewardEvent(record: record))
        case Goal.recordType:
            try .goal(Goal(record: record))
        default:
            nil
        }
    }
}

struct AtomicGemDebit: Sendable {
    let profile: Profile
    let ledger: GemLedger
}

/// Lightweight mirror of a `CKShare` participant's identity and acceptance status, consumed by the
/// share-reconciliation pass.
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
    func claimRewardEvent(_ event: RewardEvent, in zoneID: CKRecordZone.ID?, using db: CKDatabase?) async throws -> Bool
    func fetch<T: CloudKitRecord>(_ type: T.Type, id: CKRecord.ID, using db: CKDatabase?) async throws -> T
    func query<T: CloudKitRecord>(_ type: T.Type, predicate: NSPredicate, in zoneID: CKRecordZone.ID?, sortDescriptors: [NSSortDescriptor]?, using db: CKDatabase?) async throws
        -> [T]
    func delete(_ recordID: CKRecord.ID, in zoneID: CKRecordZone.ID?, using db: CKDatabase?) async throws
    func delete(_ entity: some CloudKitRecord, using db: CKDatabase?) async throws

    func ensureZoneExists(_ zoneID: CKRecordZone.ID) async throws

    func createShare(for rootRecordID: CKRecord.ID, role: UserRole) async throws -> CKShare
    func fetchOrCreateShare(for rootRecordID: CKRecord.ID, role: UserRole) async throws -> CKShare
    /// Resolves a share invitation URL into acceptance metadata. Wraps the
    /// container call so callers outside the service layer never touch it.
    func shareMetadata(for url: URL) async throws -> CKShare.Metadata
    func acceptShare(metadata: CKShare.Metadata) async throws
    func removeParticipant(iCloudUserRecordName: String, from rootRecordID: CKRecord.ID) async throws
    /// Aggregated `CKShare` participants across all role shares for the family
    /// root, deduplicated by identity. Used to render the in-app Invitations
    /// panel (pending invites and their acceptance state).
    func fetchShareParticipants(for rootRecordID: CKRecord.ID) async throws -> [CKShare.Participant]
    /// Removes a specific participant (matched by identity) from the family
    /// shares. Covers pending invites that have no iCloud user record name yet.
    func removeParticipant(_ participant: CKShare.Participant, from rootRecordID: CKRecord.ID) async throws

    /// Lightweight view of each participant's identity and acceptance status across all role shares.
    func fetchShareParticipantStatuses(for rootRecordID: CKRecord.ID) async throws -> [ShareParticipantStatus]

    /// Maps each share participant's stable identity key or record name to the
    /// target `UserRole` decoded from the title of the `CKShare` they belong to.
    func fetchShareParticipantRoles(for rootRecordID: CKRecord.ID) async throws -> [String: UserRole]

    func processAbandonedZonesQueue(appState: AppState) async
    func currentUserRecordID() async throws -> CKRecord.ID
    func fetchPrivateZones() async throws -> [CKRecordZone]
    func fetchSharedZones() async throws -> [CKRecordZone]
    func deleteZone(_ zoneID: CKRecordZone.ID) async throws

    func atomicallyDebitGems(
        amount: Int,
        from profile: Profile,
        ledger: GemLedger
    ) async throws -> AtomicGemDebit?
}

/// Convenience overloads; protocol requirements live above.
extension CloudKitServiceProtocol {
    func claimRewardEvent(
        _ event: RewardEvent,
        in zoneID: CKRecordZone.ID? = nil,
        using db: CKDatabase? = nil
    ) async throws -> Bool {
        try await claimRewardEvent(event, in: zoneID, using: db)
    }

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

    /// Performs a conditional balance update and ledger creation in one CloudKit operation.
    func atomicallyDebitGems(
        amount: Int,
        from profile: Profile,
        ledger: GemLedger
    ) async throws -> AtomicGemDebit? {
        guard amount > 0 else { return nil }
        guard ledger.amount == -amount, ledger.source == "shopPurchase" else {
            throw CloudKitServiceError.invalidArguments("Gem debit does not match the purchase amount")
        }

        let isMock = self is MockCloudKitService
        guard isMock || activeFamilyDatabase != nil else {
            throw CloudKitServiceError.accountUnavailable
        }

        let database = isMock ? nil : activeFamilyDatabase
        let authoritativeProfileID = CKRecord.ID(
            recordName: profile.id.recordName,
            zoneID: ledger.id.zoneID
        )

        for attempt in 0 ..< 3 {
            do {
                if let existingLedger = try await existingGemLedger(
                    ledger,
                    using: database
                ) {
                    let existingProfile = try await fetch(
                        Profile.self,
                        id: authoritativeProfileID,
                        using: database
                    )
                    return AtomicGemDebit(profile: existingProfile, ledger: existingLedger)
                }

                let authoritativeProfile: Profile
                do {
                    authoritativeProfile = try await fetch(
                        Profile.self,
                        id: authoritativeProfileID,
                        using: database
                    )
                } catch let error as CloudKitServiceError {
                    // A mock can model a local-first credit without having received the profile's pending sync write yet.
                    if isMock, case .notFound = error {
                        authoritativeProfile = profile
                    } else {
                        throw error
                    }
                }
                guard authoritativeProfile.gems >= amount else { return nil }

                var debitedProfile = authoritativeProfile
                debitedProfile.gems -= amount

                if isMock {
                    _ = try await save(debitedProfile, in: ledger.id.zoneID, using: database)
                    _ = try await save(ledger, in: ledger.id.zoneID, using: database)
                } else if let database {
                    try await performAtomicGemDebit(
                        profile: debitedProfile,
                        ledger: ledger,
                        in: ledger.id.zoneID,
                        using: database
                    )
                }

                let savedProfile = try await fetch(
                    Profile.self,
                    id: authoritativeProfileID,
                    using: database
                )
                let savedLedger = try await fetch(
                    GemLedger.self,
                    id: ledger.id,
                    using: database
                )
                return AtomicGemDebit(profile: savedProfile, ledger: savedLedger)
            } catch {
                let mappedError = mapAtomicGemDebitError(error)
                guard isServerRecordChanged(mappedError), attempt < 2 else {
                    throw mappedError
                }
            }
        }

        throw CloudKitServiceError.serverRecordChanged
    }

    private func existingGemLedger(
        _ ledger: GemLedger,
        using database: CKDatabase?
    ) async throws -> GemLedger? {
        do {
            return try await fetch(GemLedger.self, id: ledger.id, using: database)
        } catch let error as CloudKitServiceError {
            if case .notFound = error {
                return nil
            }
            throw error
        }
    }

    private func performAtomicGemDebit(
        profile: Profile,
        ledger: GemLedger,
        in zoneID: CKRecordZone.ID,
        using database: CKDatabase
    ) async throws {
        let familyID = CKRecord.ID(
            recordName: profile.family.recordID.recordName,
            zoneID: zoneID
        )
        let parent = CKRecord.Reference(recordID: familyID, action: .none)
        let profileRecord = profile.toRecord()
        profileRecord.parent = parent
        let ledgerRecord = ledger.toRecord()
        ledgerRecord.parent = parent

        let (saveResults, _) = try await database.modifyRecords(
            saving: [profileRecord, ledgerRecord],
            deleting: [],
            savePolicy: .ifServerRecordUnchanged,
            atomically: true
        )
        for (_, result) in saveResults {
            switch result {
            case .success:
                break
            case let .failure(error):
                throw error
            }
        }
    }

    private func mapAtomicGemDebitError(_ error: Error) -> Error {
        if let serviceError = error as? CloudKitServiceError {
            return serviceError
        }
        guard let cloudKitError = error as? CKError else { return error }
        if isServerRecordChanged(cloudKitError) {
            return CloudKitServiceError.serverRecordChanged
        }
        switch cloudKitError.code {
        case .constraintViolation:
            return CloudKitServiceError.serverRecordChanged
        case .unknownItem:
            return CloudKitServiceError.notFound(cloudKitError.localizedDescription)
        case .networkUnavailable, .networkFailure:
            return CloudKitServiceError.networkUnavailable
        default:
            return CloudKitServiceError.underlying(cloudKitError.localizedDescription)
        }
    }

    private func isServerRecordChanged(_ error: Error) -> Bool {
        if let serviceError = error as? CloudKitServiceError {
            if case .serverRecordChanged = serviceError {
                return true
            }
            return false
        }
        guard let cloudKitError = error as? CKError else { return false }
        if cloudKitError.code == .serverRecordChanged {
            return true
        }
        guard let partialErrors = cloudKitError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Any] else {
            return false
        }
        return partialErrors.values.contains { value in
            guard let nestedError = value as? Error else { return false }
            return isServerRecordChanged(nestedError)
        }
    }
}

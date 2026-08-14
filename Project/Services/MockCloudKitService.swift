//
//  MockCloudKitService.swift
//  LootList
//
//  Created by Ben Mackin on 7/31/26.
//

import CloudKit
import Foundation

@MainActor
class MockCloudKitService: CloudKitServiceProtocol {
    /// The fixed current iCloud user the mock reports via `currentUserRecordID()`.
    static let mockUserRecordName = "mockUser"

    private static let containerInstance: CKContainer = .init(identifier: "iCloud.com.volcrypt.lootlist")

    static var defaultContainer: CKContainer {
        containerInstance
    }

    var container: CKContainer {
        Self.defaultContainer
    }

    var activeFamilyZoneID: CKRecordZone.ID?
    var activeIsOwner: Bool = true
    var mockRecords: [CKRecord.ID: CKRecord] = [:]
    /// Role-targeted `CKShare`s minted for the current test, mirroring a family
    /// root's multiple coexisting shares (Hero + Ranger). Powers the mock's
    /// share participant aggregation and revocation paths.
    var mockShares: [CKShare] = []
    /// Simulated share membership: per role share, the set of participant
    /// identity keys (the strings the sharing service's `participantKey`
    /// produces) currently holding access. CloudKit cannot fabricate
    /// `CKShare.Participant` instances client-side, so the mock stands the
    /// server-minted participant list in with these keys.
    var mockShareMemberships: [CKRecord.ID: Set<String>] = [:]
    /// Identities (participant identity keys) whose server-side acceptance
    /// status is `.removed` (a GM revoked the identity but it has not yet
    /// dropped off the share). Mirrors how CloudKit keeps a removed participant
    /// visible with `.removed` status for a propagation window.
    var mockRemovedMemberships: Set<String> = []
    /// Every role share (in revocation order) that a remove call stripped the
    /// target identity from. Lets tests assert that revocation spans all
    /// matching role shares rather than returning after the first match.
    private(set) var revokedShareIDs: [CKRecord.ID] = []
    var fetchError: Error?
    /// Optional per-test injection: when set, `save` throws this error after
    /// persisting the record's `CKRecord` form into the mock store. Mirrors
    /// `fetchError` so tests can drive a save-time conflict (e.g.
    /// `CloudKitServiceError.serverRecordChanged`) and still observe a
    /// subsequent authoritative `fetch` against the seeded `mockRecords`.
    var saveError: Error?

    /// Emulates CloudKit's server-side creator stamp. The SDK allows only the
    /// server to write `CKRecord.creatorUserRecordID`, so the mock mirrors that
    /// read-only system field in a registry and applies it onto decoded models.
    var recordCreators: [CKRecord.ID: String] = [:]

    var resolvedZoneID: CKRecordZone.ID {
        activeFamilyZoneID ?? CKRecordZone.default().zoneID
    }

    /// Protocol conformance stub (see `CloudKitServiceProtocol.seedMockRecords`):
    /// seeds records into the mock store with the default server-stamped
    /// creator — the mock's fixed current user ("mockUser").
    func seedMockRecords(_ models: [any CloudKitRecord]) {
        seedMockRecords(models, creatorUserRecordName: Self.mockUserRecordName)
    }

    /// Emulates CloudKit's server-side creator stamp for a specific caller. An
    /// explicit `creatorUserRecordName` stamps the record as authored by that
    /// iCloud user; passing nil leaves the registry unset so the record decodes
    /// with a nil `creatorUserRecordName` (a legacy family with no creator
    /// anchor). Callers that want the default stamp (the mock's fixed current
    /// user, "mockUser") should use the single-argument `seedMockRecords(_:)`.
    /// Records written via `save` are always stamped with the acting user.
    func seedMockRecords(_ models: [any CloudKitRecord], creatorUserRecordName: String?) {
        for model in models {
            let record = model.toRecord()
            mockRecords[record.recordID] = record
            // `nil` subscript removes the key, leaving a legacy record with no
            // server-stamped creator.
            recordCreators[record.recordID] = creatorUserRecordName
        }
    }

    var database: CKDatabase? {
        nil
    }

    var privateDatabase: CKDatabase? {
        nil
    }

    var sharedDatabase: CKDatabase? {
        nil
    }

    var activeFamilyDatabase: CKDatabase? {
        nil
    }

    func database(isOwner _: Bool) -> CKDatabase? {
        nil
    }

    func save<T: CloudKitRecord>(_ entity: T, in _: CKRecordZone.ID?, using _: CKDatabase?) async throws -> T {
        // Per-test save-time conflict injection (mirrors `fetchError` on the
        // fetch path). Throw BEFORE persisting so a previously-seeded
        // authoritative record in `mockRecords` survives — exactly the
        // state a real CloudKit `serverRecordChanged` leaves behind
        // (another device's record lives on, our rejected write never landed),
        // which lets the rollback path's re-`fetch` retrieve that authoritative
        // value rather than the optimistic state we attempted to push.
        if let saveError {
            throw saveError
        }
        let record = entity.toRecord()
        // Emulate the server: stamp the creator only on creation, before
        // persisting and re-decoding (mirrors the real `CloudKitService.save`'s
        // `return try T(record: saved)`). A later edit by a different user must
        // not overwrite or clear the original server-stamped creator, so the
        // existing stamp (if any) is left untouched.
        if recordCreators[record.recordID] == nil {
            recordCreators[record.recordID] = await (try? currentUserRecordID())?.recordName
        }
        mockRecords[record.recordID] = record
        let decoded = try T(record: record)
        return applyingCreatorStamp(for: record.recordID, on: decoded)
    }

    func fetch<T: CloudKitRecord>(_ type: T.Type, id: CKRecord.ID, using _: CKDatabase?) async throws -> T {
        if let fetchError {
            throw fetchError
        }
        _ = type
        guard let record = mockRecords[id] else {
            throw CloudKitServiceError.notFound(id.recordName)
        }
        let decoded = try T(record: record)
        return applyingCreatorStamp(for: id, on: decoded)
    }

    func query<T: CloudKitRecord>(_: T.Type, predicate: NSPredicate, in _: CKRecordZone.ID?, sortDescriptors: [NSSortDescriptor]?, using _: CKDatabase?) async throws -> [T] {
        var matching = Array(mockRecords.values.filter { $0.recordType == T.recordType })
        if predicate != NSPredicate(value: true) {
            matching = matching.filter { predicate.evaluate(with: $0) }
        }
        if let sortDescriptors, !sortDescriptors.isEmpty {
            let nsArray = (matching as NSArray).sortedArray(using: sortDescriptors)
            if let sortedMatching = nsArray as? [CKRecord] {
                matching = sortedMatching
            }
        }
        return try matching.map { record -> T in
            let decoded = try T(record: record)
            return applyingCreatorStamp(for: record.recordID, on: decoded)
        }
    }

    func delete(_ recordID: CKRecord.ID, in _: CKRecordZone.ID?, using _: CKDatabase?) async throws {
        mockRecords.removeValue(forKey: recordID)
    }

    func delete(_ entity: some CloudKitRecord, using _: CKDatabase?) async throws {
        let record = entity.toRecord()
        mockRecords.removeValue(forKey: record.recordID)
    }

    func ensureZoneExists(_: CKRecordZone.ID) async throws {}

    func fetchZoneChanges(in _: CKRecordZone.ID?, since _: CKServerChangeToken?, using _: CKDatabase?) async throws -> ZoneChangesResult {
        let parsed: [ParsedRecord] = mockRecords.values.compactMap { record in
            do {
                switch record.recordType {
                case Family.recordType: return try .family(Family(record: record))
                case Profile.recordType: return try .profile(Profile(record: record))
                case Quest.recordType: return try .quest(Quest(record: record))
                case QuestTemplate.recordType: return try .questTemplate(QuestTemplate(record: record))
                case QuestCompletion.recordType: return try .questCompletion(QuestCompletion(record: record))
                case LedgerEntry.recordType: return try .ledgerEntry(LedgerEntry(record: record))
                case AllowancePeriod.recordType: return try .allowancePeriod(AllowancePeriod(record: record))
                case Achievement.recordType: return try .achievement(Achievement(record: record))
                case ProfileAchievement.recordType: return try .profileAchievement(ProfileAchievement(record: record))
                case NotificationPreference.recordType: return try .notificationPreference(NotificationPreference(record: record))
                default: return .parseFailure(recordType: record.recordType, recordName: record.recordID.recordName)
                }
            } catch {
                return .parseFailure(recordType: record.recordType, recordName: record.recordID.recordName)
            }
        }
        return ZoneChangesResult(
            changedRecords: parsed,
            deletedRecordIDs: [],
            newToken: nil,
            moreComing: false
        )
    }

    func createShare(for rootRecordID: CKRecord.ID, role: UserRole) async throws -> CKShare {
        let root = mockRecords[rootRecordID] ?? CKRecord(recordType: Family.recordType, recordID: rootRecordID)
        let share = CKShare(rootRecord: root)
        share[CKShare.SystemFieldKey.title] = "\(root["name"] as? String ?? "Family Guild")\(role.shareTitleSuffix)"
        share.publicPermission = .none
        mockShares.append(share)
        return share
    }

    func fetchOrCreateShare(for rootRecordID: CKRecord.ID, role: UserRole) async throws -> CKShare {
        // Find-or-create over the stored role shares, mirroring the real
        // service: a family root carries one share per role, so a repeated
        // fetch for the same role returns the minted share rather than a copy.
        if let existing = mockShares.first(where: { share in
            share.recordID.zoneID == rootRecordID.zoneID
                && UserRole.fromShareTitle(share[CKShare.SystemFieldKey.title] as? String) == role
        }) {
            return existing
        }
        return try await createShare(for: rootRecordID, role: role)
    }

    func acceptShare(metadata _: CKShare.Metadata) async throws {}

    /// Records an identity (as a `participantKey` string) as a participant of
    /// the family's `role` share, standing in for CloudKit's server-minted
    /// participant list which unit tests cannot fabricate.
    @discardableResult
    func simulateParticipation(key: String, rootRecordID: CKRecord.ID, role: UserRole) async throws -> CKShare {
        let share = try await fetchOrCreateShare(for: rootRecordID, role: role)
        mockShareMemberships[share.recordID, default: []].insert(key)
        return share
    }

    /// Core revocation pass shared by both overloads: removes the identity key
    /// from EVERY role share in the zone that contains it. A member can sit on
    /// both the Hero and the Ranger share, so stopping at the first match would
    /// leave live access through the second. A share is revoked only when it
    /// actually contained the identity (no-op for no match).
    private func revokeIdentityKey(_ key: String, inZone zoneID: CKRecordZone.ID) {
        for share in mockShares where share.recordID.zoneID == zoneID {
            guard mockShareMemberships[share.recordID]?.remove(key) != nil else { continue }
            revokedShareIDs.append(share.recordID)
        }
    }

    func removeParticipant(iCloudUserRecordName: String, from rootRecordID: CKRecord.ID) async throws {
        let key = "record:\(iCloudUserRecordName)"
        let zoneID = rootRecordID.zoneID
        // A revocation with no matching membership must never be a silent
        // no-op. Mirror the object overload (and the real service's
        // propagation-race surface the VM reports through `loadError`): when no
        // role share contains the identity, throw so the caller does not assume
        // access was revoked.
        guard mockShares.contains(where: { share in
            share.recordID.zoneID == zoneID && mockShareMemberships[share.recordID]?.contains(key) == true
        }) else {
            throw CloudKitServiceError.shareFailed(
                "No role share contains a participant matching this identity — the revocation was not performed"
            )
        }
        revokeIdentityKey(key, inZone: zoneID)
    }

    func fetchShareParticipants(for rootRecordID: CKRecord.ID) async throws -> [CKShare.Participant] {
        var seen = Set<String>()
        var participants: [CKShare.Participant] = []
        for share in mockShares where share.recordID.zoneID == rootRecordID.zoneID {
            for participant in share.participants {
                guard let key = ShareParticipantKey.key(for: participant) else { continue }
                if seen.insert(key).inserted {
                    participants.append(participant)
                }
            }
        }
        return participants
    }

    /// Emulated server participant summary. Reads the membership registry
    /// (`mockShareMemberships`) rather than fabricated `CKShare.Participant`
    /// objects, which unit tests cannot create with a chosen acceptance status.
    /// `recordName` is derived from `"record:"`-prefixed identity keys; keys
    /// without that prefix are pending invites with no iCloud identity yet.
    func fetchShareParticipantStatuses(for rootRecordID: CKRecord.ID) async throws -> [ShareParticipantStatus] {
        var seen = Set<String>()
        var statuses: [ShareParticipantStatus] = []
        let memberships = mockShareMemberships.filter { $0.key.zoneID == rootRecordID.zoneID }
        for (_, keys) in memberships {
            for key in keys where seen.insert(key).inserted {
                let recordName = key.hasPrefix("record:") ? String(key.dropFirst("record:".count)) : nil
                statuses.append(ShareParticipantStatus(
                    identityKey: key,
                    recordName: recordName,
                    isRemoved: mockRemovedMemberships.contains(key)
                ))
            }
        }
        return statuses
    }

    func removeParticipant(_ participant: CKShare.Participant, from rootRecordID: CKRecord.ID) async throws {
        // Mirrors the real service: a participant with no matchable identity
        // (no user record name, email, phone, or participant ID) or no matching
        // membership anywhere must surface a failure — never a silent no-op.
        let key = ShareParticipantKey.key(for: participant)
        guard let key else {
            throw CloudKitServiceError.shareFailed(
                "Cannot revoke a share participant with no CloudKit identity (no user record name, email, phone, or participant ID)"
            )
        }
        let zoneID = rootRecordID.zoneID
        guard mockShares.contains(where: { share in
            share.recordID.zoneID == zoneID && mockShareMemberships[share.recordID]?.contains(key) == true
        }) else {
            throw CloudKitServiceError.shareFailed(
                "No role share contains a participant matching this identity — the revocation was not performed"
            )
        }
        revokeIdentityKey(key, inZone: zoneID)
    }

    func fetchShareParticipantRoles(for rootRecordID: CKRecord.ID) async throws -> [String: UserRole] {
        var rolesByIdentity: [String: UserRole] = [:]
        for share in mockShares where share.recordID.zoneID == rootRecordID.zoneID {
            guard let title = share[CKShare.SystemFieldKey.title] as? String,
                  let role = UserRole.fromShareTitle(title) else { continue }
            if let keys = mockShareMemberships[share.recordID] {
                for key in keys {
                    rolesByIdentity[key] = role
                    let cleanKey = key.replacingOccurrences(of: "record:", with: "")
                    rolesByIdentity[cleanKey] = role
                }
            }
        }
        return rolesByIdentity
    }

    func processAbandonedZonesQueue(appState _: AppState) async {}

    func currentUserRecordID() async throws -> CKRecord.ID {
        CKRecord.ID(recordName: Self.mockUserRecordName, zoneID: resolvedZoneID)
    }

    func fetchPrivateZones() async throws -> [CKRecordZone] {
        []
    }

    func fetchSharedZones() async throws -> [CKRecordZone] {
        []
    }

    func deleteZone(_ zoneID: CKRecordZone.ID) async throws {
        _ = zoneID
    }

    /// Applies the emulated server creator stamp onto a decoded model. Only the
    /// `Family` model carries the creator anchor; all other record types are
    /// returned untouched. The registry is authoritative because CloudKit owns
    /// the creator field — a locally-authored value cannot override the stamp.
    private func applyingCreatorStamp<T: CloudKitRecord>(for recordID: CKRecord.ID, on result: T) -> T {
        guard var family = result as? Family, let creator = recordCreators[recordID] else {
            return result
        }
        family.creatorUserRecordName = creator
        // `result` is already a Family (proven by the guard above), so the
        // optional cast back up to `T` never fails; the fallback exists only
        // to keep the code free of forced casts.
        return family as? T ?? result
    }
}

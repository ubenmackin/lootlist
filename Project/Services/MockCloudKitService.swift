//
//  MockCloudKitService.swift
//  LootList
//
//  Created by Ben Mackin on 7/31/26.
//

import CloudKit
import Foundation
import os

@MainActor
class MockCloudKitService: CloudKitServiceProtocol {
    /// The fixed current iCloud user the mock reports via `currentUserRecordID()`.
    static let mockUserRecordName = "mockUser"

    private static var _containerInstance: CKContainer?

    static var defaultContainer: CKContainer {
        if let instance = _containerInstance {
            return instance
        }
        let instance = CKContainer(identifier: "iCloud.com.volcrypt.lootlist")
        _containerInstance = instance
        return instance
    }

    var container: CKContainer {
        Self.defaultContainer
    }

    var activeFamilyZoneID: CKRecordZone.ID?
    var activeIsOwner: Bool = true
    var mockStore = MockRecordStore()

    var mockRecords: [CKRecord.ID: CKRecord] {
        get {
            var dict: [CKRecord.ID: CKRecord] = [:]
            for record in mockStore.allRecords {
                dict[record.recordID] = record
            }
            return dict
        }
        set {
            mockStore.clear()
            let scope: CKDatabase.Scope = activeIsOwner ? .private : .shared
            for (_, record) in newValue {
                mockStore.setRecord(record, databaseScope: scope)
            }
        }
    }

    var deletedRecordIDs: [CKRecord.ID] = []
    var savedRecords: [CKRecord] = []
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

    init() {}

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "MockCloudKit")

    init(zoneID: CKRecordZone.ID) {
        self.activeFamilyZoneID = zoneID
    }

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
        let scope: CKDatabase.Scope = activeIsOwner ? .private : .shared
        for model in models {
            let record = model.toRecord()
            mockStore.setRecord(record, databaseScope: scope)
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

    func save<T: CloudKitRecord>(_ entity: T, in zoneID: CKRecordZone.ID? = nil, using db: CKDatabase? = nil) async throws -> T {
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
        let scope: CKDatabase.Scope = db?.databaseScope ?? (activeIsOwner ? .private : .shared)
        let source = entity.toRecord()
        let zone = zoneID ?? activeFamilyZoneID ?? CKRecordZone.default().zoneID
        let targetID: CKRecord.ID = (source.recordID.zoneID.zoneName != CKRecordZone.default().zoneID.zoneName)
            ? source.recordID
            : CKRecord.ID(recordName: source.recordID.recordName, zoneID: zone)

        let existing = mockStore.getRecord(recordID: targetID, databaseScope: scope)
        let record = existing ?? CKRecord(recordType: T.recordType, recordID: targetID)
        for key in source.allKeys() {
            record[key] = source[key]
        }
        let sourceKeys = Set(source.allKeys())
        for key in T.managedFieldKeys where !sourceKeys.contains(key) {
            record[key] = nil
        }
        // Emulate the server: stamp the creator only on creation, before
        // persisting and re-decoding (mirrors the real `CloudKitService.save`'s
        // `return try T(record: saved)`). A later edit by a different user must
        // not overwrite or clear the original server-stamped creator, so the
        // existing stamp (if any) is left untouched.
        if recordCreators[targetID] == nil {
            do {
                let recordID = try await currentUserRecordID()
                recordCreators[targetID] = recordID.recordName
            } catch {
                logger.debug("MockCloudKitService: failed to resolve current user record ID while saving \(T.recordType) — setting creator to nil: \(error, privacy: .private)")
                recordCreators[targetID] = nil
            }
        }
        mockStore.setRecord(record, databaseScope: scope)
        savedRecords.append(record)
        let decoded = try T(record: record)
        guard let creator = recordCreators[targetID] else {
            return decoded
        }
        if var family = decoded as? Family {
            family.creatorUserRecordName = creator
            return family as? T ?? decoded
        }
        if let profile = decoded as? Profile {
            return profile.applyingServerCreator(creator) as? T ?? decoded
        }
        return decoded
    }

    func claimRewardEvent(_ event: RewardEvent, in zoneID: CKRecordZone.ID? = nil, using db: CKDatabase? = nil) async throws -> Bool {
        if let saveError {
            throw saveError
        }
        let scope: CKDatabase.Scope = db?.databaseScope ?? (activeIsOwner ? .private : .shared)
        let source = event.toRecord()
        let zone = zoneID ?? activeFamilyZoneID ?? CKRecordZone.default().zoneID
        let targetID = source.recordID.zoneID.zoneName == CKRecordZone.default().zoneID.zoneName
            ? CKRecord.ID(recordName: source.recordID.recordName, zoneID: zone)
            : source.recordID
        guard mockStore.getRecord(recordID: targetID, databaseScope: scope) == nil else { return false }

        let record = CKRecord(recordType: RewardEvent.recordType, recordID: targetID)
        for key in source.allKeys() {
            record[key] = source[key]
        }
        record.setParent(CKRecord.ID(recordName: event.family.recordID.recordName, zoneID: zone))
        do {
            let recordID = try await currentUserRecordID()
            recordCreators[targetID] = recordID.recordName
        } catch {
            logger.debug("MockCloudKitService: failed to resolve current user record ID while claiming reward event — setting creator to nil: \(error, privacy: .private)")
            recordCreators[targetID] = nil
        }
        mockStore.setRecord(record, databaseScope: scope)
        savedRecords.append(record)
        return true
    }

    func fetch<T: CloudKitRecord>(_ type: T.Type, id: CKRecord.ID, using db: CKDatabase? = nil) async throws -> T {
        if let fetchError {
            throw fetchError
        }
        _ = type
        let scope: CKDatabase.Scope? = db?.databaseScope
        let targetID: CKRecord.ID = {
            if id.zoneID.zoneName != CKRecordZone.default().zoneID.zoneName {
                return id
            }
            if let activeZone = activeFamilyZoneID {
                return CKRecord.ID(recordName: id.recordName, zoneID: activeZone)
            }
            return id
        }()

        guard let record = mockStore.getRecord(recordID: targetID, databaseScope: scope) else {
            throw CloudKitServiceError.notFound(id.recordName)
        }
        let decoded = try T(record: record)
        // Apply creator-stamp to match production CloudKit behavior.
        if let creator = recordCreators[record.recordID] {
            return stampCreatorRecord(decoded, creator: creator)
        }
        return decoded
    }

    /// Applies the server-stamped creator to concrete record types that carry a
    /// `creatorUserRecordName`.
    private func stampCreatorRecord<T: CloudKitRecord>(_ record: T, creator: String) -> T {
        if var family = record as? Family {
            family.creatorUserRecordName = creator
            if let stamped = family as? T {
                return stamped
            }
        }
        if let profile = record as? Profile {
            if let stamped = profile.applyingServerCreator(creator) as? T {
                return stamped
            }
        }
        return record
    }

    func query<T: CloudKitRecord>(_: T.Type, predicate: NSPredicate, in zoneID: CKRecordZone.ID?, sortDescriptors: [NSSortDescriptor]?,
                                  using db: CKDatabase? = nil) async throws -> [T]
    {
        let scope: CKDatabase.Scope? = db?.databaseScope
        let targetZone = zoneID ?? activeFamilyZoneID
        let records = try mockStore.query(T.self, predicate: predicate, in: targetZone, sortDescriptors: sortDescriptors, databaseScope: scope)

        // Apply creator-stamps to match production CloudKit behavior.
        var results: [T] = []
        for record in records {
            let rid = record.toRecord().recordID
            if let creator = recordCreators[rid] {
                results.append(stampCreatorRecord(record, creator: creator))
            } else {
                results.append(record)
            }
        }
        return results
    }

    func delete(_ recordID: CKRecord.ID, in zoneID: CKRecordZone.ID? = nil, using db: CKDatabase? = nil) async throws {
        let scope: CKDatabase.Scope = db?.databaseScope ?? (activeIsOwner ? .private : .shared)
        let targetID: CKRecord.ID = {
            if recordID.zoneID.zoneName != CKRecordZone.default().zoneID.zoneName {
                return recordID
            }
            let zone = zoneID ?? activeFamilyZoneID ?? CKRecordZone.default().zoneID
            return CKRecord.ID(recordName: recordID.recordName, zoneID: zone)
        }()
        mockStore.delete(targetID, in: zoneID, activeZoneID: activeFamilyZoneID, databaseScope: scope)
        deletedRecordIDs.append(targetID)
    }

    func delete(_ entity: some CloudKitRecord, using db: CKDatabase? = nil) async throws {
        let record = entity.toRecord()
        try await delete(record.recordID, in: record.recordID.zoneID, using: db)
    }

    func ensureZoneExists(_: CKRecordZone.ID) async throws {}

    func createShare(for rootRecordID: CKRecord.ID, role: UserRole) async throws -> CKShare {
        let scope: CKDatabase.Scope = activeIsOwner ? .private : .shared
        let root = mockStore.getRecord(recordID: rootRecordID, databaseScope: scope) ?? CKRecord(recordType: Family.recordType, recordID: rootRecordID)
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
}

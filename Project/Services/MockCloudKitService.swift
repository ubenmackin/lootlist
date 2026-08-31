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
    static let mockUserRecordName = "mockUser"

    static var defaultContainer: CKContainer {
        CKContainer(identifier: "iCloud.com.volcrypt.lootlist")
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
            let scope: CKDatabase.Scope = DatabaseScopeResolver.scope(isOwner: activeIsOwner)
            for (_, record) in newValue {
                mockStore.setRecord(record, databaseScope: scope)
            }
        }
    }

    var deletedRecordIDs: [CKRecord.ID] = []
    var savedRecords: [CKRecord] = []
    var mockShares: [CKShare] = []
    var fetchError: Error?
    var saveError: Error?
    var mockShareMemberships: [CKRecord.ID: Set<String>] = [:]
    var mockRemovedMemberships: Set<String> = []
    var revokedShareIDs: [CKRecord.ID] = []

    init() {}

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "MockCloudKit")

    init(zoneID: CKRecordZone.ID) {
        self.activeFamilyZoneID = zoneID
    }

    var recordCreators: [CKRecord.ID: String] = [:]

    var resolvedZoneID: CKRecordZone.ID {
        activeFamilyZoneID ?? CKRecordZone.default().zoneID
    }

    /// Test-only seeding helper. Deliberately NOT part of `CloudKitServiceProtocol`
    /// — production CloudKit has no record-seeding surface, so tests must call
    /// this on the concrete mock type.
    func seedMockRecords(_ models: [any CloudKitRecord]) {
        seedMockRecords(models, creatorUserRecordName: Self.mockUserRecordName)
    }

    func seedMockRecords(_ models: [any CloudKitRecord], creatorUserRecordName: String?) {
        let scope: CKDatabase.Scope = DatabaseScopeResolver.scope(isOwner: activeIsOwner)
        for model in models {
            let record = model.toRecord()
            mockStore.setRecord(record, databaseScope: scope)
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
        if let saveError {
            throw saveError
        }
        let scope: CKDatabase.Scope = db?.databaseScope ?? (DatabaseScopeResolver.scope(isOwner: activeIsOwner))
        let source = entity.toRecord()
        let zone = zoneID ?? activeFamilyZoneID ?? CKRecordZone.default().zoneID
        let targetID: CKRecord.ID = (source.recordID.zoneID.zoneName != CKRecordZone.default().zoneID.zoneName) ? source.recordID : CKRecord.ID(
            recordName: source.recordID.recordName,
            zoneID: zone
        )
        let record: CKRecord
        if source.recordID == targetID {
            record = source
        } else {
            record = CKRecord(recordType: T.recordType, recordID: targetID)
            for key in source.allKeys() {
                record[key] = source[key]
            }
        }
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
        guard let creator = recordCreators[targetID] else { return decoded }
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
        let scope: CKDatabase.Scope = db?.databaseScope ?? (DatabaseScopeResolver.scope(isOwner: activeIsOwner))
        let source = event.toRecord()
        let zone = zoneID ?? activeFamilyZoneID ?? CKRecordZone.default().zoneID
        let targetID = source.recordID.zoneID.zoneName == CKRecordZone.default().zoneID.zoneName ? CKRecord.ID(recordName: source.recordID.recordName, zoneID: zone) : source
            .recordID
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
        if let creator = recordCreators[record.recordID] {
            return stampCreatorRecord(decoded, creator: creator)
        }
        return decoded
    }

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
        if let fetchError {
            throw fetchError
        }
        let scope: CKDatabase.Scope? = db?.databaseScope
        let targetZone = zoneID ?? activeFamilyZoneID
        let records = try mockStore.query(T.self, predicate: predicate, in: targetZone, sortDescriptors: sortDescriptors, databaseScope: scope)
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
        let scope: CKDatabase.Scope = db?.databaseScope ?? (DatabaseScopeResolver.scope(isOwner: activeIsOwner))
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
        let scope: CKDatabase.Scope = DatabaseScopeResolver.scope(isOwner: activeIsOwner)
        let root = mockStore.getRecord(recordID: rootRecordID, databaseScope: scope) ?? CKRecord(recordType: Family.recordType, recordID: rootRecordID)
        let share = CKShare(rootRecord: root)
        share[CKShare.SystemFieldKey.title] = "\(root["name"] as? String ?? "Family Guild")\(role.shareTitleSuffix)"
        share.publicPermission = .none
        mockShares.append(share)
        return share
    }

    func fetchOrCreateShare(for rootRecordID: CKRecord.ID, role: UserRole) async throws -> CKShare {
        if let existing = mockShares
            .first(where: { share in share.recordID.zoneID == rootRecordID.zoneID && UserRole.fromShareTitle(share[CKShare.SystemFieldKey.title] as? String) == role })
        {
            return existing
        }
        return try await createShare(for: rootRecordID, role: role)
    }

    @discardableResult
    func simulateParticipation(key: String, rootRecordID: CKRecord.ID, role: UserRole) async throws -> CKShare {
        let share = try await fetchOrCreateShare(for: rootRecordID, role: role)
        var set = mockShareMemberships[share.recordID] ?? Set<String>()
        set.insert(key)
        mockShareMemberships[share.recordID] = set
        // Ensure the key is not considered removed
        mockRemovedMemberships.remove(key)
        return share
    }

    func shareMetadata(for _: URL) async throws -> CKShare.Metadata {
        // CKShare.Metadata cannot be synthesized outside CloudKit, so the
        // mock cannot resolve pasted invitation links.
        throw CloudKitServiceError.underlying("MockCloudKitService cannot resolve share metadata")
    }

    func acceptShare(metadata _: CKShare.Metadata) async throws {}

    func removeParticipant(iCloudUserRecordName: String, from rootRecordID: CKRecord.ID) async throws {
        let key = "record:\(iCloudUserRecordName)"
        var removed = false
        for share in mockShares where share.recordID.zoneID == rootRecordID.zoneID {
            if var set = mockShareMemberships[share.recordID], set.contains(key) {
                set.remove(key)
                mockShareMemberships[share.recordID] = set
                if !revokedShareIDs.contains(share.recordID) {
                    revokedShareIDs.append(share.recordID)
                }
                removed = true
            }
            if let match = share.participants.first(where: { $0.userIdentity.userRecordID?.recordName == iCloudUserRecordName }) {
                share.removeParticipant(match)
                if !revokedShareIDs.contains(share.recordID) {
                    revokedShareIDs.append(share.recordID)
                }
                removed = true
            }
        }
        // Fallback: handle mock membership where share may not be in mockShares filtered set
        if !removed {
            for (shareID, var set) in mockShareMemberships where set.contains(key) {
                if let share = mockShares.first(where: { $0.recordID == shareID }), share.recordID.zoneID == rootRecordID.zoneID {
                    set.remove(key)
                    mockShareMemberships[shareID] = set
                    if !revokedShareIDs.contains(shareID) {
                        revokedShareIDs.append(shareID)
                    }
                    removed = true
                }
            }
        }
        guard removed else {
            throw CloudKitServiceError.shareFailed("No role share contains a participant matching this identity — the revocation was not performed")
        }
    }

    func fetchShareParticipants(for rootRecordID: CKRecord.ID) async throws -> [CKShare.Participant] {
        mockShares.filter { $0.recordID.zoneID == rootRecordID.zoneID }.flatMap(\.participants).filter { $0.role != .owner }
    }

    func fetchShareParticipantStatuses(for rootRecordID: CKRecord.ID) async throws -> [ShareParticipantStatus] {
        if !mockShareMemberships.isEmpty || !mockRemovedMemberships.isEmpty {
            var seen = Set<String>()
            var statuses: [ShareParticipantStatus] = []
            for (_, keys) in mockShareMemberships {
                for key in keys where !seen.contains(key) {
                    seen.insert(key)
                    let isRemoved = mockRemovedMemberships.contains(key)
                    let recordName: String? = key.hasPrefix("record:") ? String(key.dropFirst("record:".count)) : nil
                    statuses.append(ShareParticipantStatus(identityKey: key, recordName: recordName, isRemoved: isRemoved))
                }
            }
            for key in mockRemovedMemberships where !seen.contains(key) {
                let recordName: String? = key.hasPrefix("record:") ? String(key.dropFirst("record:".count)) : nil
                statuses.append(ShareParticipantStatus(identityKey: key, recordName: recordName, isRemoved: true))
            }
            // Include any real participants not covered by mock keys
            let real = mockShares.filter { $0.recordID.zoneID == rootRecordID.zoneID }
                .flatMap(\.participants)
                .filter { $0.role != .owner }
                .compactMap { participant -> ShareParticipantStatus? in
                    guard let key = ShareParticipantKey.key(for: participant) else { return nil }
                    if seen.contains(key) {
                        return nil
                    }
                    return ShareParticipantStatus(
                        identityKey: key,
                        recordName: participant.userIdentity.userRecordID?.recordName,
                        isRemoved: participant.acceptanceStatus == .removed
                    )
                }
            return statuses + real
        }
        return mockShares.filter { $0.recordID.zoneID == rootRecordID.zoneID }
            .flatMap(\.participants)
            .filter { $0.role != .owner }
            .compactMap { participant in
                guard let key = ShareParticipantKey.key(for: participant) else { return nil }
                return ShareParticipantStatus(identityKey: key, recordName: participant.userIdentity.userRecordID?.recordName, isRemoved: participant.acceptanceStatus == .removed)
            }
    }

    func removeParticipant(_ participant: CKShare.Participant, from rootRecordID: CKRecord.ID) async throws {
        guard let key = ShareParticipantKey.key(for: participant) else {
            throw CloudKitServiceError.shareFailed("Cannot revoke a share participant with no CloudKit identity (no user record name, email, phone, or participant ID)")
        }
        var removed = false
        for share in mockShares where share.recordID.zoneID == rootRecordID.zoneID {
            if var set = mockShareMemberships[share.recordID], set.contains(key) {
                set.remove(key)
                mockShareMemberships[share.recordID] = set
                if !revokedShareIDs.contains(share.recordID) {
                    revokedShareIDs.append(share.recordID)
                }
                removed = true
            }
            if let match = share.participants.first(where: { ShareParticipantKey.key(for: $0) == key }) {
                share.removeParticipant(match)
                if !revokedShareIDs.contains(share.recordID) {
                    revokedShareIDs.append(share.recordID)
                }
                removed = true
            }
        }
        guard removed else {
            throw CloudKitServiceError.shareFailed("No role share contains a participant matching this identity — the revocation was not performed")
        }
    }

    func fetchShareParticipantRoles(for rootRecordID: CKRecord.ID) async throws -> [String: UserRole] {
        var rolesByIdentity: [String: UserRole] = [:]
        for share in mockShares where share.recordID.zoneID == rootRecordID.zoneID {
            guard let title = share[CKShare.SystemFieldKey.title] as? String, let role = UserRole.fromShareTitle(title) else { continue }
            if let keys = mockShareMemberships[share.recordID] {
                for key in keys {
                    rolesByIdentity[key] = role
                    if key.hasPrefix("record:"), let recordName = key.split(separator: ":", maxSplits: 1).last.map(String.init) {
                        rolesByIdentity[recordName] = role
                    }
                }
            }
            for participant in share.participants where participant.role != .owner {
                if let key = ShareParticipantKey.key(for: participant) {
                    rolesByIdentity[key] = role
                }
                if let recordName = participant.userIdentity.userRecordID?.recordName {
                    rolesByIdentity[recordName] = role
                }
            }
        }
        // Handle mock keys that may not have a share yet (fallback)
        if mockShareMemberships.isEmpty {
            return rolesByIdentity
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

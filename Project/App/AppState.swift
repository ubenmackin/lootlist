import CloudKit
import Foundation
import os

@MainActor
@Observable
final class AppState {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "Security")

    enum AuthStatus: Equatable {
        case restoringSession
        case checkingCloudData
        case detectedPreviousFamily(family: Family, profile: Profile, zoneID: CKRecordZone.ID, isOwner: Bool)
        case onboarding
        case authenticated
    }

    var authStatus: AuthStatus

    var currentProfile: Profile?

    var family: Family?

    /// The CloudKit zone ID for the current family's shared data.
    /// Set during onboarding or session restoration.
    var familyZoneID: CKRecordZone.ID?

    /// Whether the current user is the owner of the family zone.
    /// - `true` → Guild Master created the zone in `privateCloudDatabase`.
    /// - `false` → Hero joined via CKShare; data lives in `sharedCloudDatabase`.
    var isZoneOwner: Bool = false

    /// The active CKShare for the family zone (Guild Master only).
    /// Used to generate invitation links for new family members.
    var activeShareURL: URL?

    // MARK: - Session Persistence Keys

    private static let profileIDKey = "session_profileRecordName"
    private static let familyIDKey = "session_familyRecordName"
    private static let zoneNameKey = "session_familyZoneName"
    private static let zoneOwnerKey = "session_familyZoneOwnerName"
    private static let isOwnerKey = "session_isZoneOwner"
    private static let hasSessionKey = "session_hasActiveSession"
    private static let abandonedZoneIDsKey = "session_abandonedFamilyZoneNames"

    init() {
        let hasSession = UserDefaults.standard.bool(forKey: Self.hasSessionKey)
        authStatus = hasSession ? .restoringSession : .checkingCloudData
    }

    // MARK: - Abandoned Zone Queue Management

    var abandonedZoneIDs: [String] {
        get {
            UserDefaults.standard.stringArray(forKey: Self.abandonedZoneIDsKey) ?? []
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.abandonedZoneIDsKey)
        }
    }

    func addAbandonedZoneID(_ zoneName: String) {
        var current = abandonedZoneIDs
        if !current.contains(zoneName) {
            current.append(zoneName)
            abandonedZoneIDs = current
        }
    }

    func removeAbandonedZoneID(_ zoneName: String) {
        var current = abandonedZoneIDs
        current.removeAll { $0 == zoneName }
        abandonedZoneIDs = current
    }

    func saveSession(profile: Profile, family: Family, zoneID: CKRecordZone.ID, isOwner: Bool) {
        let defaults = UserDefaults.standard
        defaults.set(profile.id.recordName, forKey: Self.profileIDKey)
        defaults.set(family.id.recordName, forKey: Self.familyIDKey)
        defaults.set(zoneID.zoneName, forKey: Self.zoneNameKey)
        defaults.set(zoneID.ownerName, forKey: Self.zoneOwnerKey)
        defaults.set(isOwner, forKey: Self.isOwnerKey)
        defaults.set(true, forKey: Self.hasSessionKey)
    }

    func clearSession() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.profileIDKey)
        defaults.removeObject(forKey: Self.familyIDKey)
        defaults.removeObject(forKey: Self.zoneNameKey)
        defaults.removeObject(forKey: Self.zoneOwnerKey)
        defaults.removeObject(forKey: Self.isOwnerKey)
        defaults.removeObject(forKey: Self.hasSessionKey)
        signOutInternal()
    }

    func restoreSession(cloudKit: CloudKitService) async {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Self.hasSessionKey),
              let profileRecordName = defaults.string(forKey: Self.profileIDKey),
              let familyRecordName = defaults.string(forKey: Self.familyIDKey),
              let zoneName = defaults.string(forKey: Self.zoneNameKey),
              let zoneOwnerName = defaults.string(forKey: Self.zoneOwnerKey)
        else {
            authStatus = .checkingCloudData
            await discoverExistingCloudState(cloudKit: cloudKit)
            return
        }

        let isOwner = defaults.bool(forKey: Self.isOwnerKey)
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: zoneOwnerName)

        cloudKit.activeFamilyZoneID = zoneID
        cloudKit.activeIsOwner = isOwner
        let db = cloudKit.database(isOwner: isOwner)

        let profileID = CKRecord.ID(recordName: profileRecordName, zoneID: zoneID)
        let familyID = CKRecord.ID(recordName: familyRecordName, zoneID: zoneID)

        do {
            let fetchedProfile: Profile = try await cloudKit.fetch(Profile.self, id: profileID, using: db)
            let fetchedFamily: Family = try await cloudKit.fetch(Family.self, id: familyID, using: db)

            self.familyZoneID = zoneID
            self.isZoneOwner = isOwner
            self.family = fetchedFamily
            self.currentProfile = fetchedProfile

            if isOwner {
                self.activeShareURL = try? await cloudKit.fetchOrCreateShareURL(in: zoneID, rootRecordID: familyID)
            } else {
                self.activeShareURL = nil
            }

            self.authStatus = .authenticated
        } catch {
            logger.error("Session restoration failed: \(error, privacy: .private)")
            if let ckErr = error as? CloudKitServiceError, case .notFound = ckErr {
                clearSession()
            } else {
                // Non-destructive: fallback to cloud discovery or onboarding without deleting saved session keys
                authStatus = .onboarding
            }
        }
    }

    // MARK: - Cloud State Discovery

    func discoverExistingCloudState(cloudKit: CloudKitService) async {
        guard authStatus == .checkingCloudData else { return }

        print("[CloudDiscovery] Starting iCloud family discovery...")
        let userRecordID = try? await cloudKit.currentUserRecordID()
        print("[CloudDiscovery] Current user record ID: \(userRecordID?.recordName ?? "nil")")

        // 1. Parent Search: Check privateCloudDatabase custom zones
        do {
            let privateZones = try await cloudKit.fetchPrivateZones()
            print("[CloudDiscovery] Found \(privateZones.count) private zones: \(privateZones.map { $0.zoneID.zoneName })")
            let customZones = privateZones.filter { $0.zoneID.zoneName != "_defaultZone" && $0.zoneID.zoneName != "LootListZone" }

            for zone in customZones {
                print("[CloudDiscovery] Inspecting private custom zone: '\(zone.zoneID.zoneName)'")
                let db = cloudKit.privateDatabase

                var family: Family? = nil

                // Strategy A: Direct point lookup by zone record ID (requires no CloudKit query index)
                let familyID = CKRecord.ID(recordName: zone.zoneID.zoneName, zoneID: zone.zoneID)
                if let fetched: Family = try? await cloudKit.fetch(Family.self, id: familyID, using: db) {
                    family = fetched
                    print("[CloudDiscovery] Direct point lookup found Family: '\(fetched.name)'")
                }

                // Strategy B: Query search fallback
                if family == nil {
                    do {
                        let families: [Family] = try await cloudKit.query(Family.self, predicate: NSPredicate(value: true), in: zone.zoneID, using: db)
                        family = families.first
                        print("[CloudDiscovery] Query fallback returned \(families.count) Family records.")
                    } catch {
                        print("[CloudDiscovery] Query fallback error for zone '\(zone.zoneID.zoneName)': \(error)")
                    }
                }

                if let foundFamily = family {
                    var profile: Profile? = nil

                    // Strategy A: Direct point lookup for Guild Master profile using createdBy record ID
                    let creatorID = CKRecord.ID(recordName: foundFamily.createdBy.recordName, zoneID: zone.zoneID)
                    if let fetchedProfile: Profile = try? await cloudKit.fetch(Profile.self, id: creatorID, using: db), fetchedProfile.isActive {
                        profile = fetchedProfile
                        print("[CloudDiscovery] Direct point lookup found active Guild Master profile: '\(fetchedProfile.displayName)'")
                    }

                    // Strategy B: Query search fallback for profiles
                    if profile == nil {
                        do {
                            let profiles: [Profile] = try await cloudKit.query(Profile.self, predicate: NSPredicate(value: true), in: zone.zoneID, using: db)
                            print("[CloudDiscovery] Profile query returned \(profiles.count) Profile records.")
                            profile = profiles.first(where: { $0.role == .guildMaster && $0.isActive }) ?? profiles.first(where: { $0.isActive })
                        } catch {
                            print("[CloudDiscovery] Profile query error for zone '\(zone.zoneID.zoneName)': \(error)")
                        }
                    }

                    if let activeProfile = profile {
                        print("[CloudDiscovery] SUCCESS: Detected Guild Master profile '\(activeProfile.displayName)' in family '\(foundFamily.name)'")
                        self.authStatus = .detectedPreviousFamily(family: foundFamily, profile: activeProfile, zoneID: zone.zoneID, isOwner: true)
                        return
                    }
                }
            }
        } catch {
            print("[CloudDiscovery] Error fetching private zones: \(error)")
        }

        // 2. Child Search: Check sharedCloudDatabase zones
        do {
            let sharedZones = try await cloudKit.fetchSharedZones()
            print("[CloudDiscovery] Found \(sharedZones.count) shared zones: \(sharedZones.map { $0.zoneID.zoneName })")

            for zone in sharedZones {
                print("[CloudDiscovery] Inspecting shared zone: '\(zone.zoneID.zoneName)'")
                let db = cloudKit.sharedDatabase

                do {
                    let profiles: [Profile] = try await cloudKit.query(Profile.self, predicate: NSPredicate(value: true), in: zone.zoneID, using: db)
                    print("[CloudDiscovery] Shared zone '\(zone.zoneID.zoneName)' returned \(profiles.count) Profile records.")

                    if let activeHeroProfile = profiles.first(where: { $0.isActive && (userRecordID == nil || $0.iCloudUserID.recordName == userRecordID?.recordName) }) ?? profiles.first(where: { $0.isActive }) {
                        let sharedFamilyID = CKRecord.ID(recordName: zone.zoneID.zoneName, zoneID: zone.zoneID)
                        var family: Family? = try? await cloudKit.fetch(Family.self, id: sharedFamilyID, using: db)
                        if family == nil {
                            let families: [Family] = (try? await cloudKit.query(Family.self, predicate: NSPredicate(value: true), in: zone.zoneID, using: db)) ?? []
                            family = families.first
                        }

                        if let family {
                            print("[CloudDiscovery] SUCCESS: Detected Hero profile '\(activeHeroProfile.displayName)' in shared family '\(family.name)'")
                            self.authStatus = .detectedPreviousFamily(family: family, profile: activeHeroProfile, zoneID: zone.zoneID, isOwner: false)
                            return
                        }
                    }
                } catch {
                    print("[CloudDiscovery] Error querying shared zone '\(zone.zoneID.zoneName)': \(error)")
                }
            }
        } catch {
            print("[CloudDiscovery] Error fetching shared zones: \(error)")
        }

        print("[CloudDiscovery] Discovery complete — no active family detected. Transitioning to onboarding.")
        self.authStatus = .onboarding
    }

    func acceptDetectedFamily(family: Family, profile: Profile, zoneID: CKRecordZone.ID, isOwner: Bool, cloudKit: CloudKitService) {
        saveSession(profile: profile, family: family, zoneID: zoneID, isOwner: isOwner)
        self.familyZoneID = zoneID
        self.isZoneOwner = isOwner
        self.family = family
        self.currentProfile = profile
        cloudKit.activeFamilyZoneID = zoneID
        cloudKit.activeIsOwner = isOwner
        if isOwner {
            Task {
                self.activeShareURL = try? await cloudKit.fetchOrCreateShareURL(in: zoneID, rootRecordID: family.id)
            }
        }
        self.authStatus = .authenticated
    }

    func rejectDetectedFamily(family: Family, profile: Profile, zoneID: CKRecordZone.ID, isOwner: Bool, cloudKit: CloudKitService) async {
        if isOwner {
            addAbandonedZoneID(zoneID.zoneName)
            try? await cloudKit.deleteZone(zoneID)
            removeAbandonedZoneID(zoneID.zoneName)
        } else {
            var deactivated = profile
            deactivated.isActive = false
            let db = cloudKit.database(isOwner: false)
            _ = try? await cloudKit.save(deactivated, in: zoneID, using: db)
        }
        clearSession()
    }

    func signOut() {
        clearSession()
    }

    private func signOutInternal() {
        authStatus = .onboarding
        currentProfile = nil
        family = nil
        familyZoneID = nil
        isZoneOwner = false
        activeShareURL = nil
    }
}

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

            familyZoneID = zoneID
            isZoneOwner = isOwner
            family = fetchedFamily
            currentProfile = fetchedProfile

            if isOwner {
                activeShareURL = try? await cloudKit.fetchOrCreateShareURL(in: zoneID, rootRecordID: familyID)
            } else {
                activeShareURL = nil
            }

            authStatus = .authenticated
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

    // CloudKit discoverability logic requires branching over known containers; refactoring would be a behavioral change outside lint scope.
    // swiftlint:disable:next cyclomatic_complexity
    func discoverExistingCloudState(cloudKit: CloudKitService) async {
        guard authStatus == .checkingCloudData else { return }

        logger.info("Starting iCloud family discovery...")
        let userRecordID = try? await cloudKit.currentUserRecordID()
        logger.info("Current user record ID: \(userRecordID?.recordName ?? "nil", privacy: .private)")

        // 1. Parent Search: Check privateCloudDatabase custom zones
        do {
            let privateZones = try await cloudKit.fetchPrivateZones()
            logger.info("Found \(privateZones.count) private zones")
            let customZones = privateZones.filter { $0.zoneID.zoneName != "_defaultZone" && $0.zoneID.zoneName != "LootListZone" }

            for zone in customZones {
                logger.info("Inspecting private custom zone: '\(zone.zoneID.zoneName, privacy: .private)'")
                let db = cloudKit.privateDatabase

                var family: Family?

                // Strategy A: Direct point lookup by zone record ID (requires no CloudKit query index)
                let familyID = CKRecord.ID(recordName: zone.zoneID.zoneName, zoneID: zone.zoneID)
                if let fetched: Family = try? await cloudKit.fetch(Family.self, id: familyID, using: db) {
                    family = fetched
                    logger.info("Direct point lookup found Family: '\(fetched.name, privacy: .private)'")
                }

                // Strategy B: Query search fallback
                if family == nil {
                    do {
                        let families: [Family] = try await cloudKit.query(Family.self, predicate: NSPredicate(value: true), in: zone.zoneID, using: db)
                        family = families.first
                        logger.info("Query fallback returned \(families.count) Family records.")
                    } catch {
                        logger.error("Query fallback error for zone '\(zone.zoneID.zoneName, privacy: .private)': \(error, privacy: .private)")
                    }
                }

                if let foundFamily = family {
                    var profile: Profile?

                    // Strategy A: Direct point lookup for Guild Master profile using createdBy record ID
                    let creatorID = CKRecord.ID(recordName: foundFamily.createdBy.recordName, zoneID: zone.zoneID)
                    if let fetchedProfile: Profile = try? await cloudKit.fetch(Profile.self, id: creatorID, using: db), fetchedProfile.isActive {
                        profile = fetchedProfile
                        logger.info("Direct point lookup found active Guild Master profile: '\(fetchedProfile.displayName, privacy: .private)'")
                    }

                    // Strategy B: Query search fallback for profiles
                    if profile == nil {
                        do {
                            let profiles: [Profile] = try await cloudKit.query(Profile.self, predicate: NSPredicate(value: true), in: zone.zoneID, using: db)
                            logger.info("Profile query returned \(profiles.count) Profile records.")
                            profile = profiles.first(where: { $0.role == .guildMaster && $0.isActive }) ?? profiles.first(where: { $0.isActive })
                        } catch {
                            logger.error("Profile query error for zone '\(zone.zoneID.zoneName, privacy: .private)': \(error, privacy: .private)")
                        }
                    }

                    if let activeProfile = profile {
                        logger.info("SUCCESS: Detected Guild Master profile '\(activeProfile.displayName, privacy: .private)' in family '\(foundFamily.name, privacy: .private)'")
                        authStatus = .detectedPreviousFamily(family: foundFamily, profile: activeProfile, zoneID: zone.zoneID, isOwner: true)
                        return
                    }
                }
            }
        } catch {
            logger.error("Error fetching private zones: \(error, privacy: .private)")
        }

        // 2. Child Search: Check sharedCloudDatabase zones
        do {
            var sharedZones = try await cloudKit.fetchSharedZones()
            logger.info("Initial shared zones check: \(sharedZones.count) shared zones")

            // If empty on cold launch (reinstall), perform a brief retry pulse to allow CloudKit daemon to sync accepted shares
            if sharedZones.isEmpty {
                for attempt in 1 ... AppConstants.Sync.maxPulseAttempts {
                    logger.info("Shared zone sync pulse attempt \(attempt)...")
                    try? await Task.sleep(nanoseconds: AppConstants.Sync.pulseDelayNanoseconds)
                    sharedZones = await (try? cloudKit.fetchSharedZones()) ?? []
                    if !sharedZones.isEmpty {
                        logger.info("Shared zone sync pulse succeeded! Found \(sharedZones.count) shared zones.")
                        break
                    }
                }
            }

            logger.info("Final shared zones count: \(sharedZones.count)")

            for zone in sharedZones {
                logger.info("Inspecting shared zone: '\(zone.zoneID.zoneName, privacy: .private)' (owner: '\(zone.zoneID.ownerName, privacy: .private)')")
                let db = cloudKit.sharedDatabase

                do {
                    let profiles: [Profile] = try await cloudKit.query(Profile.self, predicate: NSPredicate(value: true), in: zone.zoneID, using: db)
                    logger.info("Shared zone '\(zone.zoneID.zoneName, privacy: .private)' returned \(profiles.count) Profile records.")

                    if let activeHeroProfile = profiles.first(where: { $0.isActive && (userRecordID == nil || $0.iCloudUserID.recordName == userRecordID?.recordName) }) ?? profiles
                        .first(where: { $0.isActive })
                    {
                        let sharedFamilyID = CKRecord.ID(recordName: zone.zoneID.zoneName, zoneID: zone.zoneID)
                        var family: Family? = try? await cloudKit.fetch(Family.self, id: sharedFamilyID, using: db)
                        if family == nil {
                            let families: [Family] = await (try? cloudKit.query(Family.self, predicate: NSPredicate(value: true), in: zone.zoneID, using: db)) ?? []
                            family = families.first
                        }

                        if let family {
                            logger.info("SUCCESS: Detected Hero profile '\(activeHeroProfile.displayName, privacy: .private)' in shared family '\(family.name, privacy: .private)'")
                            authStatus = .detectedPreviousFamily(family: family, profile: activeHeroProfile, zoneID: zone.zoneID, isOwner: false)
                            return
                        }
                    }
                } catch {
                    logger.error("Error querying shared zone '\(zone.zoneID.zoneName, privacy: .private)': \(error, privacy: .private)")
                }
            }
        } catch {
            logger.error("Error fetching shared zones: \(error, privacy: .private)")
        }

        logger.info("Discovery complete — no active family detected. Transitioning to onboarding.")
        authStatus = .onboarding
    }

    func acceptDetectedFamily(family: Family, profile: Profile, zoneID: CKRecordZone.ID, isOwner: Bool, cloudKit: CloudKitService) async {
        saveSession(profile: profile, family: family, zoneID: zoneID, isOwner: isOwner)
        familyZoneID = zoneID
        isZoneOwner = isOwner
        self.family = family
        currentProfile = profile
        cloudKit.activeFamilyZoneID = zoneID
        cloudKit.activeIsOwner = isOwner
        if isOwner {
            do {
                activeShareURL = try await cloudKit.fetchOrCreateShareURL(in: zoneID, rootRecordID: family.id)
            } catch {
                logger.error("Failed to generate share URL on accept: \(error, privacy: .private)")
            }
        }
        authStatus = .authenticated
    }

    func rejectDetectedFamily(family _: Family, profile: Profile, zoneID: CKRecordZone.ID, isOwner: Bool, cloudKit: CloudKitService) async {
        if isOwner {
            addAbandonedZoneID(zoneID.zoneName)
            do {
                try await cloudKit.deleteZone(zoneID)
                removeAbandonedZoneID(zoneID.zoneName)
            } catch {
                logger.error("Failed to delete zone on rejection: \(error, privacy: .private)")
            }
        } else {
            var deactivated = profile
            deactivated.isActive = false
            let db = cloudKit.database(isOwner: false)
            do {
                _ = try await cloudKit.save(deactivated, in: zoneID, using: db)
            } catch {
                logger.error("Failed to save profile deactivation on rejection: \(error, privacy: .private)")
            }
        }
        clearSession()
    }

    var shareInviteItems: [Any] {
        let name = family?.name ?? "our guild"
        if let activeShareURL {
            let message = "Join \(name) on LootList! Tap the link to join our guild:\n\(activeShareURL.absoluteString)"
            return [message, activeShareURL]
        } else {
            let message = "Join \(name) on LootList!"
            return [message]
        }
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

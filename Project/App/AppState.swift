import CloudKit
import Foundation

@MainActor
@Observable
final class AppState {
    enum AuthStatus: Equatable {
        case restoringSession
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

    init() {
        let hasSession = UserDefaults.standard.bool(forKey: Self.hasSessionKey)
        authStatus = hasSession ? .restoringSession : .onboarding
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
            authStatus = .onboarding
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
            self.authStatus = .authenticated
        } catch {
            print("Session restoration failed: \(error)")
            clearSession()
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

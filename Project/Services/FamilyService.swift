import Foundation
import CloudKit

enum FamilyServiceError: Error, Equatable, Sendable {

    case invalidInviteCode

    case joinFailed(String)

    case creationFailed(String)

    case accountUnavailable
}

@MainActor
@Observable
final class FamilyService {

    private let cloudKit: CloudKitService

    private let appState: AppState

    init(cloudKit: CloudKitService, appState: AppState) {
        self.cloudKit = cloudKit
        self.appState = appState
    }

    @discardableResult
    func createFamily(name: String,
                       ownerProfile: Profile) async throws -> Family {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw FamilyServiceError.creationFailed("Family name cannot be empty.")
        }

        let familyID = CKRecord.ID(recordName: UUID().uuidString)
        let zoneID = CKRecordZone.ID(zoneName: familyID.recordName,
                                       ownerName: "__defaultOwner__")

        do {
            try await cloudKit.ensureZoneExists(zoneID)
        } catch {
            throw FamilyServiceError.creationFailed(
                "Could not create family zone: \(error)")
        }

        let code = Self.generateInviteCode(seed: familyID.recordName)

        var family = Family(name: name,
                              createdBy: ownerProfile.id,
                              inviteCode: code,
                              id: familyID)

        do {
            family = try await cloudKit.save(family, in: zoneID)
        } catch {
            throw FamilyServiceError.creationFailed(
                "Could not save family record: \(error)")
        }

        var owner = ownerProfile
        owner.role = .guildMaster
        owner.family = CKRecord.Reference(recordID: family.id, action: .none)
        owner.isActive = true

        do {
            let savedOwner = try await cloudKit.save(owner, in: zoneID)

            appState.family = family
            appState.currentProfile = savedOwner
            appState.authStatus = .authenticated
        } catch {
            throw FamilyServiceError.creationFailed(
                "Could not save guild master profile: \(error)")
        }

        return family
    }

    func generateInviteCode(family: Family) -> String {
        family.inviteCode
    }

    static func generateInviteCode(seed: String) -> String {

        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

        var hash: UInt64 = 0xcbf29ce484222325
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }

        var code = ""
        var remaining = hash
        for _ in 0..<6 {
            let index = Int(remaining % UInt64(alphabet.count))
            code.append(alphabet[index])
            remaining /= UInt64(alphabet.count)

            if remaining == 0 { remaining = hash &* 0x100000001b3 }
        }
        return code
    }

    @discardableResult
    func joinFamily(code: String,
                     heroProfile: Profile) async throws -> Family {
        let normalized = code
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()

        guard !normalized.isEmpty else {
            throw FamilyServiceError.invalidInviteCode
        }

        let families: [Family]
        do {
            families = try await cloudKit.query(
                Family.self,
                predicate: NSPredicate(format: "inviteCode == %@",
                                          normalized))
        } catch {
            throw FamilyServiceError.joinFailed(
                "Could not look up invite code: \(error)")
        }

        guard let family = families.first else {
            throw FamilyServiceError.invalidInviteCode
        }

        let heroZoneID = CKRecordZone.ID(zoneName: family.id.recordName,
                                            ownerName: "__defaultOwner__")

        var hero = heroProfile
        hero.role = .hero
        hero.family = CKRecord.Reference(recordID: family.id, action: .none)
        hero.isActive = true

        do {
            let savedHero = try await cloudKit.save(hero, in: heroZoneID)
            appState.family = family
            appState.currentProfile = savedHero
            appState.authStatus = .authenticated
        } catch {
            throw FamilyServiceError.joinFailed(
                "Could not save hero profile: \(error)")
        }

        return family
    }

    func updateMemberRole(profile: Profile, newRole: UserRole) async throws {
        var updated = profile
        updated.role = newRole

        let zoneID = CKRecordZone.ID(zoneName: profile.family.recordID.recordName,
                                       ownerName: "__defaultOwner__")
        do {
            _ = try await cloudKit.save(updated, in: zoneID)
        } catch {
            throw FamilyServiceError.creationFailed(
                "Could not update role: \(error)")
        }
    }

    func leaveFamily(profile: Profile) async throws {
        var updated = profile
        updated.isActive = false

        let zoneID = CKRecordZone.ID(zoneName: profile.family.recordID.recordName,
                                       ownerName: "__defaultOwner__")
        do {
            _ = try await cloudKit.save(updated, in: zoneID)
        } catch {
            throw FamilyServiceError.creationFailed(
                "Could not leave family: \(error)")
        }
    }
}

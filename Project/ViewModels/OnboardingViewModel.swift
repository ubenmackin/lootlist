//
//  OnboardingViewModel.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation

enum OnboardingStep: Hashable, Sendable {
    case welcome

    case roleSelection

    case familyCreation

    case familyJoin

    case avatarSelection

    case done
}

/// A single active `Profile` bound to the current iCloud user, discovered in a
/// shared zone during hero onboarding, together with the family and zone it
/// belongs to. Lets a returning hero reconnect to their existing guild instead
/// of minting a duplicate profile (see `checkForExistingHero`).
struct DetectedHero {
    let family: Family
    let profile: Profile
    let zoneID: CKRecordZone.ID
}

@MainActor
@Observable
final class OnboardingViewModel {
    var selectedRole: UserRole?

    var displayName: String = ""

    var avatarClass: AvatarClass?

    var avatarPresetID: String?

    var customAvatarImageData: Data?

    var shareURLString: String = ""

    var sharedMetadata: CKShare.Metadata?

    var familyName: String = ""

    var path: [OnboardingStep] = []

    var currentStep: OnboardingStep {
        path.last ?? .welcome
    }

    var error: String?

    var isLoading: Bool = false

    var shareURL: URL?
    var pendingShareMetadata: CKShare.Metadata?

    /// Set when the hero onboarding path discovers exactly one active `Profile`
    /// bound to the current iCloud user across the shared zones, before Avatar
    /// Selection. Defense-in-depth UX surface: lets a returning hero reconnect
    /// to their existing guild instead of minting a duplicate profile. The
    /// service layer already refuses to mint a duplicate; this is the nicer
    /// prompt on top.
    var detectedHero: DetectedHero?

    private let familyService: FamilyService

    private let appState: AppState

    private(set) var builtFamily: Family?

    private(set) var builtProfile: Profile?

    init(familyService: FamilyService, appState: AppState) {
        self.familyService = familyService
        self.appState = appState
    }

    func advanceFromRoleSelection() {
        guard let role = selectedRole else { return }
        switch role.isParent {
        case true: push(.familyCreation)
        case false:
            if role == .hero {
                checkForExistingHero()
            }
            push(.familyJoin)
        }
    }

    /// Probing helper for the hero onboarding path. Kicks off a fire-and-forget
    /// scan of the user's shared zones looking for an existing, active `Profile`
    /// bound to the current iCloud user. If exactly one match is found while the
    /// user is still on the hero path, `detectedHero` is populated so the
    /// FamilyJoin screen can offer a "Reconnect to Guild" prompt before Avatar
    /// Selection. This is defense-in-depth only — the service layer already
    /// refuses to mint a duplicate profile, so this scan merely surfaces the
    /// reconnect option earlier in the flow.
    func checkForExistingHero() {
        guard selectedRole == .hero else { return }
        Task { @MainActor [weak self] in
            await self?.performExistingHeroCheck()
        }
    }

    private func performExistingHeroCheck() async {
        guard selectedRole == .hero else { return }

        guard let userID = await (try? familyService.cloudKitReference.currentUserRecordID()) else {
            detectedHero = nil
            return
        }

        let sharedZones = await (try? familyService.cloudKitReference.fetchSharedZones()) ?? []

        var matches: [(zoneID: CKRecordZone.ID, profile: Profile)] = []
        for zone in sharedZones {
            let zoneID = zone.zoneID
            let activeProfiles = await AppState.activeSharedHeroProfiles(
                cloudKit: familyService.cloudKitReference,
                userRecordID: userID,
                zoneID: zoneID
            )
            for profile in activeProfiles {
                matches.append((zoneID, profile))
            }
        }

        // Only a single discoverable active hero warrants the reconnect prompt.
        guard matches.count == 1, let match = matches.first else {
            detectedHero = nil
            return
        }

        // Resolve the Family record in the matching shared zone (point lookup
        // first, query fallback second — shared with AppState discovery).
        guard let family = await AppState.sharedZoneFamily(
            cloudKit: familyService.cloudKitReference,
            zoneID: match.zoneID
        ) else {
            detectedHero = nil
            return
        }

        detectedHero = DetectedHero(family: family, profile: match.profile, zoneID: match.zoneID)
    }

    func backToRoleSelection() {
        popTo(.roleSelection)
    }

    func advanceToAvatarSelection() {
        push(.avatarSelection)
    }

    func backToWelcome() {
        path = []
    }

    func goToRoleSelection() {
        push(.roleSelection)
    }

    func pushBackFromAvatar() {
        popTo(isParentFlow ? .familyCreation : .familyJoin)
    }

    private func push(_ step: OnboardingStep) {
        path.append(step)
    }

    private func popTo(_ target: OnboardingStep) {
        if let index = path.firstIndex(of: target) {
            path = Array(path[...index])
        } else {
            path = [target]
        }
    }

    func createFamily(name: String) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            error = "Your guild needs a name, Guild Master."
            return
        }
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            error = "Pick a name before founding your guild."
            return
        }

        error = nil

        // Resolve the iCloud user ID up front. Surfacing a failure here (vs.
        // synthesizing a random UUID) prevents duplicate `Profile` records on
        // re-runs over a flaky network. The finalize button serves as the
        // retry affordance — see `iCloudUserID()` docs.
        let owneriCloudID: CKRecord.ID
        do {
            owneriCloudID = try await iCloudUserID()
        } catch {
            self.error = "Could not reach iCloud to identify your account. Check your network and tap Found the Guild to retry."
            return
        }

        let ownerProfile = Profile(
            displayName: trimmedName,
            avatarClass: avatarClass,
            avatarPresetID: avatarPresetID,
            customAvatarImageData: customAvatarImageData,
            role: .guildMaster,
            iCloudUserID: owneriCloudID,
            family: CKRecord.Reference(recordID: CKRecord.ID(recordName: "pending"),
                                       action: .none)
        )

        do {
            let result = try await familyService.createFamily(
                name: trimmed,
                ownerProfile: ownerProfile
            )

            builtFamily = result.family
            builtProfile = result.profile
            shareURL = result.shareURL
            familyName = trimmed
            push(.done)
        } catch let familyError as FamilyServiceError {
            print("Failed to create family: \(familyError.localizedDescription)")
            error = familyError.localizedDescription
        } catch {
            print("Failed to create family: \(error)")
            self.error = "Could not found your guild: \(error)"
        }
    }

    func joinFamilyViaShareLink() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            error = "Pick a name before joining your party."
            return
        }

        error = nil

        // 1. If user pasted a share URL string into the join field, resolve its metadata first
        if pendingShareMetadata == nil {
            let rawURL = shareURLString.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: rawURL) {
                do {
                    let metadata = try await familyService.cloudKitReference.fetchShareMetadata(for: url)
                    pendingShareMetadata = metadata
                } catch {
                    self.error = "Could not open share invitation: \(error.localizedDescription)"
                    return
                }
            } else if !rawURL.isEmpty {
                error = "The invitation link is not a valid URL."
                return
            }
        }

        guard let metadata = pendingShareMetadata else {
            error = "No share invitation found. Ask your Guild Master to send an invitation link."
            return
        }

        // Resolve the iCloud user ID up front. Surfacing a failure here (vs.
        // synthesizing a random UUID) prevents duplicate `Profile` records on
        // re-runs over a flaky network. The finalize button serves as the
        // retry affordance — see `iCloudUserID()` docs.
        let heroiCloudID: CKRecord.ID
        do {
            heroiCloudID = try await iCloudUserID()
        } catch {
            self.error = "Could not reach iCloud to identify your account. Check your network and tap Join the Quest to retry."
            return
        }

        let heroProfile = Profile(
            displayName: trimmedName,
            avatarClass: avatarClass,
            avatarPresetID: avatarPresetID,
            customAvatarImageData: customAvatarImageData,
            role: .hero,
            iCloudUserID: heroiCloudID,
            family: CKRecord.Reference(recordID: CKRecord.ID(recordName: "pending"),
                                       action: .none)
        )

        do {
            let result = try await familyService.joinFamilyViaShare(
                metadata: metadata,
                heroProfile: heroProfile
            )
            builtFamily = result.family
            builtProfile = result.profile
            pendingShareMetadata = nil
            push(.done)
        } catch let familyError as FamilyServiceError {
            error = familyError.localizedDescription
        } catch {
            self.error = "Could not join the guild: \(error)"
        }
    }

    var isParentFlow: Bool {
        selectedRole?.isParent ?? false
    }

    var hasShareInvitation: Bool {
        pendingShareMetadata != nil
    }

    func completeOnboarding(family: Family?, profile: Profile?) {
        guard let family, let profile else { return }
        appState.family = family
        appState.currentProfile = profile
        appState.authStatus = .authenticated
        reset()
    }

    func reset() {
        selectedRole = nil
        displayName = ""
        avatarClass = nil
        avatarPresetID = nil
        customAvatarImageData = nil
        shareURLString = ""
        familyName = ""
        error = nil
        isLoading = false
        path = []
        builtFamily = nil
        builtProfile = nil
        shareURL = nil
        pendingShareMetadata = nil
        detectedHero = nil
    }

    private func iCloudUserID() async throws -> CKRecord.ID {
        try await familyService.cloudKitReference.currentUserRecordID()
    }
}

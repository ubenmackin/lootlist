//
//  OnboardingViewModel.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
import os

enum OnboardingStep: Hashable, Sendable {
    case welcome

    case roleSelection

    case familyCreation

    case familyJoin

    case avatarSelection

    case done
}

/// The intent a new user declares on the role-selection screen. The joiner's
/// role is deliberately unknown here — it arrives baked into the accepted share
/// — so onboarding captures only the family-vs-join choice.
enum UserIntent: String, Hashable, Sendable {
    case createFamily
    case joinFamily
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
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "Onboarding")

    var userIntent: UserIntent?

    var displayName: String = ""

    var avatarClass: AvatarClass?

    var avatarPresetID: String?

    var customAvatarImageData: Data?

    var familyName: String = ""

    var path: [OnboardingStep] = []

    var currentStep: OnboardingStep {
        path.last ?? .welcome
    }

    var error: String?

    var isLoading: Bool = false

    var joinProgressStatus: String?

    var joinProgressFraction: Double?

    var pendingShareMetadata: CKShare.Metadata?

    /// Populated when hero discovery identifies an existing active profile in shared zones.
    var detectedHero: DetectedHero?

    private let familyService: FamilyService

    private let appState: AppState

    private(set) var builtFamily: Family?

    private(set) var builtProfile: Profile?

    /// Indicates whether `joinFamilyViaAcceptedShare` reused an existing active profile without modification.
    private(set) var didReuseActiveProfile = false

    init(familyService: FamilyService, appState: AppState) {
        self.familyService = familyService
        self.appState = appState
    }

    func advanceFromIntentSelection() {
        switch userIntent {
        case .createFamily:
            push(.familyCreation)
        case .joinFamily:
            checkForExistingHero()
            push(.familyJoin)
            Task { [weak self] in
                await self?.joinFamilyViaAcceptedShare()
            }
        case nil:
            break
        }
    }

    /// Initiates a background scan of shared zones for an existing active profile matching current user.
    func checkForExistingHero() {
        guard userIntent == .joinFamily else { return }
        Task { [weak self] in
            await self?.performExistingHeroCheck()
        }
    }

    private func performExistingHeroCheck() async {
        guard userIntent == .joinFamily else { return }

        let userID: CKRecord.ID
        do {
            userID = try await familyService.cloudKitReference.currentUserRecordID()
        } catch {
            logger.warning("Failed to resolve current user record ID for hero check: \(error, privacy: .private)")
            detectedHero = nil
            return
        }

        let sharedZones: [CKRecordZone]
        do {
            sharedZones = try await familyService.cloudKitReference.fetchSharedZones()
        } catch {
            logger.warning("Failed to fetch shared zones for hero check: \(error, privacy: .private)")
            sharedZones = []
        }

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
            familyName = trimmed
            push(.done)
        } catch let familyError as FamilyServiceError {
            logger.error("Failed to create family: \(familyError.localizedDescription, privacy: .private)")
            error = "Could not create your guild. Please try again."
        } catch {
            logger.error("Failed to create family: \(error, privacy: .private)")
            self.error = "Could not create your guild. Please try again."
        }
    }

    /// Joiner entry: consumes the pending share metadata that an apple share
    /// invitation resolved (see `pendingShareMetadata`) and accepts the invite
    /// via `FamilyService.joinFamilyViaAcceptedShare`. The joiner's role is
    /// decoded from the share's title by the service — the flow never asks for a
    /// role up front. The accept path mints the Profile with empty
    /// display-name/avatar defaults, so the flow advances straight to Avatar
    /// Selection for the user to pick them.
    func joinFamilyViaAcceptedShare() async {
        let intent = String(describing: self.userIntent)
        let hasMetadata = self.pendingShareMetadata != nil
        logger.info(
            "Joining family via accepted share called. userIntent=\(intent), hasMetadata=\(hasMetadata), isLoading=\(self.isLoading)"
        )
        guard userIntent == .joinFamily,
              let metadata = pendingShareMetadata,
              !isLoading
        else {
            logger.info(
                "Joining family via accepted share guard check failed. (userIntent=\(intent), hasMetadata=\(hasMetadata), isLoading=\(self.isLoading))"
            )
            return
        }
        isLoading = true
        joinProgressStatus = "Accepting family invitation..."
        joinProgressFraction = 0.25
        defer {
            isLoading = false
            joinProgressStatus = nil
            joinProgressFraction = nil
        }

        logger.info("Calling familyService.joinFamilyViaAcceptedShare...")
        do {
            let result = try await familyService.joinFamilyViaAcceptedShare(
                metadata: metadata,
                displayName: displayName,
                avatarClass: avatarClass,
                progressHandler: { [weak self] status, fraction in
                    self?.joinProgressStatus = status
                    self?.joinProgressFraction = fraction
                }
            )
            logger.info("Joined family '\(result.family.name, privacy: .private)' as profile '\(result.profile.displayName, privacy: .private)'")
            builtFamily = result.family
            builtProfile = result.profile
            didReuseActiveProfile = result.didReuseActiveProfile
            pendingShareMetadata = nil
            push(.avatarSelection)
        } catch {
            logger.error("Joining family via accepted share failed: \(error, privacy: .private)")
            if let friendly = friendlyInviteAcceptError(error) {
                self.error = friendly
            } else {
                // Non-invalid-invitation failure: surface a static generic
                // message rather than the raw CloudKit error text.
                self.error = genericJoinerErrorFallback
            }
        }
    }

    /// Completes joiner setup, updating profile name/avatar unless reusing an active profile.
    func completeJoinedProfile() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        guard let profile = builtProfile else {
            error = "Join your family's invitation before setting up your hero."
            return
        }

        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            error = "Pick a name before joining your party."
            return
        }

        error = nil
        appState.currentProfile = profile

        guard !didReuseActiveProfile else {
            builtProfile = profile
            push(.done)
            return
        }

        do {
            let renamed = try await familyService.updateProfileDisplayName(
                profile: profile,
                newName: trimmedName
            )
            let saved = try await familyService.updateProfileAvatar(
                profile: renamed,
                avatarClass: avatarClass,
                avatarPresetID: avatarPresetID,
                customAvatarImageData: customAvatarImageData
            )

            // Persist completed profile synchronously to CloudKit before background sync pull.
            let zoneID = saved.id.zoneID
            let sharedDB = familyService.cloudKit.sharedDatabase
            do {
                let serverSaved = try await familyService.cloudKit.save(saved, in: zoneID, using: sharedDB)
                builtProfile = serverSaved
            } catch {
                // Fallback: the enqueueSave from the update calls will eventually
                // push the correct data. Log and proceed with the local version.
                logger.warning("Failed to persist completed joined profile immediately: \(error, privacy: .private)")
                builtProfile = saved
            }
            push(.done)
        } catch let familyError as FamilyServiceError {
            logger.error("Failed to finalize joined profile: \(familyError.localizedDescription, privacy: .private)")
            error = "Could not set up your hero profile. Please try again."
        } catch {
            logger.error("Failed to finalize joined profile: \(error, privacy: .private)")
            self.error = genericJoinerErrorFallback
        }
    }

    var isParentFlow: Bool {
        userIntent == .createFamily
    }

    func completeOnboarding(family: Family?, profile: Profile?) {
        guard let family, let profile else { return }
        appState.family = family
        appState.currentProfile = profile
        appState.authStatus = .authenticated
        reset()
    }

    func reset() {
        userIntent = nil
        displayName = ""
        avatarClass = nil
        avatarPresetID = nil
        customAvatarImageData = nil
        familyName = ""
        error = nil
        isLoading = false
        path = []
        builtFamily = nil
        builtProfile = nil
        didReuseActiveProfile = false
        pendingShareMetadata = nil
        detectedHero = nil
    }

    private func iCloudUserID() async throws -> CKRecord.ID {
        try await familyService.cloudKitReference.currentUserRecordID()
    }
}

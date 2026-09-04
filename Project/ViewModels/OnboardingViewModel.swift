//
//  OnboardingViewModel.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

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

/// Active Profile matching current iCloud user in a shared zone, for reconnecting without duplicates.
/// CKShare and zone details stay in the Service layer; the ViewModel holds only presentation data.
struct DetectedHero {
    let family: Family
    let profile: Profile
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

    /// Single emoji chosen as the profile's lightweight avatar during onboarding.
    var avatarEmoji: String?

    var familyName: String = ""

    var path: [OnboardingStep] = []

    var currentStep: OnboardingStep {
        path.last ?? .welcome
    }

    var error: String?

    var isLoading: Bool = false

    var joinProgressStatus: String?

    var joinProgressFraction: Double?

    var pendingShareMetadata: InvitationLinkResolution?

    /// Populated when hero discovery identifies an existing active profile in shared zones.
    var detectedHero: DetectedHero?

    private let familyService: FamilyService

    private let appState: AppState

    private let syncCoordinator: CKSyncEngineCoordinator

    private(set) var builtFamily: Family?

    private(set) var builtProfile: Profile?

    /// Indicates whether `joinFamilyViaAcceptedShare` reused an existing active profile without modification.
    private(set) var didReuseActiveProfile = false

    init(familyService: FamilyService, appState: AppState, syncCoordinator: CKSyncEngineCoordinator) {
        self.familyService = familyService
        self.appState = appState
        self.syncCoordinator = syncCoordinator
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
        // All CloudKit zone and identity resolution stays in the Service layer.
        if let hero = await familyService.detectExistingHeroForJoin() {
            detectedHero = DetectedHero(family: hero.family, profile: hero.profile)
        } else {
            detectedHero = nil
        }
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

        do {
            let result = try await familyService.createFamilyWithOnboarding(
                name: trimmed,
                displayName: trimmedName,
                avatarClass: avatarClass,
                avatarPresetID: avatarPresetID,
                customAvatarImageData: customAvatarImageData,
                avatarEmoji: avatarEmoji
            )

            builtFamily = result.family
            builtProfile = result.profile
            familyName = trimmed
            push(.done)
        } catch let familyError as FamilyServiceError {
            logger.error("Failed to create family: \(familyError.localizedDescription, privacy: .private)")
            self.error = "Could not create your guild. Please try again."
        } catch {
            logger.error("Failed to create family: \(error, privacy: .private)")
            self.error = "Could not create your guild. Please try again."
        }
    }

    /// Consumes pending share metadata to join family, resolving role from share title.
    func joinFamilyViaAcceptedShare() async {
        let intent = String(describing: self.userIntent)
        let hasMetadata = self.pendingShareMetadata != nil
        logger.info(
            "Joining family via accepted share called. userIntent=\(intent), hasMetadata=\(hasMetadata), isLoading=\(self.isLoading)"
        )
        guard userIntent == .joinFamily,
              let resolution = pendingShareMetadata,
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
                resolution: resolution,
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

    #if DEBUG
        /// Development-only helper to accept a pasted share URL via the service layer.
        func simulateInviteLink(_ url: URL) async {
            joinProgressStatus = "Reading invitation link..."
            joinProgressFraction = 0.15
            do {
                logger.info("Requesting share metadata for simulated invite URL...")
                let resolved = try await familyService.resolveInvitationLink(url)
                logger.info("Resolved share metadata: zone='\(resolved.zoneName ?? "unknown", privacy: .private)' title='\(resolved.title ?? "unknown", privacy: .private)'")
                joinProgressStatus = "Invitation verified! Connecting to family..."
                joinProgressFraction = 0.3
                pendingShareMetadata = resolved
            } catch {
                joinProgressStatus = nil
                joinProgressFraction = nil
                logger.error("Resolving share metadata failed: \(error, privacy: .private)")
                self.error = friendlyInviteAcceptError(error) ?? "Could not read that share link. Please try again."
            }
        }
    #endif

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
                customAvatarImageData: customAvatarImageData,
                avatarEmoji: avatarEmoji
            )

            // Profile updates already wrote cache and enqueued saves; raw save would cause conflict.
            await syncCoordinator.sendPendingChanges()
            builtProfile = saved
            push(.done)
        } catch let familyError as FamilyServiceError {
            logger.error("Failed to finalize joined profile: \(familyError.localizedDescription, privacy: .private)")
            self.error = "Could not set up your hero profile. Please try again."
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
        avatarEmoji = nil
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
}

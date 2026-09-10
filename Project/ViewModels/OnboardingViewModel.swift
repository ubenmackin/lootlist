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

    case notificationPrime

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
    /// Typed onboarding failures surfaced alongside `error` so callers can
    /// branch without parsing copy. Messages stay stable for existing views.
    enum OnboardingError: Error, Equatable, Sendable, LocalizedError {
        case missingGuildName
        case missingFounderName
        case missingJoinerName
        case missingInvite
        case inviteInvalid
        case joinFailed
        case linkReadFailed
        case familyCreateFailed
        case profileSetupFailed

        var errorDescription: String? {
            switch self {
            case .missingGuildName:
                "Your guild needs a name, Guild Master."
            case .missingFounderName:
                "Pick a name before founding your guild."
            case .missingJoinerName:
                "Pick a name before joining your party."
            case .missingInvite:
                "Join your family's invitation before setting up your hero."
            case .inviteInvalid:
                "This invitation link is invalid or has expired. Please ask the Guild Master for a new invite link."
            case .joinFailed:
                "Could not join the family. Please try again."
            case .linkReadFailed:
                "Could not read that share link. Please try again."
            case .familyCreateFailed:
                "Could not create your guild. Please try again."
            case .profileSetupFailed:
                "Could not set up your hero profile. Please try again."
            }
        }
    }

    private let logger = Logger(category: "Onboarding")

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

    /// Typed counterpart to `error` for branchable error handling.
    private(set) var lastError: OnboardingError?

    private func setError(_ error: OnboardingError) {
        lastError = error
        self.error = error.localizedDescription
    }

    private func clearError() {
        lastError = nil
        error = nil
    }

    var isLoading: Bool = false

    var joinProgressStatus: String?

    var joinProgressFraction: Double?

    var pendingShareMetadata: InvitationLinkResolution?

    /// Prevents double-push when the same invite arrives via URL + acceptance paths.
    var hasAutoRoutedForInvite: Bool = false

    /// Role decoded from the share title for role-aware copy. Nil until an invite resolves — unknown is never shown as Hero.
    var invitedRole: UserRole?

    /// Display name for the decoded invite role, used by FamilyJoin/RoleSelection copy.
    var invitedRoleDisplayName: String {
        invitedRole?.inviteDisplayName ?? "Family Member"
    }

    /// Populated when hero discovery identifies an existing active profile in shared zones.
    var detectedHero: DetectedHero?

    private let familyService: FamilyService

    private let appState: AppState

    private let syncCoordinator: CKSyncEngineCoordinator

    /// Retained enable path for notification priming so prime writes ride the service instead of UserDefaults.
    private let notificationService: NotificationService?

    /// Double-join guard. URL + accept-share arrivals spawn concurrent tasks that would double-accept without serialization.
    /// WHY plain flag: the view model is MainActor-isolated, so synchronous claim/release never suspends and needs no lock.
    @ObservationIgnored
    private var joinInProgress = false

    private func claimJoin() -> Bool {
        guard !joinInProgress else { return false }
        joinInProgress = true
        return true
    }

    private func releaseJoin() {
        joinInProgress = false
    }

    private(set) var builtFamily: Family?

    private(set) var builtProfile: Profile?

    /// Indicates whether `joinFamilyViaAcceptedShare` reused an existing active profile without modification.
    private(set) var didReuseActiveProfile = false

    init(familyService: FamilyService, appState: AppState, syncCoordinator: CKSyncEngineCoordinator, notificationService: NotificationService? = nil) {
        self.familyService = familyService
        self.appState = appState
        self.syncCoordinator = syncCoordinator
        self.notificationService = notificationService
    }

    func advanceFromIntentSelection() {
        switch userIntent {
        case .createFamily:
            push(.familyCreation)
        case .joinFamily:
            // WHY atomic claim before navigation: concurrent invite tasks racing here must not double-push or double-accept.
            guard claimJoin() else { return }
            checkForExistingHero()
            push(.familyJoin)
            Task { [weak self] in
                await self?.runAdvanceJoin()
            }
        case nil:
            break
        }
    }

    /// Serialized join for the intent path. Releases the claim from `advanceFromIntentSelection`; failure leaves routing clear for retry.
    private func runAdvanceJoin() async {
        defer { releaseJoin() }
        guard userIntent == .joinFamily, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        _ = await performJoinFamilyViaAcceptedShare()
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

    /// Auto-routes a pending invite to the join flow when still on Welcome.
    /// Debounced via `hasAutoRoutedForInvite` and guarded against `isLoading` re-entry.
    /// WHY explicit routing: property observers must not trigger network navigation; caller must invoke this.
    func handlePendingInviteIfNeeded() {
        guard !hasAutoRoutedForInvite, !isLoading, let resolution = pendingShareMetadata else { return }
        // WHY atomic claim before navigation: URL + accept-share double arrival must not double-route or double-accept.
        guard claimJoin() else { return }
        // Decode role for display — FamilyService decodes server-side as well, UI is copy only.
        invitedRole = UserRole.fromShareTitle(resolution.title ?? "")
        // Do not override an active creation flow.
        if path.contains(.familyCreation) {
            releaseJoin()
            return
        }
        // Only auto-route from Welcome (empty) or from RoleSelection without creation.
        guard path.isEmpty || path == [.roleSelection] else {
            releaseJoin()
            return
        }
        // WHY atomic claim before yield: isLoading set before suspension prevents concurrent second trigger (didSet+LootListApp double-route) from passing guard.
        hasAutoRoutedForInvite = true
        isLoading = true
        userIntent = .joinFamily
        if path.isEmpty {
            path = [.roleSelection, .familyJoin]
        } else {
            path.append(.familyJoin)
        }
        checkForExistingHero()
        // Schedule join on next runloop so navigation settles before the async join mutates state.
        Task { [weak self] in
            await Task.yield()
            await self?.joinFamilyViaAcceptedShareClaimed()
        }
    }

    private func joinFamilyViaAcceptedShareClaimed() async {
        defer {
            isLoading = false
            releaseJoin()
        }
        // Single serialized entry with the intent path; failure clears auto-route so retry can re-route.
        let success = await performJoinFamilyViaAcceptedShare()
        if !success {
            hasAutoRoutedForInvite = false
        }
    }

    /// Single serialized join entry for intent, auto-route, and view-retry paths. Callers hold the join claim.
    private func performJoinFamilyViaAcceptedShare() async -> Bool {
        guard userIntent == .joinFamily, let resolution = pendingShareMetadata else { return false }
        joinProgressStatus = "Accepting family invitation..."
        joinProgressFraction = 0.25
        defer {
            joinProgressStatus = nil
            joinProgressFraction = nil
        }
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
            builtFamily = result.family
            builtProfile = result.profile
            didReuseActiveProfile = result.didReuseActiveProfile
            pendingShareMetadata = nil
            push(.avatarSelection)
            return true
        } catch {
            logger.error("Joining family via accepted share failed: \(error, privacy: .private)")
            if friendlyInviteAcceptError(error) != nil {
                setError(.inviteInvalid)
            } else {
                setError(.joinFailed)
            }
            return false
        }
    }

    func createFamily(name: String) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            setError(.missingGuildName)
            return
        }
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            setError(.missingFounderName)
            return
        }

        clearError()

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
            if shouldShowNotificationPrime() {
                push(.notificationPrime)
            } else {
                push(.done)
            }
        } catch let familyError as FamilyServiceError {
            logger.error("Failed to create family: \(familyError.localizedDescription, privacy: .private)")
            setError(.familyCreateFailed)
        } catch {
            logger.error("Failed to create family: \(error, privacy: .private)")
            setError(.familyCreateFailed)
        }
    }

    /// Consumes pending share metadata to join family, resolving role from share title.
    /// Serialized with the auto-route path via the join claim; concurrent arrivals skip while the winner owns UI.
    func joinFamilyViaAcceptedShare() async {
        let intent = String(describing: self.userIntent)
        let hasMetadata = self.pendingShareMetadata != nil
        logger.info(
            "Joining family via accepted share called. userIntent=\(intent), hasMetadata=\(hasMetadata), isLoading=\(self.isLoading)"
        )
        guard userIntent == .joinFamily,
              pendingShareMetadata != nil,
              !isLoading
        else {
            logger.info(
                "Joining family via accepted share guard check failed. (userIntent=\(intent), hasMetadata=\(hasMetadata), isLoading=\(self.isLoading))"
            )
            return
        }
        // WHY atomic claim: FamilyJoinView onChange races auto-route double arrival; loser skips while winner owns UI.
        guard claimJoin() else {
            logger.info("Join already in progress. Skipping duplicate join request.")
            return
        }
        isLoading = true
        defer {
            isLoading = false
            releaseJoin()
        }

        logger.info("Calling familyService.joinFamilyViaAcceptedShare...")
        // WHY single entry: progress stays weak and error copy stays in one place so retry behaves identically.
        let success = await performJoinFamilyViaAcceptedShare()
        if success, let family = builtFamily, let profile = builtProfile {
            logger.info("Joined family '\(family.name, privacy: .private)' as profile '\(profile.displayName, privacy: .private)'")
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
                if friendlyInviteAcceptError(error) != nil {
                    setError(.inviteInvalid)
                } else {
                    setError(.linkReadFailed)
                }
            }
        }
    #endif

    /// Completes joiner setup, updating profile name/avatar unless reusing an active profile.
    func completeJoinedProfile() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        guard let profile = builtProfile else {
            setError(.missingInvite)
            return
        }

        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            setError(.missingJoinerName)
            return
        }

        clearError()
        appState.currentProfile = profile

        guard !didReuseActiveProfile else {
            builtProfile = profile
            if shouldShowNotificationPrime() {
                push(.notificationPrime)
            } else {
                push(.done)
            }
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
            if shouldShowNotificationPrime() {
                push(.notificationPrime)
            } else {
                push(.done)
            }
        } catch let familyError as FamilyServiceError {
            logger.error("Failed to finalize joined profile: \(familyError.localizedDescription, privacy: .private)")
            setError(.profileSetupFailed)
        } catch {
            logger.error("Failed to finalize joined profile: \(error, privacy: .private)")
            setError(.joinFailed)
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
        clearError()
        isLoading = false
        path = []
        builtFamily = nil
        builtProfile = nil
        didReuseActiveProfile = false
        pendingShareMetadata = nil
        detectedHero = nil
        hasAutoRoutedForInvite = false
        invitedRole = nil
    }

    // MARK: - Notification Prime Navigation

    /// WHY scoped clear: family switches drop the prime so the new household re-primes once.
    func clearPrimeForFamilySwitch() {
        clearNotificationPrimeSeen()
    }

    /// WHY teardown: identity teardown clears scoped and legacy primes so no family leaks the gate.
    func clearNotificationPrimeSeen() {
        DismissalStore.remove(scopedPrimeKey())
        DismissalStore.remove(DismissalKeys.hasSeenNotificationPrime)
    }

    private func scopedPrimeKey() -> String {
        DismissalKeys.scoped(
            DismissalKeys.hasSeenNotificationPrime,
            familyRecordName: builtFamily?.id.recordName ?? appState.family?.id.recordName,
            profileRecordName: builtProfile?.id.recordName ?? appState.currentProfile?.id.recordName
        )
    }

    private func markNotificationPrimeSeenAndAdvance() {
        let scoped = scopedPrimeKey()
        // WHY scoped-only: the base key is legacy migration-read only; writing it would leak the prime across families.
        DismissalStore.set(true, forKey: scoped)
        push(.done)
    }

    private func shouldShowNotificationPrime() -> Bool {
        // WHY explicit migrate: the pure read never writes, so promotion runs here in ViewModel logic instead of a view body.
        DismissalKeys.migrate(
            DismissalKeys.hasSeenNotificationPrime,
            familyRecordName: builtFamily?.id.recordName ?? appState.family?.id.recordName,
            profileRecordName: builtProfile?.id.recordName ?? appState.currentProfile?.id.recordName
        )
        return !DismissalKeys.effectiveBool(
            DismissalKeys.hasSeenNotificationPrime,
            familyRecordName: builtFamily?.id.recordName ?? appState.family?.id.recordName,
            profileRecordName: builtProfile?.id.recordName ?? appState.currentProfile?.id.recordName
        )
    }

    func skipNotificationPrime() {
        markNotificationPrimeSeenAndAdvance()
    }

    func completeNotificationPrime() {
        markNotificationPrimeSeenAndAdvance()
    }

    /// Single enable path for the onboarding prime so Views ride the viewModel instead of touching the service directly.
    /// WHY single home: requestAuthorization + register + setMasterEnabled must not drift between prime surfaces.
    func enableNotificationsAfterPrime() async throws -> Bool {
        try await notificationService?.enableNotificationsAfterPrime() ?? false
    }
}

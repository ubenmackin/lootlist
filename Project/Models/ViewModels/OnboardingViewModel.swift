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

@MainActor
@Observable
final class OnboardingViewModel {
    var selectedRole: UserRole?

    var displayName: String = ""

    var avatarClass: AvatarClass?

    var avatarPresetID: String?

    var customAvatarImageData: Data?

    var shareURLString: String = ""

    var familyName: String = ""

    var path: [OnboardingStep] = []

    var currentStep: OnboardingStep {
        path.last ?? .welcome
    }

    var error: String?

    var isLoading: Bool = false

    var shareURL: URL?
    var pendingShareMetadata: CKShare.Metadata?

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
        case false: push(.familyJoin)
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

        isLoading = true
        error = nil

        // Resolve the iCloud user ID up front. Surfacing a failure here (vs.
        // synthesizing a random UUID) prevents duplicate `Profile` records on
        // re-runs over a flaky network. The finalize button serves as the
        // retry affordance — see `iCloudUserID()` docs.
        let owneriCloudID: CKRecord.ID
        do {
            owneriCloudID = try await iCloudUserID()
        } catch {
            isLoading = false
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
        } catch let FamilyServiceError.creationFailed(message) {
            error = message
        } catch {
            self.error = "Could not found your guild: \(error)"
        }

        isLoading = false
    }

    func joinFamilyViaShareLink() async {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            error = "Pick a name before joining your party."
            return
        }

        isLoading = true
        error = nil

        // 1. If user pasted a share URL string into the join field, resolve its metadata first
        if pendingShareMetadata == nil {
            let rawURL = shareURLString.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: rawURL) {
                do {
                    let container = CloudKitService.defaultContainer
                    let metadata = try await container.shareMetadata(for: url)
                    pendingShareMetadata = metadata
                } catch {
                    isLoading = false
                    self.error = "Could not open share invitation: \(error.localizedDescription)"
                    return
                }
            }
        }

        guard let metadata = pendingShareMetadata else {
            isLoading = false
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
            isLoading = false
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
        } catch let FamilyServiceError.joinFailed(message) {
            error = message
        } catch {
            self.error = "Could not join the guild: \(error)"
        }

        isLoading = false
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
    }

    private func iCloudUserID() async throws -> CKRecord.ID {
        try await CloudKitService.defaultContainer.userRecordID()
    }
}

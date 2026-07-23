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

    var shareURLString: String = ""

    var familyName: String = ""

    var path: [OnboardingStep] = []

    var currentStep: OnboardingStep {
        path.last ?? .welcome
    }

    var error: String?

    var isLoading: Bool = false

    /// The share URL generated after family creation (Guild Master only).
    /// Presented to the parent so they can invite Heroes.
    var shareURL: URL?

    /// Pending CKShare metadata from an incoming share link.
    /// Set when the app opens via a CKShare URL before onboarding is complete.
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
        guard let avatarClass else {
            error = "Choose a character class first."
            return
        }
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            error = "Pick a hero name before founding your guild."
            return
        }

        isLoading = true
        error = nil

        let presetID = avatarPresetID ?? "\(avatarClass.presetPrefix)_01"
        let ownerProfile = await Profile(
            displayName: trimmedName,
            avatarClass: avatarClass,
            avatarPresetID: presetID,
            role: .guildMaster,
            iCloudUserID: iCloudUserID(),
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

    /// Joins a family via a CKShare link (opened from iMessage/AirDrop or pasted into the app).
    func joinFamilyViaShareLink() async {
        guard let avatarClass else {
            error = "Choose a character class first."
            return
        }
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            error = "Pick a hero name before joining your party."
            return
        }

        isLoading = true
        error = nil

        // 1. If user pasted a share URL string into the join field, resolve its metadata first
        if pendingShareMetadata == nil {
            let rawURL = shareURLString.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: rawURL) {
                do {
                    let container = CKContainer.default()
                    let metadata = try await container.shareMetadata(for: url)
                    self.pendingShareMetadata = metadata
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

        let presetID = avatarPresetID ?? "\(avatarClass.presetPrefix)_01"
        let heroProfile = await Profile(
            displayName: trimmedName,
            avatarClass: avatarClass,
            avatarPresetID: presetID,
            role: .hero,
            iCloudUserID: iCloudUserID(),
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

    /// Whether the user has a pending CKShare invitation to join.
    var hasShareInvitation: Bool {
        pendingShareMetadata != nil
    }

    func completeOnboarding(family: Family?, profile: Profile?) {
        guard let family, let profile else { return }
        appState.family = family
        appState.currentProfile = profile
        appState.authStatus = .authenticated
        // Defense in depth: clear transient onboarding state so a future
        // re-onboard (sign-out → sign-in) starts completely clean.
        reset()
    }

    func reset() {
        selectedRole = nil
        displayName = ""
        avatarClass = nil
        avatarPresetID = nil
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

    private func iCloudUserID() async -> CKRecord.ID {
        do {
            return try await CKContainer.default().userRecordID()
        } catch {
            // Fallback to a generated ID if we can't get the real one.
            return CKRecord.ID(recordName: UUID().uuidString)
        }
    }
}

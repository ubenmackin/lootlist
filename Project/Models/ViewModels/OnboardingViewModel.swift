import Foundation
import CloudKit

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

    var familyCode: String = ""

    var familyName: String = ""

    var path: [OnboardingStep] = []

    var currentStep: OnboardingStep { path.last ?? .welcome }

    var error: String?

    var isLoading: Bool = false

    private let familyService: FamilyService

    private let appState: AppState

    init(familyService: FamilyService, appState: AppState) {
        self.familyService = familyService
        self.appState = appState
    }

    func advanceFromRoleSelection() {
        guard let role = selectedRole else { return }
        switch role.isParent {
        case true:  push(.familyCreation)
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
        guard let avatarClass = avatarClass else {
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
        let ownerProfile = Profile(
            displayName: trimmedName,
            avatarClass: avatarClass,
            avatarPresetID: presetID,
            role: .guildMaster,
            iCloudUserID: iCloudUserID(),
            family: CKRecord.Reference(recordID: CKRecord.ID(recordName: "pending"),
                                 action: .none)
        )

        do {
            try await familyService.createFamily(
                name: trimmed,
                ownerProfile: ownerProfile)

            familyName = trimmed
            push(.done)
        } catch let FamilyServiceError.creationFailed(message) {
            error = message
        } catch {
            self.error = "Could not found your guild: \(error)"
        }

        isLoading = false
    }

    func joinFamilyWithCode() async {
        let code = familyCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            error = "Enter your invite code to join the quest."
            return
        }
        guard let avatarClass = avatarClass else {
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

        let presetID = avatarPresetID ?? "\(avatarClass.presetPrefix)_01"
        let heroProfile = Profile(
            displayName: trimmedName,
            avatarClass: avatarClass,
            avatarPresetID: presetID,
            role: .hero,
            iCloudUserID: iCloudUserID(),
            family: CKRecord.Reference(recordID: CKRecord.ID(recordName: "pending"),
                                 action: .none)
        )

        do {
            try await familyService.joinFamily(
                code: code,
                heroProfile: heroProfile)
            push(.done)
        } catch FamilyServiceError.invalidInviteCode {
            error = "We couldn't find that invite code. Ask your Guild Master."
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

    func reset() {
        selectedRole = nil
        displayName = ""
        avatarClass = nil
        avatarPresetID = nil
        familyCode = ""
        familyName = ""
        error = nil
        isLoading = false
        path = []
    }

    private func iCloudUserID() -> CKRecord.ID {
        CKRecord.ID(recordName: UUID().uuidString)
    }
}

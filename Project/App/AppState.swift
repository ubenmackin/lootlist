import Foundation

@MainActor
@Observable
final class AppState {

    enum AuthStatus: Equatable {
        case onboarding
        case authenticated
    }

    var authStatus: AuthStatus = .onboarding

    var currentProfile: Profile? = nil

    var family: Family? = nil

    func signOut() {
        authStatus = .onboarding
        currentProfile = nil
        family = nil
    }
}

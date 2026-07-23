import SwiftUI

struct WelcomeView: View {
    @Bindable var viewModel: OnboardingViewModel

    var body: some View {
        NavigationStack(path: $viewModel.path) {
            welcomeScreen
                .navigationDestination(for: OnboardingStep.self) { step in
                    destination(for: step)
                }
        }
    }

    private var welcomeScreen: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "shield.lefthalf.filled")
                .resizable()
                .scaledToFit()
                .frame(width: 120, height: 120)
                .foregroundStyle(
                    LinearGradient(
                        colors: [.yellow, .orange],
                        startPoint: .top, endPoint: .bottom
                    )
                )

            VStack(spacing: 12) {
                Text("Welcome,")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Adventurer!")
                    .font(.system(size: 44, weight: .heavy,
                                  design: .rounded))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.yellow, .orange],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
            }

            Text("Your quest for gold and glory begins here. "
                + "Found a guild or join one to start earning loot.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)

            Spacer()

            Button {
                viewModel.selectedRole = nil
                viewModel.goToRoleSelection()
            } label: {
                Label("Begin Your Quest", systemImage: "sparkles")
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)
            .tint(.yellow)
            .padding(.horizontal, 32)
            .accessibilityIdentifier("welcome.startButton")

            Spacer().frame(height: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [Color(.systemBackground), Color.purple.opacity(0.15)],
                startPoint: .top, endPoint: .bottom
            )
        )
    }

    @ViewBuilder
    private func destination(for step: OnboardingStep) -> some View {
        switch step {
        case .welcome:
            welcomeScreen
                .navigationBarBackButtonHidden(true)
        case .roleSelection:
            RoleSelectionView(viewModel: viewModel)
        case .familyCreation:
            FamilyCreationView(viewModel: viewModel)
        case .familyJoin:
            FamilyJoinView(viewModel: viewModel)
        case .avatarSelection:
            AvatarSelectionView(viewModel: viewModel)
        case .done:
            OnboardingCompletionView(viewModel: viewModel)
        }
    }
}

struct OnboardingCompletionView: View {
    @Bindable var viewModel: OnboardingViewModel

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 80))
                .foregroundStyle(.green)

            Text("Ready to quest!")
                .font(.system(size: 36, weight: .heavy, design: .rounded))

            if !viewModel.familyName.isEmpty {
                Text("Your guild \u{201C}\(viewModel.familyName)\u{201D} awaits.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            } else {
                Text("Your party is ready — adventure calls!")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                viewModel.completeOnboarding(
                    family: viewModel.builtFamily,
                    profile: viewModel.builtProfile
                )
            } label: {
                Text("Continue")
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .padding(.horizontal, 32)
            // Both builtFamily and builtProfile must be non-nil to proceed,
            // matching the `guard let family, let profile` in completeOnboarding.
            .disabled(viewModel.builtFamily == nil || viewModel.builtProfile == nil)
            .accessibilityIdentifier("onboarding.continueButton")

            Spacer().frame(height: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [Color(.systemBackground), Color.green.opacity(0.12)],
                startPoint: .top, endPoint: .bottom
            )
        )
        .accessibilityIdentifier("onboarding.done")
    }
}

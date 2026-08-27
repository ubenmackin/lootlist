//
//  WelcomeView.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

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
                        colors: [Color.gold, Color(DesignSystemConstants.Colors.pendingAmber)],
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
                            colors: [Color.gold, Color(DesignSystemConstants.Colors.pendingAmber)],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
            }

            Text("Chores, allowance, and savings in one place. "
                + "Found a guild or join one to get started.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)

            Spacer()

            Button {
                viewModel.userIntent = nil
                viewModel.goToRoleSelection()
            } label: {
                Label("Begin Your Quest", systemImage: "sparkles")
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(DesignSystemConstants.Colors.accentBlue))
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
            .accessibilityIdentifier("welcome.startButton")
        }
        .background(
            LinearGradient(
                colors: [Color(.systemBackground), Color(DesignSystemConstants.Colors.accentBlue).opacity(0.15)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
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
                .foregroundStyle(Color(DesignSystemConstants.Colors.primaryGreen))

            Text("Ready to quest!")
                .font(.system(size: 36, weight: .heavy, design: .rounded))

            if !viewModel.familyName.isEmpty {
                Text("Your guild \u{201C}\(viewModel.familyName)\u{201D} awaits.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            } else {
                Text("You're all set — let's get started!")
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
            .tint(Color(DesignSystemConstants.Colors.primaryGreen))
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
            // Both builtFamily and builtProfile must be non-nil to proceed,
            // matching the `guard let family, let profile` in completeOnboarding.
            .disabled(viewModel.builtFamily == nil || viewModel.builtProfile == nil)
            .accessibilityIdentifier("onboarding.continueButton")
        }
        .background(
            LinearGradient(
                colors: [Color(.systemBackground), Color(DesignSystemConstants.Colors.primaryGreen).opacity(0.12)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
        )
        .accessibilityIdentifier("onboarding.done")
    }
}

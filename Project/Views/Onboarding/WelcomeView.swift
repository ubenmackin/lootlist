//
//  WelcomeView.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import SwiftUI

// MARK: - OnboardingStep helpers

extension OnboardingStep: CaseIterable {
    static var allCases: [OnboardingStep] {
        [.welcome, .roleSelection, .familyCreation, .familyJoin, .avatarSelection, .done]
    }

    /// Label used in the vertical step indicator.
    var indicatorTitle: String {
        switch self {
        case .welcome: "Welcome"
        case .roleSelection: "Role"
        case .familyCreation: "Guild"
        case .familyJoin: "Join"
        case .avatarSelection: "Avatar"
        case .done: "Done"
        }
    }

    /// System image that represents the step in the marketing illustration.
    var marketingIcon: String {
        switch self {
        case .welcome: "shield.lefthalf.filled"
        case .roleSelection: "person.3.fill"
        case .familyCreation: "crown.fill"
        case .familyJoin: "envelope.badge.fill"
        case .avatarSelection: "person.crop.circle.badge.plus"
        case .done: "checkmark.seal.fill"
        }
    }

    var marketingDescription: String {
        switch self {
        case .welcome:
            "Chores, allowance, and savings in one place. Found a guild or join one to get started."
        case .roleSelection:
            "Choose your path — create a family guild or join one."
        case .familyCreation:
            "Name your guild and forge a shared space for the whole family."
        case .familyJoin:
            "Waiting for your invitation — tap the share link to join."
        case .avatarSelection:
            "Pick a name and emoji to make your hero yours."
        case .done:
            "Your guild awaits — ready to quest!"
        }
    }
}

struct WelcomeView: View {
    @Bindable var viewModel: OnboardingViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        NavigationStack(path: $viewModel.path) {
            Group {
                if horizontalSizeClass == .regular {
                    regularRoot
                } else {
                    compactRoot
                }
            }
            .navigationDestination(for: OnboardingStep.self) { step in
                destination(for: step)
            }
        }
    }

    // MARK: - Adaptive roots

    /// Regular width uses the iPad split layout; ViewThatFits provides the
    /// 50/50 collapse to a top banner when the split is too narrow.
    private var regularRoot: some View {
        GeometryReader { proxy in
            let totalWidth = proxy.size.width
            ViewThatFits(in: .horizontal) {
                // Full split: left 45% marketing, right 55% wizard.
                HStack(spacing: 0) {
                    marketingPane
                        .frame(width: totalWidth * 0.45)
                        .frame(maxHeight: .infinity)

                    rightWizard
                        .frame(width: totalWidth * 0.55)
                        .frame(maxHeight: .infinity)
                }
                // Narrow regular (e.g. 50/50 ~417pt still reported regular on some
                // multitasking sizes) collapses the left pane to a top banner.
                VStack(spacing: 0) {
                    collapsedBanner
                    rightWizard
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .ignoresSafeArea()
    }

    private var compactRoot: some View {
        welcomeCoreContent
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 16)
            .background(
                LinearGradient(
                    colors: [Color(DesignSystemConstants.Colors.background), Color(DesignSystemConstants.Colors.accentBlue).opacity(0.15)],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()
            )
    }

    // MARK: - Right wizard (regular)

    private var rightWizard: some View {
        ZStack {
            Color(DesignSystemConstants.Colors.background)
                .ignoresSafeArea()
            HStack(alignment: .center, spacing: 12) {
                OnboardingStepIndicator(currentStep: viewModel.currentStep)
                    .frame(width: 84)
                    .padding(.leading, 8)

                welcomeCard
                    .frame(maxWidth: 520)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(20)
        }
    }

    private var welcomeCard: some View {
        VStack(spacing: 0) {
            welcomeCoreContent
                .padding(24)
        }
        .frame(maxWidth: 500)
        .background(Color(DesignSystemConstants.Colors.cardSurface))
        .clipShape(RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.modal, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.modal, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 16, x: 0, y: 8)
    }

    // MARK: - Shared welcome content

    /// Core welcome copy and CTA — reused for both compact and regular card.
    /// Button tints and accessibilityIdentifiers stay identical across idioms.
    private var welcomeCoreContent: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "shield.lefthalf.filled")
                .resizable()
                .scaledToFit()
                .frame(width: 120, height: 120)
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color(DesignSystemConstants.Colors.gold), Color(DesignSystemConstants.Colors.pendingAmber)],
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
                            colors: [Color(DesignSystemConstants.Colors.gold), Color(DesignSystemConstants.Colors.pendingAmber)],
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
    }

    // MARK: - Marketing panes

    private var marketingPane: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "shield.lefthalf.filled")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color(DesignSystemConstants.Colors.gold), Color(DesignSystemConstants.Colors.pendingAmber)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .shadow(color: Color(DesignSystemConstants.Colors.gold).opacity(0.35), radius: 12, x: 0, y: 6)

            VStack(spacing: 8) {
                Text("Welcome,")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Adventurer!")
                    .font(.system(size: 36, weight: .heavy, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color(DesignSystemConstants.Colors.gold), Color(DesignSystemConstants.Colors.pendingAmber)],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                Text(viewModel.currentStep.marketingDescription)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
            }

            Spacer()

            // Cross-fading illustration per step — uses the reference screenshot
            // palette via system images rather than the newer asset look.
            ZStack {
                Image(systemName: viewModel.currentStep.marketingIcon)
                    .font(.system(size: 64, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color(DesignSystemConstants.Colors.accentBlue), Color(DesignSystemConstants.Colors.gold).opacity(0.85)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .id(viewModel.currentStep)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
            .frame(height: 80)
            .animation(.easeInOut(duration: 0.32), value: viewModel.currentStep)

            Spacer()

            Text("LootList")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 16)
        .background(
            LinearGradient(
                colors: [Color(DesignSystemConstants.Colors.background), Color(DesignSystemConstants.Colors.accentBlue).opacity(0.12)],
                startPoint: .top, endPoint: .bottom
            )
        )
        .overlay(
            Rectangle()
                .fill(Color.secondary.opacity(0.08))
                .frame(width: 1)
                .frame(maxWidth: .infinity, alignment: .trailing)
        )
    }

    private var collapsedBanner: some View {
        HStack(spacing: 16) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 32))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color(DesignSystemConstants.Colors.gold), Color(DesignSystemConstants.Colors.pendingAmber)],
                        startPoint: .top, endPoint: .bottom
                    )
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("Welcome, Adventurer!")
                    .font(.headline.weight(.bold))
                    .lineLimit(1)
                Text(viewModel.currentStep.marketingDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Image(systemName: viewModel.currentStep.marketingIcon)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
                .id("banner-\(viewModel.currentStep)")
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.28), value: viewModel.currentStep)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .overlay(
            Rectangle()
                .fill(Color.secondary.opacity(0.12))
                .frame(height: 1)
                .frame(maxHeight: .infinity, alignment: .bottom)
        )
    }

    @ViewBuilder
    private func destination(for step: OnboardingStep) -> some View {
        switch step {
        case .welcome:
            // When deep-linked back to welcome inside the NavigationStack,
            // reuse the compact core so the push does not duplicate the split.
            welcomeCoreContent
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    LinearGradient(
                        colors: [Color(DesignSystemConstants.Colors.background), Color(DesignSystemConstants.Colors.accentBlue).opacity(0.15)],
                        startPoint: .top, endPoint: .bottom
                    )
                    .ignoresSafeArea()
                )
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

// MARK: - Step Indicator

private struct OnboardingStepIndicator: View {
    let currentStep: OnboardingStep

    private var currentIndex: Int {
        OnboardingStep.allCases.firstIndex(of: currentStep) ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(OnboardingStep.allCases.enumerated()), id: \.offset) { index, step in
                let isCompleted = index < currentIndex
                let isCurrent = index == currentIndex

                HStack(alignment: .center, spacing: 10) {
                    Capsule()
                        .fill(capsuleColor(isCompleted: isCompleted, isCurrent: isCurrent))
                        .frame(width: 4, height: isCurrent ? 28 : 18)
                        .animation(.easeInOut(duration: 0.28), value: currentStep)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(step.indicatorTitle)
                            .font(.caption.weight(isCurrent ? .bold : .semibold))
                            .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                            .lineLimit(1)
                        if isCurrent {
                            Text("Step \(index + 1) of \(OnboardingStep.allCases.count)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .opacity(isCurrent || isCompleted ? 1 : 0.72)

                if index < OnboardingStep.allCases.count - 1 {
                    Rectangle()
                        .fill(Color.secondary.opacity(isCompleted ? 0.28 : 0.12))
                        .frame(width: 1, height: 14)
                        .padding(.leading, 1.5)
                        .padding(.vertical, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(DesignSystemConstants.Colors.cardSurface).opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.08), lineWidth: 1)
        )
    }

    private func capsuleColor(isCompleted: Bool, isCurrent: Bool) -> Color {
        if isCurrent {
            return Color(DesignSystemConstants.Colors.accentBlue)
        }
        if isCompleted {
            return Color(DesignSystemConstants.Colors.primaryGreen)
        }
        return Color.secondary.opacity(0.22)
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
                colors: [Color(DesignSystemConstants.Colors.background), Color(DesignSystemConstants.Colors.primaryGreen).opacity(0.12)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
        )
        .accessibilityIdentifier("onboarding.done")
    }
}

//
//  RoleSelectionView.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import SwiftUI

struct RoleSelectionView: View {
    @Bindable var viewModel: OnboardingViewModel
    @State private var pulseJoinCard = false

    private var isAutoRouted: Bool {
        viewModel.hasAutoRoutedForInvite
    }

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text("Choose Your Path")
                    .font(.system(size: 32, weight: .heavy,
                                  design: .rounded))
                Text("Start your own family, or join an existing one.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if isAutoRouted {
                    Text("Invitation for \(viewModel.invitedRoleDisplayName) detected — joining your Guild…")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.top, 32)

            Spacer()

            VStack(spacing: 20) {
                intentCard(
                    intent: .createFamily,
                    title: "Create a Family",
                    subtitle: "Become the Guild Master and invite your family.",
                    icon: "crown.fill",
                    gradient: [Color(DesignSystemConstants.Colors.pendingAmber), Color.gold]
                )

                intentCard(
                    intent: .joinFamily,
                    title: "Join a Family",
                    subtitle: "Tap to wait for your parent's invitation.",
                    icon: "figure.and.child.holdinghands",
                    gradient: [Color(DesignSystemConstants.Colors.accentBlue), Color(DesignSystemConstants.Colors.accentBlue).opacity(0.75)]
                )
            }
            .padding(.horizontal, 24)

            Spacer()
        }
        .background(
            LinearGradient(
                colors: [Color(DesignSystemConstants.Colors.background), Color(DesignSystemConstants.Colors.accentBlue).opacity(0.1)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
        )
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    viewModel.backToWelcome()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
            }
        }
        // WHY task-driven reset: the cancellable .task(id:) owns the sleep so no stored Task crosses MainActor state.
        .task(id: viewModel.hasAutoRoutedForInvite) {
            guard viewModel.hasAutoRoutedForInvite else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatCount(2, autoreverses: true)) {
                pulseJoinCard = true
            }
            // WHY defer reset: cancellation or identity reset must not leave the join card stuck highlighted.
            defer {
                withAnimation(.easeOut(duration: 0.3)) {
                    pulseJoinCard = false
                }
            }
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
        }
    }

    private func intentCard(intent: UserIntent,
                            title: String,
                            subtitle: String,
                            icon: String,
                            gradient: [Color]) -> some View
    {
        let isHighlighted = intent == .joinFamily && isAutoRouted
        return Button {
            viewModel.userIntent = intent
            viewModel.advanceFromIntentSelection()
        } label: {
            HStack(spacing: 20) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: icon)
                        .font(.system(size: 36, weight: .semibold))
                        .frame(width: 72, height: 72)
                        .foregroundStyle(.white)
                        .background(
                            LinearGradient(
                                colors: gradient,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                    if isHighlighted {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
                            .background(Circle().fill(.white))
                            .offset(x: 6, y: -6)
                            .transition(.scale.combined(with: .opacity))
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .padding(20)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(isHighlighted ? Color(DesignSystemConstants.Colors.accentBlue) : Color.white.opacity(0.15), lineWidth: isHighlighted ? 2 : 1)
            )
            .scaleEffect(isHighlighted && pulseJoinCard ? 1.02 : 1.0)
            .shadow(color: isHighlighted && pulseJoinCard ? Color(DesignSystemConstants.Colors.accentBlue).opacity(0.25) : .clear, radius: 8, x: 0, y: 4)
            .animation(.easeInOut(duration: 0.9), value: pulseJoinCard)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("role.\(intent.rawValue)")
    }
}

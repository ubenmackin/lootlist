//
//  FamilyJoinView.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import SwiftUI

struct FamilyJoinView: View {
    @Bindable var viewModel: OnboardingViewModel

    @Environment(AppState.self) private var appState
    @Environment(CloudKitService.self) private var cloudKitService

    var body: some View {
        Group {
            if viewModel.detectedHero != nil {
                heroWelcomeBody
            } else {
                joinBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [Color(.systemBackground), Color.blue.opacity(0.15)],
                startPoint: .top, endPoint: .bottom
            )
        )
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    viewModel.backToRoleSelection()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
            }
        }
    }

    private var joinBody: some View {
        VStack(spacing: 24) {
            header

            Spacer()

            if viewModel.hasShareInvitation {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)

                    Text("Invitation Link Received!")
                        .font(.headline.weight(.bold))

                    Text("You're ready to join your family's guild party.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 24)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Invitation Link", systemImage: "link.badge.plus")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.primary)

                    TextField("https://www.icloud.com/share/...", text: $viewModel.shareURLString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.subheadline)
                        .padding(16)
                        .background(.thinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                        )
                        .accessibilityIdentifier("joinFamily.linkField")

                    Text("Tap the invitation link sent by your Guild Master, or paste the link here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24)
            }

            Spacer()

            Button {
                viewModel.advanceToAvatarSelection()
            } label: {
                Label("Next: Choose Your Hero", systemImage: "sparkles")
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .disabled(!viewModel.hasShareInvitation && viewModel.shareURLString.trimmingCharacters(in: .whitespaces).isEmpty)
            .padding(.horizontal, 24)

            Spacer().frame(height: 32)
        }
    }

    // MARK: - Detected Hero ("Welcome back") surface

    /// Defense-in-depth reconnect surface. When `viewModel.detectedHero`
    /// transitions to non-nil, this swaps the join body for a
    /// DetectedFamilyView-style card so a returning hero can reconnect to their
    /// existing guild instead of minting a duplicate profile.
    private var heroWelcomeBody: some View {
        VStack(spacing: 28) {
            Spacer()

            VStack(spacing: 12) {
                Image(systemName: "return")
                    .font(.system(size: 64))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .top, endPoint: .bottom
                        )
                    )

                Text("Welcome back, \(viewModel.detectedHero?.profile.displayName ?? "Hero")!")
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .multilineTextAlignment(.center)

                Text("We found an active hero bound to your iCloud account. Reconnect to pick up your quests where you left off.")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
            }

            if let hero = viewModel.detectedHero {
                heroCard(hero)
            }

            Spacer()

            heroActionButtons

            Spacer().frame(height: 24)
        }
        .padding(.horizontal, 24)
    }

    private func heroCard(_ hero: DetectedHero) -> some View {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                Image(systemName: hero.profile.avatarClass?.iconSystemName ?? hero.profile.role.iconSystemName)
                    .font(.system(size: 32))
                    .foregroundStyle(.blue)
                    .frame(width: 56, height: 56)
                    .background(Color.blue.opacity(0.15))
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text(hero.family.name)
                        .font(.title2.weight(.bold))

                    HStack(spacing: 8) {
                        Text(hero.profile.displayName)
                            .font(.subheadline.weight(.semibold))

                        Text("Hero")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.2))
                            .foregroundStyle(.blue)
                            .clipShape(Capsule())
                    }
                }

                Spacer()
            }

            Divider()

            HStack {
                Label("Level \(hero.profile.level)", systemImage: "star.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.yellow)

                Spacer()

                Text("\(hero.profile.xp) Total XP")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(.white.opacity(0.2), lineWidth: 1)
        )
        .accessibilityIdentifier("detectedHero.card")
    }

    private var heroActionButtons: some View {
        VStack(spacing: 12) {
            Button {
                guard let hero = viewModel.detectedHero else { return }
                Task { @MainActor in
                    await appState.acceptDetectedFamily(
                        family: hero.family,
                        profile: hero.profile,
                        zoneID: hero.zoneID,
                        isOwner: false,
                        cloudKit: cloudKitService
                    )
                }
            } label: {
                Label("Reconnect to Guild", systemImage: "arrow.triangle.2.circlepath")
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .accessibilityIdentifier("detectedHero.reconnectButton")

            Button {
                viewModel.detectedHero = nil
            } label: {
                Label("Join a Different Family", systemImage: "arrow.right")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .tint(.blue)
            .accessibilityIdentifier("detectedHero.differentButton")
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "figure.and.child.holdinghands")
                .font(.system(size: 56))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.blue, .purple],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            Text("Join Your Party")
                .font(.system(size: 28, weight: .heavy, design: .rounded))
            Text("Heroes partake in quests to earn money and glory.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
        }
        .padding(.top, 24)
    }
}

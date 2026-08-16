//
//  FamilyJoinView.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import os
import SwiftUI

struct FamilyJoinView: View {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "FamilyJoin")

    @Bindable var viewModel: OnboardingViewModel

    @Environment(AppState.self) private var appState
    @Environment(CloudKitService.self) private var cloudKitService
    @Environment(ToastManager.self) private var toastManager

    #if DEBUG
        @State private var showDebugSharePrompt = false
        @State private var debugShareURLText = ""
    #endif

    var body: some View {
        Group {
            if viewModel.detectedHero != nil {
                heroWelcomeBody
            } else if viewModel.isLoading || viewModel.joinProgressStatus != nil {
                loadingBody
            } else {
                waitingBody
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
                .disabled(viewModel.isLoading || viewModel.joinProgressStatus != nil)
            }
        }
        .onChange(of: viewModel.pendingShareMetadata) { _, metadata in
            logger.info("FamilyJoinView pendingShareMetadata changed: \(metadata != nil ? "has metadata" : "nil")")
            guard metadata != nil else { return }
            Task {
                await viewModel.joinFamilyViaAcceptedShare()
            }
        }
        .onChange(of: viewModel.error) { _, newError in
            if let error = newError {
                logger.error("FamilyJoinView surfaced error: \(error, privacy: .private)")
                toastManager.show(message: error, type: .error)
            }
        }
        #if DEBUG
        .alert("Simulate Invite Link", isPresented: $showDebugSharePrompt) {
                TextField("https://www.icloud.com/share/…", text: $debugShareURLText)
                Button("Accept Link") {
                    Task {
                        await simulateShareLink()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Paste a CloudKit share URL to run the accept flow as if the invite were tapped in Messages.")
            }
        #endif
    }

    /// Loading view surface shown when fetching share metadata or accepting invitation
    private var loadingBody: some View {
        VStack(spacing: 24) {
            Spacer()

            ProgressView()
                .controlSize(.large)
                .tint(.blue)

            VStack(spacing: 12) {
                Text(viewModel.joinProgressStatus ?? "Joining Guild...")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)

                if let fraction = viewModel.joinProgressFraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(.blue)
                        .frame(maxWidth: 240)
                        .animation(.easeInOut(duration: 0.3), value: fraction)
                }

                Text("Please keep LootList open while we set up your family Guild.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()
        }
        .padding(.horizontal, 24)
    }

    /// Pure waiting surface for the joiner path: no inputs, no buttons — the
    /// user simply waits for an apple share invitation from their parent. When
    /// the invitation arrives, `pendingShareMetadata` is populated and the
    /// `.onChange(of:)` above accepts it, advancing to Avatar Selection.
    private var waitingBody: some View {
        VStack(spacing: 28) {
            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "envelope.badge.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .top, endPoint: .bottom
                        )
                    )

                Text("Waiting for your invite…")
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .multilineTextAlignment(.center)

                Text(
                    "Ask your family's parent to invite you through their LootList app. When they send the invitation, you'll get a message invitation — tap it to join the family."
                )
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)

                Text("If you already received an invitation link, tap it in Messages to begin.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 24)
            }

            #if DEBUG
                Button {
                    showDebugSharePrompt = true
                } label: {
                    Label("Simulate Share Link (Dev)", systemImage: "hammer")
                        .font(.footnote)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tertiary)
                .padding(.top, 8)
            #endif

            Spacer()

            Spacer().frame(height: 24)
        }
        .padding(.horizontal, 24)
        .accessibilityIdentifier("joinFamily.waitingScreen")
    }

    #if DEBUG
        /// Development-only stand-in for an incoming Apple Messages share link: the
        /// Simulator can't generate or receive CloudKit invites, so let the tester
        /// paste a share URL and push it through the same accept machinery as a
        /// real device tap — `container.shareMetadata(for:)` resolves the URL into
        /// `pendingShareMetadata`, which the `.onChange(of:)` above then accepts.
        @MainActor
        private func simulateShareLink() async {
            let trimmed = debugShareURLText.trimmingCharacters(in: .whitespacesAndNewlines)
            logger.info("Simulating share link with URL string: \(trimmed, privacy: .private)")
            guard let url = URL(string: trimmed) else {
                logger.error("Simulated share link URL parsing failed")
                toastManager.show(message: "That doesn't look like a valid URL.", type: .error)
                return
            }
            viewModel.joinProgressStatus = "Reading invitation link..."
            viewModel.joinProgressFraction = 0.15
            logger.info("Requesting container.shareMetadata(for: URL)...")
            do {
                let metadata = try await cloudKitService.container.shareMetadata(for: url)
                let title = metadata.share[CKShare.SystemFieldKey.title] as? String ?? "nil"
                let zone = metadata.hierarchicalRootRecordID?.zoneID.zoneName ?? "nil"
                logger.info("Resolved share metadata: zone='\(zone, privacy: .private)' title='\(title, privacy: .private)'")
                viewModel.joinProgressStatus = "Invitation verified! Connecting to family..."
                viewModel.joinProgressFraction = 0.3
                viewModel.pendingShareMetadata = metadata
            } catch {
                viewModel.joinProgressStatus = nil
                viewModel.joinProgressFraction = nil
                logger.error("Resolving share metadata failed: \(error, privacy: .private)")
                let friendlyMessage = friendlyInviteAcceptError(error)
                    ?? "Could not read that share link. Please try again."
                viewModel.error = friendlyMessage
                toastManager.show(message: friendlyMessage, type: .error)
            }
        }
    #endif

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
                Task {
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
}

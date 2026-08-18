//
//  GuildDangerZoneSectionView.swift
//  LootList
//
//  Created by Ben Mackin on 8/13/26.
//

import os
import SwiftUI

struct GuildDangerZoneSectionView: View {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "GuildDangerZone")

    @Environment(AppState.self) private var appState
    @Environment(FamilyService.self) private var familyService
    @Environment(CloudKitService.self) private var cloudKitService
    @Environment(CKSyncEngineCoordinator.self) private var syncCoordinator: CKSyncEngineCoordinator?
    @Environment(ToastManager.self) private var toastManager

    @Binding var isSigningOut: Bool

    @State private var showLeaveConfirm: Bool = false
    @State private var showDisbandConfirm: Bool = false
    @State private var showDisbandFinalConfirm: Bool = false

    var body: some View {
        VStack(spacing: 16) {
            if let currentRole = appState.currentProfile?.role, currentRole != .guildMaster {
                signOutSection
            }

            if let currentRole = appState.currentProfile?.role, currentRole == .guildMaster {
                deleteFamilySection
            }
        }
    }

    private var signOutSection: some View {
        VStack(spacing: 0) {
            Button(role: .destructive) {
                showLeaveConfirm = true
            } label: {
                Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.signOut")
        }
        .background(cardBackground)
        .padding(.horizontal)
        .alert("Sign Out?", isPresented: $showLeaveConfirm) {
            Button("Sign Out", role: .destructive) {
                Task { await signOut() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sign out of this device. Your Guild progress and profile stay safely synced in iCloud.")
        }
    }

    @MainActor
    private func signOut() async {
        isSigningOut = true
        defer { isSigningOut = false }
        await appState.signOutAndDiscover(cloudKit: cloudKitService, syncCoordinator: syncCoordinator)
    }

    private var deleteFamilySection: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Danger Zone")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.red)
                Spacer()
            }
            .padding(.horizontal, 16)

            VStack(spacing: 0) {
                Button(role: .destructive) {
                    showDisbandConfirm = true
                } label: {
                    Label("Delete Family & Reset App", systemImage: "trash.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.disbandFamily")
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.red.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.red.opacity(0.35), lineWidth: 1)
            )
            .padding(.horizontal)
        }
        .alert("Delete Family & Reset App?", isPresented: $showDisbandConfirm) {
            Button("Continue", role: .destructive) {
                showDisbandFinalConfirm = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This will permanently delete your family zone, quest history, loot, and member profiles from iCloud, returning you to the onboarding screen. This cannot be undone."
            )
        }
        .alert("Final Confirmation", isPresented: $showDisbandFinalConfirm) {
            Button("Delete Forever & Start Fresh", role: .destructive) {
                Task { await deleteFamilyAndReset() }
            }
            Button("Keep Family", role: .cancel) {}
        } message: {
            Text("Are you sure you want to permanently erase \(appState.family?.name ?? "this family") and start over from onboarding?")
        }
    }

    @MainActor
    private func deleteFamilyAndReset() async {
        guard let family = appState.family else {
            appState.clearSessionAndCloudKitScope(cloudKit: cloudKitService, syncCoordinator: syncCoordinator)
            return
        }

        do {
            try await familyService.deleteFamilyAndReset(family: family)
        } catch {
            logger.error("Failed to delete family zone: \(error, privacy: .private)")
            appState.clearSessionAndCloudKitScope(cloudKit: cloudKitService, syncCoordinator: syncCoordinator)
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground))
    }
}

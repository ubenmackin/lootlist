//
//  DetectedFamilyView.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import SwiftUI

struct DetectedFamilyView: View {
    let familyCache: FamilyCache
    let profileCache: ProfileCache
    // WHY: shared zones reuse zone names across owners, so both names travel to FamilyService for zone resolution.
    let zoneName: String
    let zoneOwnerName: String
    let isOwner: Bool

    @Environment(FamilyService.self) private var familyService

    @State private var isProcessing: Bool = false
    @State private var showConfirmDelete: Bool = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            headerSection

            familyCard

            Spacer()

            actionButtons
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [Color(DesignSystemConstants.Colors.background), Color(DesignSystemConstants.Colors.pendingAmber).opacity(0.12)],
                startPoint: .top, endPoint: .bottom
            )
        )
        .disabled(isProcessing)
        .overlay {
            if isProcessing {
                ProgressView("Updating iCloud...")
                    .padding(24)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
        }
        .alert(isOwner ? "Disband Previous Guild?" : "Leave Previous Guild?", isPresented: $showConfirmDelete) {
            Button(isOwner ? "Delete & Start Fresh" : "Leave & Start Fresh", role: .destructive) {
                Task {
                    isProcessing = true
                    await familyService.rejectDetectedFamily(
                        familyCache: familyCache,
                        profileCache: profileCache,
                        zoneName: zoneName,
                        zoneOwnerName: zoneOwnerName,
                        isOwner: isOwner
                    )
                    isProcessing = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if isOwner {
                Text("This will permanently remove '\(familyCache.name)' and all quest data from iCloud. You can then create a new guild.")
            } else {
                Text("This will mark your character profile inactive in '\(familyCache.name)'. You can then join a new guild.")
            }
        }
        .accessibilityIdentifier("detectedFamily.view")
    }

    private var headerSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "crown.fill")
                .font(.system(size: 64))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.gold, Color(DesignSystemConstants.Colors.pendingAmber)],
                        startPoint: .top, endPoint: .bottom
                    )
                )

            Text("Guild Discovered!")
                .font(.system(size: 34, weight: .heavy, design: .rounded))

            Text("We found an active family account linked to your iCloud account.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
        }
    }

    private var familyCard: some View {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                Image(systemName: profileCache.avatarClassEnum?.iconSystemName ?? (profileCache.roleEnum ?? .hero).iconSystemName)
                    .font(.system(size: 32))
                    .foregroundStyle(Color(DesignSystemConstants.Colors.pendingAmber))
                    .frame(width: 56, height: 56)
                    .background(Color(DesignSystemConstants.Colors.pendingAmber).opacity(0.15))
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text(familyCache.name)
                        .font(.title2.weight(.bold))

                    HStack(spacing: 8) {
                        Text(profileCache.displayName)
                            .font(.subheadline.weight(.semibold))

                        Text("•")
                            .foregroundStyle(.secondary)

                        Text(profileCache.roleEnum == .guildMaster ? "Guild Master" : "Hero")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(profileCache.roleEnum == .guildMaster ? Color(DesignSystemConstants.Colors.pendingAmber)
                                .opacity(0.2) : Color(DesignSystemConstants.Colors.accentBlue).opacity(0.2))
                            .foregroundStyle(profileCache
                                .roleEnum == .guildMaster ? Color(DesignSystemConstants.Colors.pendingAmber) : Color(DesignSystemConstants.Colors.accentBlue))
                            .clipShape(Capsule())
                    }
                }

                Spacer()
            }

            // Leveling and XP stats stay unrendered while the immersive layer
            // is off; the name and role above identify the member.
            Divider()

            HStack {
                Label((profileCache.roleEnum ?? .hero).displayName, systemImage: "person.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)

                Spacer()
            }
        }
        .padding(20)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(.white.opacity(0.2), lineWidth: 1)
        )
    }

    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button {
                Task {
                    await familyService.acceptDetectedFamily(
                        familyCache: familyCache,
                        profileCache: profileCache,
                        zoneName: zoneName,
                        zoneOwnerName: zoneOwnerName,
                        isOwner: isOwner
                    )
                }
            } label: {
                Label(isOwner ? "Restore Guild" : "Reconnect to Guild", systemImage: "arrow.triangle.2.circlepath")
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(DesignSystemConstants.Colors.primaryGreen))
            .accessibilityIdentifier("detectedFamily.restoreButton")

            Button(role: .destructive) {
                showConfirmDelete = true
            } label: {
                Label(isOwner ? "Delete & Start Fresh" : "Leave Guild & Start Fresh", systemImage: "trash")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .tint(Color(DesignSystemConstants.Colors.dangerRed))
            .accessibilityIdentifier("detectedFamily.resetButton")
        }
    }
}

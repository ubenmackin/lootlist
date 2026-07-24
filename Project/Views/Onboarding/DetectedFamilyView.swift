import CloudKit
import SwiftUI

struct DetectedFamilyView: View {
    let family: Family
    let profile: Profile
    let zoneID: CKRecordZone.ID
    let isOwner: Bool

    @Environment(AppState.self) private var appState
    @Environment(CloudKitService.self) private var cloudKitService

    @State private var isProcessing: Bool = false
    @State private var showConfirmDelete: Bool = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            headerSection

            familyCard

            Spacer()

            actionButtons

            Spacer().frame(height: 24)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [Color(.systemBackground), Color.yellow.opacity(0.12)],
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
                    await appState.rejectDetectedFamily(
                        family: family,
                        profile: profile,
                        zoneID: zoneID,
                        isOwner: isOwner,
                        cloudKit: cloudKitService
                    )
                    isProcessing = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if isOwner {
                Text("This will permanently remove '\(family.name)' and all quest data from iCloud. You can then create a new guild.")
            } else {
                Text("This will mark your character profile inactive in '\(family.name)'. You can then join a new guild.")
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
                        colors: [.yellow, .orange],
                        startPoint: .top, endPoint: .bottom
                    )
                )

            Text("Guild Discovered!")
                .font(.system(size: 34, weight: .heavy, design: .rounded))

            Text("We found an active family realm linked to your iCloud account.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
        }
    }

    private var familyCard: some View {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                Image(systemName: profile.avatarClass.iconSystemName)
                    .font(.system(size: 32))
                    .foregroundStyle(.orange)
                    .frame(width: 56, height: 56)
                    .background(Color.orange.opacity(0.15))
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text(family.name)
                        .font(.title2.weight(.bold))

                    HStack(spacing: 8) {
                        Text(profile.displayName)
                            .font(.subheadline.weight(.semibold))

                        Text("•")
                            .foregroundStyle(.secondary)

                        Text(profile.role == .guildMaster ? "Guild Master" : "Hero")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(profile.role == .guildMaster ? Color.yellow.opacity(0.2) : Color.blue.opacity(0.2))
                            .foregroundStyle(profile.role == .guildMaster ? Color.orange : Color.blue)
                            .clipShape(Capsule())
                    }
                }

                Spacer()
            }

            Divider()

            HStack {
                Label("Level \(profile.level)", systemImage: "star.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.yellow)

                Spacer()

                Text("\(profile.xp) Total XP")
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
    }

    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button {
                Task {
                    await appState.acceptDetectedFamily(
                        family: family,
                        profile: profile,
                        zoneID: zoneID,
                        isOwner: isOwner,
                        cloudKit: cloudKitService
                    )
                }
            } label: {
                Label(isOwner ? "Restore Guild" : "Reconnect to Guild", systemImage: "arrow.triangle.2.circlepath")
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
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
            .tint(.red)
            .accessibilityIdentifier("detectedFamily.resetButton")
        }
    }
}

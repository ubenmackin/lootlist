import SwiftUI
import CloudKit

struct ProfileView: View {

    private let avatarService: AvatarService

    private let xpService: XPService

    private let notificationService: NotificationService

    @Environment(AppState.self) private var appState

    @State private var showingEditName: Bool = false

    @State private var draftName: String = ""

    @State private var showingSignOutConfirm: Bool = false

    init(avatarService: AvatarService,
          xpService: XPService,
          notificationService: NotificationService) {
        self.avatarService = avatarService
        self.xpService = xpService
        self.notificationService = notificationService
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let profile = appState.currentProfile {
                        characterCard(profile: profile)
                        actionsSection(profile: profile)
                        aboutSection
                    } else {
                        emptyState
                    }
                }
                .padding(.vertical, 20)
            }
            .navigationTitle("Character")
            .navigationBarTitleDisplayMode(.large)
            .alert("Sign Out?", isPresented: $showingSignOutConfirm) {
                Button("Sign Out", role: .destructive) {
                    appState.signOut()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your local session will end and you'll return to the Welcome screen. Your Guild data stays synced in iCloud.")
            }
            .sheet(isPresented: $showingEditName) {
                if let profile = appState.currentProfile, profile.role == .hero {
                    editNameSheet(profile: profile)
                }
            }
        }
    }

    @ViewBuilder
    private func characterCard(profile: Profile) -> some View {
        let spec = avatarService.renderSpec(for: profile)
        let progress = xpService.levelProgress(profile: profile)

        VStack(spacing: 14) {
            AvatarView(spec: spec, size: .large, showsNameAndTitle: false)

            nameBlock(profile: profile, spec: spec)

            levelBadge(profile: profile, spec: spec)

            xpBlock(profile: profile, progress: progress)

            if profile.role == .hero {
                Button {
                    draftName = profile.displayName
                    showingEditName = true
                } label: {
                    Label("Rename Character", systemImage: "pencil.line")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(Color.gold)
                .accessibilityIdentifier("profile.renameButton")
            }
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .background(
            ZStack {
                LinearGradient(
                    colors: [
                        Color.purple.opacity(0.35),
                        Color.blue.opacity(0.30),
                        Color.indigo.opacity(0.50)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                RadialGradient(
                    colors: [Color.gold.opacity(0.20), .clear],
                    center: .center,
                    startRadius: 0, endRadius: 0.85
                )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.gold.opacity(0.45), lineWidth: 1)
        )
        .padding(.horizontal)
        .padding(.top, 4)
    }

    @ViewBuilder
    private func nameBlock(profile: Profile, spec: AvatarRenderSpec) -> some View {
        VStack(spacing: 4) {
            Text(profile.displayName)
                .font(.title2.bold())
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(spec.levelTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.gold)
            Text("\(profile.avatarClass.displayName) • \(profile.role.displayName)")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    @ViewBuilder
    private func levelBadge(profile: Profile, spec: AvatarRenderSpec) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "number")
                .font(.caption.weight(.bold))
            Text("\(profile.level)")
                .font(.callout.weight(.bold))
            Text("Level")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.18))
                .overlay(
                    Capsule().strokeBorder(Color.gold.opacity(0.70), lineWidth: 1)
                )
        )
    }

    private func xpBlock(profile: Profile, progress: LevelProgress) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Experience")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                Text("\(progress.xpIntoCurrentLevel) / \(progress.xpForNextLevel) XP")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white)
            }
            ProgressBar(
                value: Double(progress.xpIntoCurrentLevel),
                maximum: Double(max(progress.xpForNextLevel, 1)),
                label: nil,
                tint: Color.gold,
                height: 10
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.28))
        )
    }

    @ViewBuilder
    private func actionsSection(profile: Profile) -> some View {
        VStack(spacing: 0) {
            NavigationLink {
                CharacterSheetView(
                    profile: profile,
                    avatarService: avatarService,
                    xpService: xpService,
                    streak: nil,
                    goldBalance: nil,
                    earnedAchievements: [],
                    onSaveDisplayName: { newName in
                        guard profile.role == .hero,
                              var updated = appState.currentProfile else { return }
                        updated.displayName = newName
                        appState.currentProfile = updated
                    }
                )
            } label: {
                actionRow(
                    icon: "doc.text.magnifyingglass",
                    title: "Open Character Sheet",
                    subtitle: "Detailed stats, accessories, and trophies"
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("profile.openCharacterSheet")

            Divider().padding(.leading, 56)

            NavigationLink {
                if let family = appState.family {
                    NotificationSettingsView(
                        notificationService: notificationService,
                        profile: profile,
                        family: family
                    )
                }
            } label: {
                actionRow(
                    icon: "bell.badge",
                    title: "Notification Settings",
                    subtitle: "Per-event toggles: in-app + push"
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("profile.notificationSettings")

            Divider().padding(.leading, 56)

            Button {
                showingSignOutConfirm = true
            } label: {
                actionRow(
                    icon: "rectangle.portrait.and.arrow.right",
                    title: "Sign Out",
                    subtitle: "Return to the Welcome screen",
                    tint: .red
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("profile.signOut")
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .padding(.horizontal)
    }

    private func actionRow(icon: String,
                            title: String,
                            subtitle: String,
                            tint: Color = .accentColor) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private var aboutSection: some View {
        VStack(spacing: 0) {
            aboutRow(label: "Version",      value: appVersion)
            Divider().padding(.leading, 56)
            aboutRow(label: "Build",        value: buildNumber)
            Divider().padding(.leading, 56)
            aboutRow(label: "QuestLog",     value: "Family chore tracker · RPG mode")
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .padding(.horizontal)
    }

    private func aboutRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.body)
                .foregroundStyle(.primary)
            Spacer()
            Text(value)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return v.map { "v\($0)" } ?? "v1.0"
    }

    private var buildNumber: String {
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return b ?? "1"
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.fill.questionmark")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("No Character Loaded")
                .font(.title3.bold())
            Text("Sign in or pick a character to begin questing.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .padding(.top, 60)
    }

    @ViewBuilder
    private func editNameSheet(profile: Profile) -> some View {
        NavigationStack {
            Form {
                Section("Character Name") {
                    TextField("Sir Cleanup", text: $draftName)
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier("profile.displayNameField")
                }
                Section {
                    Text("Your Guildmates will see this name on the Hall of Heroes and Hero Status board.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Rename Character")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showingEditName = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        if var updated = appState.currentProfile {
                            updated.displayName = trimmed
                            appState.currentProfile = updated
                        }
                        showingEditName = false
                    }
                    .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("profile.displayNameSave")
                }
            }
        }
        .presentationDetents([.medium])
    }
}

import SwiftUI
import CloudKit

struct CharacterSheetView: View {

    let profile: Profile

    private let avatarService: AvatarService

    private let xpService: XPService

    let streak: Int?

    let goldBalance: Double?

    let earnedAchievements: [Achievement]

    let onSaveDisplayName: ((String) -> Void)?

    @State private var isEditingName: Bool = false

    @State private var draftName: String = ""

    init(profile: Profile,
          avatarService: AvatarService,
          xpService: XPService,
          streak: Int?,
          goldBalance: Double?,
          earnedAchievements: [Achievement],
          onSaveDisplayName: ((String) -> Void)?) {
        self.profile = profile
        self.avatarService = avatarService
        self.xpService = xpService
        self.streak = streak
        self.goldBalance = goldBalance
        self.earnedAchievements = earnedAchievements
        self.onSaveDisplayName = onSaveDisplayName
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header()
                statsGrid()
                accessorySection()
                achievementSection
                if profile.role == .hero, onSaveDisplayName != nil {
                    renameSection
                }
            }
            .padding(.vertical, 20)
        }
        .navigationTitle("Character Sheet")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
    }

    private func header() -> some View {
        let spec = avatarService.renderSpec(for: profile)
        return VStack(spacing: 12) {
            AvatarView(spec: spec, size: .large, showsNameAndTitle: false)
            Text(profile.displayName)
                .font(.title2.bold())
                .foregroundStyle(.primary)
            Text(spec.levelTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.gold)
            Text("\(profile.avatarClass.displayName) · \(profile.role.displayName)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [
                    Color.purple.opacity(0.30),
                    Color.blue.opacity(0.25),
                    Color.indigo.opacity(0.40)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.gold.opacity(0.40), lineWidth: 1)
        )
        .padding(.horizontal)
    }

    private func statsGrid() -> some View {
        let progress = xpService.levelProgress(profile: profile)
        return VStack(spacing: 16) {
            statTile(symbol: "number",
                        title: "Level",
                        value: "\(profile.level)",
                        accent: .blue)
            statTile(symbol: "crown.fill",
                        title: "Title",
                        value: XPService.title(forLevel: profile.level),
                        accent: .orange)
            statTile(symbol: "star.fill",
                        title: "XP Total",
                        value: "\(profile.xp)",
                        accent: .yellow)
            statTile(symbol: "arrow.up.right.circle.fill",
                        title: "XP to Next Level",
                        value: "\(progress.xpForNextLevel)",
                        accent: .green)

            HStack(spacing: 12) {
                statTile(symbol: "flame.fill",
                            title: "Combo Streak",
                            value: streak.map { "\($0) days" } ?? "—",
                            accent: .red)
                statTile(symbol: "circle.hexagongrid.fill",
                            title: "Gold",
                            value: goldBalance.map { Self.formatGold($0) } ?? "—",
                            accent: Color.gold)
            }
        }
    }

    private func statTile(symbol: String,
                            title: String,
                            value: String,
                            accent: Color) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(accent.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(accent)
                    .symbolRenderingMode(.hierarchical)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(value)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) \(value)")
    }

    private func accessorySection() -> some View {
        let unlocked = xpService.unlockedAccessories(profile: profile)
        return sectionContainer(title: "Equipped Accessories",
                                  systemImage: "wand.and.stars.fill") {
            if unlocked.isEmpty {
                Text("No accessories unlocked yet — reach level 5 to earn your first.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(unlocked, id: \.self) { id in
                        HStack(spacing: 10) {
                            if let glyph = AvatarService.accessoryGlyph(for: id) {
                                Image(systemName: glyph)
                                    .font(.body)
                                    .foregroundStyle(Color.gold)
                                    .symbolRenderingMode(.hierarchical)
                                    .frame(width: 24)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Self.accessoryTitle(for: id))
                                    .font(.subheadline.weight(.semibold))
                                Text(id)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "checkmark.seal.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private var achievementSection: some View {
        sectionContainer(title: "Trophy Snapshot",
                          systemImage: "trophy.fill") {
            VStack(spacing: 12) {
                HStack {
                    Text("Earned")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Spacer()
                    Text("\(earnedAchievements.count)")
                        .font(.title3.bold().monospacedDigit())
                        .foregroundStyle(Color.gold)
                }

                if earnedAchievements.isEmpty {
                    Text("No trophies earned yet — quest on!")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    LazyVGrid(columns: trophyColumns, spacing: 12) {
                        ForEach(recentTrophies, id: \.id) { trophy in
                            miniTrophy(trophy)
                        }
                    }
                    if earnedAchievements.count > recentTrophies.count {
                        Text("+ \(earnedAchievements.count - recentTrophies.count) more in the Hall of Heroes")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var trophyColumns: [GridItem] {
        [GridItem(.flexible(), spacing: 12),
         GridItem(.flexible(), spacing: 12),
         GridItem(.flexible(), spacing: 12)]
    }

    private var recentTrophies: [Achievement] {
        Array(earnedAchievements.prefix(6))
    }

    private func miniTrophy(_ trophy: Achievement) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(Color.gold.opacity(0.18))
                Image(systemName: trophy.iconSystemName)
                    .font(.title3)
                    .foregroundStyle(Color.gold)
                    .symbolRenderingMode(.hierarchical)
            }
            .frame(width: 56, height: 56)
            Text(trophy.name)
                .font(.caption2.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.75)
                .frame(height: 30, alignment: .top)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.tertiarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.gold.opacity(0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Trophy \(trophy.name)")
    }

    @ViewBuilder
    private var renameSection: some View {
        sectionContainer(title: "Display Name",
                          systemImage: "person.line.dotted.person.fill") {
            if isEditingName {
                renameEditor
            } else {
                HStack {
                    Text(profile.displayName)
                        .font(.body.weight(.semibold))
                    Spacer()
                    Button {
                        draftName = profile.displayName
                        isEditingName = true
                    } label: {
                        Label("Edit", systemImage: "pencil")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("characterSheet.renameButton")
                }
            }
        }
    }

    @ViewBuilder
    private var renameEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Sir Cleanup", text: $draftName)
                .textInputAutocapitalization(.words)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(.tertiarySystemBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.gold.opacity(0.45), lineWidth: 1)
                )
                .accessibilityIdentifier("characterSheet.displayNameField")
            HStack(spacing: 12) {
                Button("Cancel") {
                    isEditingName = false
                    draftName = ""
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("characterSheet.renameCancel")
                Spacer()
                Button("Save") {
                    let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    onSaveDisplayName?(trimmed)
                    isEditingName = false
                    draftName = ""
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("characterSheet.renameSave")
            }
        }
    }

    @ViewBuilder
    private func sectionContainer<Content: View>(title: String,
                                                    systemImage: String,
                                                    @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(.primary)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .padding(.horizontal)
    }

    private static func formatGold(_ amount: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: abs(amount))) ?? "\(amount)"
    }

    private static func accessoryTitle(for id: String) -> String {
        switch id {
        case "accessory.level.5":   return "Sparkle Aura"
        case "accessory.level.10":  return "Bolt Aura"
        case "accessory.level.15":  return "Stellar Aura"
        case "accessory.level.20":  return "Phoenix Aura"
        default:                     return "Accessory \(id)"
        }
    }
}


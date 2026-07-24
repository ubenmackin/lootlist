import CloudKit
import SwiftUI

struct FamilyDashboardView: View {
    @Environment(AppState.self) private var appState
    @Environment(QuestService.self) private var questService
    @Environment(TreasuryService.self) private var treasury
    @Environment(AchievementService.self) private var achievementService

    @State private var viewModel: FamilyDashboardViewModel?
    @State private var showShareSheet: Bool = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if let vm = viewModel {
                        loadedContent(vm: vm)
                    } else {
                        loadingPlaceholder
                    }
                }
                .padding(.vertical, 14)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle(appState.family?.name ?? "Guild")
            .navigationBarTitleDisplayMode(.large)
            .refreshable { await viewModel?.refresh() }
            .task {
                if viewModel == nil {
                    viewModel = FamilyDashboardViewModel(
                        questService: questService,
                        treasury: treasury,
                        achievementService: achievementService,
                        appState: appState
                    )
                }
                await viewModel?.refresh()
            }
            .sheet(isPresented: $showShareSheet) {
                ShareSheet(items: shareInviteItems)
            }
        }
    }

    @ViewBuilder
    private func loadedContent(vm: FamilyDashboardViewModel) -> some View {
        parentHeaderCard
        weeklySummaryCard(summary: vm.weekSummary)
        heroesSection(vm: vm)
        if let error = vm.loadError {
            Text(error)
                .font(.footnote)
                .foregroundStyle(.red)
                .padding(.horizontal)
        }
    }

    private var parentHeaderCard: some View {
        HStack(spacing: 12) {
            if let profile = appState.currentProfile {
                let preset = AvatarPreset.preset(forProfile: profile)
                let spec = AvatarRenderSpec(
                    preset: preset,
                    displayName: profile.displayName,
                    levelTitle: profile.role.displayName,
                    equippedAccessory: nil
                )
                AvatarView(spec: spec, size: .small, showsNameAndTitle: false)

                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.displayName)
                        .font(.body.weight(.bold))
                        .foregroundStyle(.primary)
                    Text(profile.role.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Guild Master")
                    .font(.body.weight(.bold))
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .padding(.horizontal)
    }

    private var inviteButton: some View {
        Button {
            showShareSheet = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.up")
                    .font(.caption.weight(.bold))
                Text("Invite Heroes")
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color(.secondarySystemGroupedBackground))
                    .overlay(
                        Capsule().strokeBorder(Color.gold.opacity(0.45), lineWidth: 1)
                    )
            )
        }
        .accessibilityLabel("Invite Heroes. Tap to share invitation link.")
    }

    private var shareInviteItems: [Any] {
        appState.shareInviteItems
    }

    private func weeklySummaryCard(summary: WeekendSummary?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("This Week's Haul")
                    .font(.headline)
                Spacer()
                if let summary {
                    Text(summary.weekOf, format: .dateTime.month().day())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let summary {
                totalsRow(summary: summary)
                Divider()
                whoCompletedWhatList(summary: summary)
            } else {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Tallying the guild's loot…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.gold.opacity(0.30), lineWidth: 1)
        )
        .padding(.horizontal)
    }

    private func totalsRow(summary: WeekendSummary) -> some View {
        HStack(spacing: 16) {
            statBlock(
                icon: "circle.hexagongrid.fill",
                value: String(format: "%.2f", summary.totalEarned),
                label: "Gold Earned",
                tint: .gold
            )
            Divider()
            statBlock(
                icon: "checkmark.seal.fill",
                value: "\(summary.totalQuestsCompleted)",
                label: "Quests Slain",
                tint: .green
            )
            Divider()
            statBlock(
                icon: "person.2.fill",
                value: "\(summary.heroSummaries.count)",
                label: "Active Heroes",
                tint: .purple
            )
        }
        .frame(maxWidth: .infinity)
    }

    private func statBlock(icon: String,
                           value: String,
                           label: String,
                           tint: Color) -> some View
    {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(tint)
                Text(value)
                    .font(.title3.weight(.bold).monospacedDigit())
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func whoCompletedWhatList(summary: WeekendSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Breakdown")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if summary.heroSummaries.isEmpty {
                Text("No quest activity recorded yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(summary.heroSummaries) { hero in
                    HStack {
                        Text(hero.profile.displayName)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(hero.weeklyQuestsCompleted) quests")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.2f gold", hero.weeklyGoldEarned))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.gold)
                    }
                }
            }
        }
    }

    private func heroesSection(vm: FamilyDashboardViewModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Heroes")
                    .font(.headline)
                Spacer()
                inviteButton
            }
            .padding(.horizontal)

            if vm.heroes.isEmpty {
                emptyHeroesCard
            } else {
                VStack(spacing: 12) {
                    ForEach(vm.weekSummary?.heroSummaries ?? []) { summary in
                        HeroStatusCard(summary: summary)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private var emptyHeroesCard: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.15))
                    .frame(width: 64, height: 64)
                Image(systemName: "person.badge.plus")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Color.orange)
            }

            VStack(spacing: 6) {
                Text("Recruit Your Party!")
                    .font(.title3.weight(.heavy))
                Text("Your guild needs heroes to embark on quests. Tap **Invite Heroes** above to share an invitation link or copy your guild code.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1.5)
        )
        .padding(.horizontal)
    }

    private var loadingPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "house")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)
                .padding(.top, 120)
            Text("Summoning your guild…")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

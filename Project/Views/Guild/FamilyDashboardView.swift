import SwiftUI
import CloudKit

struct FamilyDashboardView: View {

    @Environment(AppState.self) private var appState
    @Environment(QuestService.self) private var questService
    @Environment(TreasuryService.self) private var treasury
    @Environment(AchievementService.self) private var achievementService

    @State private var viewModel: FamilyDashboardViewModel?
    @State private var showInviteCopiedToast: Bool = false

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
            .navigationTitle(appState.family?.name ?? "Family")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        GuildSettingsView()
                    } label: {
                        Image(systemName: "gear")
                            .accessibilityLabel("Guild Settings")
                    }
                }
            }
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
        }
    }

    @ViewBuilder
    private func loadedContent(vm: FamilyDashboardViewModel) -> some View {
        familyHeader
        weeklySummaryCard(summary: vm.weekSummary)
        heroesSection(vm: vm)
        navigationSection
        if let error = vm.loadError {
            Text(error)
                .font(.footnote)
                .foregroundStyle(.red)
                .padding(.horizontal)
        }
    }

    private var familyHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "house.fill")
                    .font(.title2)
                    .foregroundStyle(Color.purple)
                Text(appState.family?.name ?? "Your Guild")
                    .font(.title2.bold())
                Spacer()
            }
            inviteCodeChip
        }
        .padding(.horizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            if showInviteCopiedToast {
                Text("Copied!")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.green.opacity(0.85)))
                    .transition(.opacity)
                    .padding(.trailing, 4)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showInviteCopiedToast)
    }

    private var inviteCodeChip: some View {
        let code = appState.family?.inviteCode ?? "—"
        return Button {
            UIPasteboard.general.string = code
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                if UIPasteboard.general.string == code {
                    UIPasteboard.general.string = nil
                }
            }
            withAnimation { showInviteCopiedToast = true }
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await MainActor.run {
                    withAnimation { showInviteCopiedToast = false }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.caption.weight(.bold))
                Text("Invite Code")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(code)
                    .font(.callout.weight(.bold).monospaced())
                Image(systemName: "doc.on.doc")
                    .font(.caption2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(Color(.secondarySystemGroupedBackground))
                    .overlay(
                        Capsule().strokeBorder(Color.gold.opacity(0.45), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Invite code: \(code). Double tap to copy.")
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
                tint: Color.gold,
                value: String(format: "%.2f", summary.totalEarned),
                label: "Gold Earned"
            )
            statBlock(
                icon: "checkmark.seal.fill",
                tint: .green,
                value: "\(summary.totalQuestsCompleted)",
                label: "Quests Slain"
            )
            statBlock(
                icon: "list.bullet.clipboard",
                tint: .blue,
                value: "\(summary.totalQuestsAssigned)",
                label: "Quests Out"
            )
        }
    }

    private func statBlock(icon: String, tint: Color, value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
            Text(value)
                .font(.title3.bold().monospacedDigit())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private func whoCompletedWhatList(summary: WeekendSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Who Completed What")
                .font(.subheadline.weight(.semibold))
            let ranked = summary.heroSummaries.sorted {
                if $0.weeklyQuestsCompleted != $1.weeklyQuestsCompleted {
                    return $0.weeklyQuestsCompleted > $1.weeklyQuestsCompleted
                }
                return $0.weeklyGoldEarned > $1.weeklyGoldEarned
            }
            ForEach(ranked) { hero in
                miniHeroRow(hero)
            }
        }
    }

    private func miniHeroRow(_ hero: HeroSummary) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.gray.opacity(0.20))
                .frame(width: 22, height: 22)
                .overlay(
                    Image(systemName: "figure.and.child.holdinghands")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                )
            Text(hero.profile.displayName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Spacer()
            Text("\(hero.weeklyQuestsCompleted)/\(hero.weeklyQuestsTotal)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            GoldBadge(amount: hero.weeklyGoldEarned, size: .small)
        }
    }

    private func heroesSection(vm: FamilyDashboardViewModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Heroes")
                    .font(.headline)
                Spacer()
                Text("\(vm.heroes.count)")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            if vm.heroes.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "person.fill.viewfinder")
                        .font(.system(size: 44))
                        .foregroundStyle(.tertiary)
                    Text("No active heroes in your family yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Invite a hero with your invite code to begin.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
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

    private var navigationSection: some View {
        VStack(spacing: 0) {
            NavigationLink {
                PayoutHistoryView()
            } label: {
                actionRow(
                    icon: "calendar.badge.checkmark",
                    title: "Payout History",
                    subtitle: "Past Sunday Loot Day payouts"
                )
            }
            .buttonStyle(.plain)

            Divider().padding(.leading, 56)

            NavigationLink {
                GuildSettingsView()
            } label: {
                actionRow(
                    icon: "gearshape.fill",
                    title: "Guild Settings",
                    subtitle: "Family name, roles, invite codes"
                )
            }
            .buttonStyle(.plain)
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
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

import SwiftUI

struct TrophyRoomView: View {
    @State private var viewModel: TrophyRoomViewModel?

    @Environment(AchievementService.self) private var achievementService
    @Environment(XPService.self) private var xpService
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationStack {
            ScrollView {
                if let viewModel {
                    content(for: viewModel)
                } else {
                    loadingPlaceholder
                }
            }
            .navigationTitle("Hall of Heroes")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Image(systemName: "building.columns.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
        }
        .task {
            if viewModel == nil {
                viewModel = TrophyRoomViewModel(
                    achievementService: achievementService,
                    xpService: xpService,
                    appState: appState
                )
            }
            await viewModel?.refresh()
        }
    }

    private func content(for viewModel: TrophyRoomViewModel) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let avatar = viewModel.avatarCard {
                AvatarCardView(model: avatar)
                    .padding(.horizontal)
                    .padding(.top, 8)
            }

            header

            trophyGrid(using: viewModel)

            if let err = viewModel.lastError {
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }
        }
        .padding(.bottom, 24)
    }

    private var loadingPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "building.columns")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)
                .padding(.top, 120)
            Text("Entering the Hall of Heroes…")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Trophies")
                .font(.title2.bold())
            Spacer()
            let earnedCount = viewModel?.earned.count ?? 0
            let totalCount = viewModel?.allAchievements.count ?? 0
            Text("\(earnedCount) / \(totalCount)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    private func trophyGrid(using viewModel: TrophyRoomViewModel) -> some View {
        let columns: [GridItem] = [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12)
        ]

        let earnedIDs = viewModel.earnedIDs
        return LazyVGrid(columns: columns, spacing: 12) {
            ForEach(viewModel.allAchievements) { achievement in
                TrophyCardView(
                    achievement: achievement,
                    isEarned: earnedIDs.contains(achievement.id)
                )
            }
        }
        .padding(.horizontal)
    }
}

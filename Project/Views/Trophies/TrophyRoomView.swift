//
//  TrophyRoomView.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import SwiftData
import SwiftUI

struct TrophyRoomView: View {
    @State private var viewModel: TrophyRoomViewModel?

    @Environment(AchievementService.self) private var achievementService
    @Environment(XPService.self) private var xpService
    @Environment(AppState.self) private var appState

    @Query private var cachedAchievements: [AchievementCache]
    @Query private var cachedProfileAchievements: [ProfileAchievementCache]

    /// Family record name used to push the family filter down to SwiftData.
    /// When `nil` (no family loaded) the queries return zero rows, which is
    /// the correct behavior — there is no family to scope to.
    private let familyRecordName: String?

    init(familyRecordName: String? = nil) {
        self.familyRecordName = familyRecordName

        // Filter queries by family at the SwiftData store layer. When familyRecordName is nil,
        // scope to an empty string ("") so zero rows are returned rather than fetching unscoped across all families.
        let targetFamily = familyRecordName ?? ""
        let achievementFilter = #Predicate<AchievementCache> { $0.familyRecordName == targetFamily }
        let profileAchievementFilter = #Predicate<ProfileAchievementCache> { $0.familyRecordName == targetFamily }
        _cachedAchievements = Query(
            filter: achievementFilter,
            sort: \AchievementCache.name
        )
        _cachedProfileAchievements = Query(
            filter: profileAchievementFilter,
            sort: \ProfileAchievementCache.earnedDate,
            order: .reverse
        )
    }

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
            .refreshable {
                rebuild()
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
            rebuild()
        }
        .onChange(of: cachedAchievements) { _, _ in rebuild() }
        .onChange(of: cachedProfileAchievements) { _, _ in rebuild() }
    }

    private func rebuild() {
        guard let profileName = appState.currentProfile?.id.recordName else { return }

        // Filter family-scoped cached achievements for the active profile.
        let earned = cachedProfileAchievements.filter { $0.profileRecordName == profileName }

        viewModel?.rebuildLists(earned: earned, allAchievements: cachedAchievements)
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

        let earnedNames = viewModel.earnedAchievementRecordNames
        return LazyVGrid(columns: columns, spacing: 12) {
            ForEach(viewModel.allAchievements) { achievement in
                TrophyCardView(
                    achievement: achievement,
                    isEarned: earnedNames.contains(achievement.recordName)
                )
            }
        }
        .padding(.horizontal)
    }
}

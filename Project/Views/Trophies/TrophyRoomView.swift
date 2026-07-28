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

    @Query(sort: \AchievementCache.name) private var cachedAchievements: [AchievementCache]
    @Query(sort: \ProfileAchievementCache.earnedDate, order: .reverse) private var cachedProfileAchievements: [ProfileAchievementCache]

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
                // re-derive from the current cache snapshot. Background
                // CloudKit freshness is driven by `SyncEngine`.
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
            // synchronous initial render from the current `@Query` cache
            // snapshot. Subsequent mutations re-fire `.onChange`.
            rebuild()
            // One-shot background freshness touch: warm the achievement caches
            // from CK. The services upsert into SwiftData (cache-first), which
            // re-fires `.onChange` → `rebuild`. Does NOT block the cache render.
            if let profile = appState.currentProfile {
                Task { _ = try? await achievementService.fetchEarned(profile: profile) }
                if let family = appState.family {
                    Task { _ = try? await achievementService.fetchAllDefinitions(family: family) }
                }
            }
        }
        .onChange(of: cachedAchievements) { _, _ in rebuild() }
        .onChange(of: cachedProfileAchievements) { _, _ in rebuild() }
    }

    private func rebuild() {
        guard let familyName = appState.family?.id.recordName else { return }
        guard let profileName = appState.currentProfile?.id.recordName else { return }

        let achievements = cachedAchievements.filter { $0.familyRecordName == familyName }
        let earned = cachedProfileAchievements.filter { $0.profileRecordName == profileName }

        viewModel?.rebuildLists(earned: earned, allAchievements: achievements)
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

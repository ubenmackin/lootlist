//
//  TrophyRoomView.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import os
import SwiftData
import SwiftUI

struct TrophyRoomView: View {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "TrophyRoom")
    @State private var viewModel: TrophyRoomViewModel?

    @Environment(AchievementService.self) private var achievementService
    @Environment(XPService.self) private var xpService
    @Environment(AppState.self) private var appState
    @Environment(AppLifecycleCoordinator.self) private var lifecycleCoordinator: AppLifecycleCoordinator?

    @Query private var cachedAchievements: [AchievementCache]
    @Query private var cachedProfileAchievements: [ProfileAchievementCache]
    @Query private var currentProfileRows: [ProfileCache]

    /// Family record name used to push the family filter down to SwiftData.
    /// When `nil` (no family loaded) the queries return zero rows, which is
    /// the correct behavior — there is no family to scope to.
    private let familyRecordName: String?

    private let profileRecordName: String?

    init(familyRecordName: String? = nil, profileRecordName: String? = nil) {
        self.familyRecordName = familyRecordName
        self.profileRecordName = profileRecordName

        // Filter queries by family at the SwiftData store layer. When familyRecordName is nil,
        // scope to an empty string ("") so zero rows are returned rather than fetching unscoped across all families.
        let targetFamily = familyRecordName ?? ""
        let targetProfile = profileRecordName ?? ""
        let achievementFilter = #Predicate<AchievementCache> { $0.familyRecordName == targetFamily }
        let profileAchievementFilter = #Predicate<ProfileAchievementCache> { $0.familyRecordName == targetFamily }
        let currentProfileFilter = #Predicate<ProfileCache> {
            $0.recordName == targetProfile && $0.familyRecordName == targetFamily
        }
        _cachedAchievements = Query(
            filter: achievementFilter,
            sort: \AchievementCache.name
        )
        _cachedProfileAchievements = Query(
            filter: profileAchievementFilter,
            sort: \ProfileAchievementCache.earnedDate,
            order: .reverse
        )
        _currentProfileRows = Query(
            filter: currentProfileFilter,
            sort: \ProfileCache.displayName
        )
    }

    /// Queried cache row for the active hero profile; nil when identity or
    /// family scope has no synced row yet, keeping rendering fail-closed.
    private var currentProfileRow: ProfileCache? {
        currentProfileRows.first
    }

    var body: some View {
        NavigationStack {
            Group {
                if let viewModel {
                    content(for: viewModel)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityHidden(true)
                }
            }
            .navigationTitle("Hall of Heroes")
            .navigationBarTitleDisplayMode(.large)
            .refreshable {
                await lifecycleCoordinator?.performManualSync()
                if let profile = appState.currentProfile, let family = appState.family {
                    do {
                        _ = try await achievementService.evaluateAll(for: profile, family: family)
                    } catch {
                        Self.logger.warning("Failed to evaluate trophies during refresh: \(error, privacy: .private)")
                    }
                }
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
            if let profile = appState.currentProfile, let family = appState.family {
                do {
                    _ = try await achievementService.evaluateAll(for: profile, family: family)
                } catch {
                    Self.logger.warning("Failed to evaluate trophies on entry: \(error, privacy: .private)")
                }
                rebuild()
            }
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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TrophyHeaderCardView(
                    earnedCount: viewModel.earned.count,
                    totalCount: viewModel.allAchievements.count,
                    heroName: currentProfileRow?.displayName,
                    latestTrophyName: viewModel.latestEarnedTrophyName
                )
                .padding(.horizontal)
                .padding(.top, 8)

                Text("All Trophies")
                    .font(.title2.bold())
                    .padding(.horizontal)

                trophyGrid(using: viewModel)

                if let err = viewModel.lastError {
                    Text(err)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .background(Color(.systemGroupedBackground))
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

struct TrophyHeaderCardView: View {
    let earnedCount: Int
    let totalCount: Int
    let heroName: String?
    let latestTrophyName: String?

    private var progressRatio: Double {
        guard totalCount > 0 else { return 0 }
        return min(1.0, max(0.0, Double(earnedCount) / Double(totalCount)))
    }

    private var percentText: String {
        "\(Int(progressRatio * 100))%"
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [Color.gold.opacity(0.3), Color.orange.opacity(0.15)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(width: 52, height: 52)

                    Image(systemName: "trophy.fill")
                        .font(.title2)
                        .foregroundStyle(Color.gold)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Hall of Heroes Mastery")
                        .font(.headline.weight(.bold))

                    if let heroName, !heroName.isEmpty {
                        Text("\(heroName)'s Chronicle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(percentText)
                        .font(.title2.bold().monospacedDigit())
                        .foregroundStyle(Color.gold)
                    Text("\(earnedCount) / \(totalCount)")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.15))
                            .frame(height: 8)

                        Capsule()
                            .fill(LinearGradient(
                                colors: [.gold, .orange],
                                startPoint: .leading,
                                endPoint: .trailing
                            ))
                            .frame(width: geo.size.width * progressRatio, height: 8)
                    }
                }
                .frame(height: 8)

                if let latestTrophyName {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.caption2)
                            .foregroundStyle(Color.gold)
                        Text("Latest Unlock: \(latestTrophyName)")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("Complete quests to unlock trophies!")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.gold.opacity(0.25), lineWidth: 1)
        )
    }
}

//
//  HeroHomeView.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import CloudKit
import os
import SwiftData
import SwiftUI

struct HeroHomeView: View {
    @Environment(AppState.self) private var appState
    @Environment(XPService.self) private var xpService
    @Environment(GemService.self) private var gemService

    @Query private var cachedQuests: [QuestCache]
    @Query private var cachedCompletions: [QuestCompletionCache]
    @Query private var cachedTemplates: [QuestTemplateCache]
    @Query private var cachedProfiles: [ProfileCache]
    @Query private var cachedAllowancePeriods: [AllowancePeriodCache]

    @State private var viewModel: HeroDashboardViewModel?

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "HeroHomeView")

    private let familyRecordName: String?

    init(familyRecordName: String? = nil) {
        self.familyRecordName = familyRecordName

        // Filter queries by family at the SwiftData store layer. When familyRecordName is nil,
        // scope to an empty string ("") so zero rows are returned rather than fetching unscoped across all families.
        let targetFamily = familyRecordName ?? ""
        let questFilter = #Predicate<QuestCache> { $0.familyRecordName == targetFamily && $0.isActive == true }
        let completionFilter = #Predicate<QuestCompletionCache> { $0.familyRecordName == targetFamily }
        let templateFilter = #Predicate<QuestTemplateCache> { $0.familyRecordName == targetFamily && $0.isActive == true }
        let profileFilter = #Predicate<ProfileCache> { $0.familyRecordName == targetFamily }
        let allowanceFilter = #Predicate<AllowancePeriodCache> { $0.familyRecordName == targetFamily }

        _cachedQuests = Query(
            filter: questFilter,
            sort: \QuestCache.weekOf,
            order: .reverse
        )
        _cachedCompletions = Query(
            filter: completionFilter,
            sort: \QuestCompletionCache.completedDate,
            order: .reverse
        )
        _cachedTemplates = Query(
            filter: templateFilter,
            sort: \QuestTemplateCache.name
        )
        _cachedProfiles = Query(
            filter: profileFilter,
            sort: \ProfileCache.displayName
        )
        _cachedAllowancePeriods = Query(
            filter: allowanceFilter,
            sort: \AllowancePeriodCache.weekOf,
            order: .reverse
        )
    }

    /// Quests assigned to the active hero profile.
    private var profileQuests: [QuestCache] {
        guard let name = appState.currentProfile?.id.recordName else { return [] }
        return cachedQuests.filter { $0.assigneeRecordName == name && $0.isActive }
    }

    /// Completions logged by the active hero profile.
    private var profileLogs: [QuestCompletionCache] {
        guard let name = appState.currentProfile?.id.recordName else { return [] }
        return cachedCompletions.filter { $0.completerRecordName == name }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DesignSystemConstants.Padding.standard) {
                    DailyLoginBannerView(compactMode: true)

                    compactPlayerCard

                    if let profile = appState.currentProfile {
                        MascotBannerView(profile: profile, quests: profileQuests, completions: profileLogs, showBonusCard: false)
                    }
                }
                .padding(.horizontal, DesignSystemConstants.Padding.standard)
                .padding(.bottom, DesignSystemConstants.Padding.standard - 4)
            }
            .background(Color(.systemGroupedBackground))
            .scrollContentBackground(.hidden)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        GemShopView()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "diamond.fill")
                                .foregroundStyle(Color.gold)
                            Text(gemsBalance.map(String.init) ?? "–")
                                .font(.subheadline.bold())
                                .foregroundStyle(Color.gold)
                        }
                    }
                    .accessibilityLabel(gemsBalance.map { "Gem Shop, \($0) gems available" } ?? "Gem Shop, gem balance unavailable")
                }
            }
            .task {
                if viewModel == nil {
                    viewModel = HeroDashboardViewModel(appState: appState)
                }
                rebuildViewModel()
            }
            .onChange(of: cachedQuests) { _, _ in
                rebuildViewModel()
            }
            .onChange(of: cachedCompletions) { _, _ in
                rebuildViewModel()
            }
            .onChange(of: cachedTemplates) { _, _ in
                rebuildViewModel()
            }
            .onChange(of: cachedProfiles) { _, _ in
                rebuildViewModel()
            }
            .onChange(of: cachedAllowancePeriods) { _, _ in
                rebuildViewModel()
            }
        }
    }

    // MARK: - Compact Player Card

    @ViewBuilder
    private var compactPlayerCard: some View {
        if let profile = appState.currentProfile {
            let progress = xpService.levelProgress(profile: profile)
            HStack(spacing: 12) {
                ProfileAvatarView(profile: profile)
                    .frame(width: 64, height: 64)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(profile.displayName)
                            .font(.headline)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)

                        Text("Lv. \(progress.currentLevel)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(Color.accentColor)
                            )
                    }

                    HStack(spacing: 8) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color(.tertiarySystemFill))

                                Capsule()
                                    .fill(LinearGradient(
                                        colors: [.blue, .purple],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    ))
                                    .frame(width: max(0, geo.size.width * CGFloat(progress.progress)))
                                    .animation(.spring(response: 0.6, dampingFraction: 0.8), value: progress.progress)
                            }
                        }
                        .frame(height: 6)

                        if let familyName = appState.family?.name, !familyName.isEmpty {
                            familyNamePill(familyName)
                        }
                    }
                }
            }
            .padding(DesignSystemConstants.Padding.standard)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.card, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.card, style: .continuous)
                    .strokeBorder(Color.gold.opacity(0.30), lineWidth: 1)
            )
        }
    }

    private func familyNamePill(_ name: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "shield.fill")
                .font(.caption2)
            Text(name)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(Color.accentColor.opacity(0.12))
        )
        .overlay(
            Capsule()
                .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
        )
        .foregroundStyle(Color.accentColor)
    }

    // MARK: - Helpers

    private var gemsBalance: Int? {
        guard let profile = appState.currentProfile else { return nil }
        let family = appState.family?.id.recordName ?? profile.family.recordID.recordName
        do {
            return try gemService.balance(for: profile.id.recordName, familyRecordName: family)
        } catch {
            logger.warning("HeroHomeView.gemsBalance: failed to fetch gem balance: \(error, privacy: .private)")
            return nil
        }
    }

    private func rebuildViewModel() {
        appState.updateCurrentProfileFromCache()
        guard let vm = viewModel else { return }
        guard let profileName = appState.currentProfile?.id.recordName else { return }

        // Filter family-scoped cached records for the active hero profile.
        let quests = cachedQuests
            .filter { $0.assigneeRecordName == profileName && $0.isActive }

        let logs = cachedCompletions
            .filter { $0.completerRecordName == profileName }

        vm.rebuildLists(quests: quests, logs: logs, templates: cachedTemplates, allowancePeriods: cachedAllowancePeriods)
    }
}

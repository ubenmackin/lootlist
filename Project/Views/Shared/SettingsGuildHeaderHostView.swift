//
//  SettingsGuildHeaderHostView.swift
//  LootList
//
//  Created by Ben Mackin on 9/01/26.
//

import os
import SwiftData
import SwiftUI

struct SettingsGuildHeaderHostView: View {
    let familyRecordName: String?
    @Environment(AppState.self) private var appState
    @Environment(FamilyService.self) private var familyService
    @Environment(QuestService.self) private var questService
    @Environment(TreasuryService.self) private var treasury
    @Environment(AchievementService.self) private var achievementService
    @Environment(ToastManager.self) private var toastManager
    @State private var viewModel: FamilyDashboardViewModel?
    @State private var draftFamilyName: String = ""
    @State private var isEditingFamilyName: Bool = false
    @State private var showRolePicker: Bool = false
    @State private var sharePresentation: CloudSharePresentation?
    @Query private var cachedProfiles: [ProfileCache]
    @Query private var cachedQuests: [QuestCache]
    @Query private var cachedCompletions: [QuestCompletionCache]
    @Query private var cachedLedgers: [LedgerEntryCache]
    @Query private var cachedAllowancePeriods: [AllowancePeriodCache]
    @Query private var cachedAchievements: [AchievementCache]
    @Query private var cachedProfileAchievements: [ProfileAchievementCache]
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "SettingsGuildHeader")

    init(familyRecordName: String? = nil) {
        self.familyRecordName = familyRecordName
        let targetFamily = familyRecordName ?? ""
        let profileFilter = #Predicate<ProfileCache> { $0.familyRecordName == targetFamily }
        let questFilter = #Predicate<QuestCache> { $0.familyRecordName == targetFamily && $0.isActive == true }
        let completionFilter = #Predicate<QuestCompletionCache> { $0.familyRecordName == targetFamily }
        let ledgerFilter = #Predicate<LedgerEntryCache> { $0.familyRecordName == targetFamily }
        let allowanceFilter = #Predicate<AllowancePeriodCache> { $0.familyRecordName == targetFamily }
        let achievementFilter = #Predicate<AchievementCache> { $0.familyRecordName == targetFamily }
        let profileAchievementFilter = #Predicate<ProfileAchievementCache> { $0.familyRecordName == targetFamily }
        _cachedProfiles = Query(filter: profileFilter, sort: [SortDescriptor(\ProfileCache.displayName), SortDescriptor(\ProfileCache.recordName)])
        _cachedQuests = Query(filter: questFilter, sort: \QuestCache.weekOf, order: .reverse)
        _cachedCompletions = Query(filter: completionFilter, sort: \QuestCompletionCache.completedDate, order: .reverse)
        _cachedLedgers = Query(filter: ledgerFilter, sort: \LedgerEntryCache.date, order: .reverse)
        _cachedAllowancePeriods = Query(filter: allowanceFilter, sort: \AllowancePeriodCache.weekOf, order: .reverse)
        _cachedAchievements = Query(filter: achievementFilter, sort: \AchievementCache.name)
        _cachedProfileAchievements = Query(filter: profileAchievementFilter, sort: \ProfileAchievementCache.earnedDate, order: .reverse)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "house.fill")
                    .foregroundStyle(.tint)
                if isEditingFamilyName {
                    TextField("Family name", text: $draftFamilyName)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("settings.familyNameField")
                } else {
                    Text(appState.family?.name ?? "—")
                        .font(.body.weight(.semibold))
                }
                Spacer()
                if appState.currentProfile?.role == .guildMaster {
                    if isEditingFamilyName {
                        Button("Save") {
                            Task { await saveFamilyName() }
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("settings.familyNameSave")
                    } else {
                        Button("Edit") {
                            draftFamilyName = appState.family?.name ?? ""
                            isEditingFamilyName = true
                        }
                        .accessibilityIdentifier("settings.familyNameEdit")
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            if appState.currentProfile?.role == .guildMaster {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Guild Invitations")
                            .font(.subheadline.weight(.semibold))
                        Text("Invite a Hero or Co-Parent to your guild")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        showRolePicker = true
                    } label: {
                        Label("Invite Members", systemImage: "person.badge.plus")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("settings.inviteMembers")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(DesignSystemConstants.Colors.cardSurface))
        )
        .padding(.horizontal)
        .task {
            ensureViewModel()
        }
        .onChange(of: cachedProfiles) { _, _ in
            rebuildViewModel()
        }
        .onChange(of: cachedQuests) { _, _ in rebuildViewModel() }
        .onChange(of: cachedCompletions) { _, _ in rebuildViewModel() }
        .onChange(of: cachedLedgers) { _, _ in rebuildViewModel() }
        .onChange(of: cachedAllowancePeriods) { _, _ in rebuildViewModel() }
        .onChange(of: cachedAchievements) { _, _ in rebuildViewModel() }
        .onChange(of: cachedProfileAchievements) { _, _ in rebuildViewModel() }
        .sheet(isPresented: $showRolePicker) {
            InviteRolePickerView { role in
                await presentInviteShare(for: role)
            }
        }
        .sheet(item: $sharePresentation) { presentation in
            CloudSharingControllerWrapper(presentation: presentation)
        }
    }

    private func ensureViewModel() {
        ViewLifecycle.ensureAndRebuild(&viewModel, factory: {
            FamilyDashboardViewModel(
                questService: questService,
                treasury: treasury,
                achievementService: achievementService,
                familyService: familyService,
                appState: appState
            )
        }, rebuild: { vm in rebuildViewModel(vm) })
    }

    private func rebuildViewModel(_ vm: FamilyDashboardViewModel? = nil) {
        guard let targetVM = vm ?? viewModel else { return }
        targetVM.rebuildLists(
            profiles: cachedProfiles,
            quests: cachedQuests,
            logs: cachedCompletions,
            ledgers: cachedLedgers,
            allowancePeriods: cachedAllowancePeriods,
            profileAchievements: cachedProfileAchievements,
            achievements: cachedAchievements
        )
    }

    @MainActor
    private func saveFamilyName() async {
        guard let family = appState.family else { return }
        let trimmed = draftFamilyName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            isEditingFamilyName = false
            return
        }
        do {
            try await familyService.updateFamilyName(family: family, newName: trimmed)
            isEditingFamilyName = false
        } catch {
            logger.error("Failed to rename family: \(error, privacy: .private)")
            toastManager.show(message: "Could not rename the family. Please try again.", type: .error)
        }
    }

    @MainActor
    private func presentInviteShare(for role: UserRole) async {
        guard let presentation = await viewModel?.prepareInviteShare(for: role) else {
            toastManager.show(message: "Could not create an invitation. Please try again.", type: .error)
            return
        }
        guard presentation.shareURL != nil else {
            toastManager.show(message: "Could not generate a share link for this invitation. Please try again.", type: .error)
            return
        }
        sharePresentation = presentation
    }
}

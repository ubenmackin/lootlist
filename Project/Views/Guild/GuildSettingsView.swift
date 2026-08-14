//
//  GuildSettingsView.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import os
import SwiftData
import SwiftUI

struct GuildSettingsView: View {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "GuildSettings")

    @Environment(ToastManager.self) private var toastManager
    @Environment(AppState.self) private var appState
    @Environment(CloudKitService.self) private var cloudKitService
    @Environment(QuestService.self) private var questService
    @Environment(TreasuryService.self) private var treasury
    @Environment(AchievementService.self) private var achievementService
    @Environment(FamilyService.self) private var familyService

    @State private var viewModel: FamilyDashboardViewModel?

    @Query private var cachedProfiles: [ProfileCache]
    @Query private var cachedQuests: [QuestCache]
    @Query private var cachedCompletions: [QuestCompletionCache]
    @Query private var cachedLedgers: [LedgerEntryCache]
    @Query private var cachedAllowancePeriods: [AllowancePeriodCache]
    @Query private var cachedAchievements: [AchievementCache]
    @Query private var cachedProfileAchievements: [ProfileAchievementCache]

    @State private var draftFamilyName: String = ""
    @State private var isEditingFamilyName: Bool = false

    @State private var showRolePicker: Bool = false
    @State private var sharePresentation: CloudSharePresentation?
    @State private var heroToEdit: ProfileCache?

    @State private var showRoleTransferConfirm: ProfileCache?
    @State private var memberToKick: ProfileCache?
    @State private var invitationToRevoke: FamilyInvitation?
    @State private var showDisbandConfirm: Bool = false
    @State private var showDisbandFinalConfirm: Bool = false
    @State private var showLeaveConfirm: Bool = false

    @State private var actionError: String?
    @State private var revokeError: String?

    @State private var isSigningOut: Bool = false

    private let familyRecordName: String?

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

        _cachedProfiles = Query(filter: profileFilter, sort: \ProfileCache.displayName)
        _cachedQuests = Query(filter: questFilter, sort: \QuestCache.weekOf, order: .reverse)
        _cachedCompletions = Query(filter: completionFilter, sort: \QuestCompletionCache.completedDate, order: .reverse)
        _cachedLedgers = Query(filter: ledgerFilter, sort: \LedgerEntryCache.date, order: .reverse)
        _cachedAllowancePeriods = Query(filter: allowanceFilter, sort: \AllowancePeriodCache.weekOf, order: .reverse)
        _cachedAchievements = Query(filter: achievementFilter, sort: \AchievementCache.name)
        _cachedProfileAchievements = Query(filter: profileAchievementFilter, sort: \ProfileAchievementCache.earnedDate, order: .reverse)
    }

    @State private var isRoleTransferConfirmPresented: Bool = false
    @State private var isPayoutPolicyExpanded: Bool = false

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
            .navigationTitle("Guild Settings")
            .navigationBarTitleDisplayMode(.large)
            .refreshable { await viewModel?.refresh() }
            .task {
                if viewModel == nil {
                    viewModel = FamilyDashboardViewModel(
                        questService: questService,
                        treasury: treasury,
                        achievementService: achievementService,
                        familyService: familyService,
                        appState: appState
                    )
                }
                rebuildViewModel()
                await viewModel?.refresh()
                rebuildViewModel()
                // Load the CKShare participants so the Invitations panel is
                // populated the first time the screen appears.
                await viewModel?.refreshInvitations()
            }
            .onChange(of: sharePresentation?.id) { _, newID in
                // New participants may have been added (or an invite revoked)
                // via the share sheet; refresh the Invitations panel on dismiss.
                if newID == nil, sharePresentation == nil {
                    Task {
                        await viewModel?.refreshInvitations()
                    }
                }
            }
            .onChange(of: cachedProfiles) { _, _ in
                rebuildViewModel()
                // The Invitations panel classifies `CKShare` participants
                // against the member roster (`heroes` + `parents`). A roster
                // change — a hero accepting an invite, a member being kicked or
                // deactivated — invalidates that classification, so re-run it
                // here instead of leaving stale revocable rows lingering until
                // the next share-sheet dismiss.
                Task { await viewModel?.refreshInvitations() }
            }
            .onChange(of: cachedQuests) { _, _ in
                rebuildViewModel()
            }
            .onChange(of: cachedCompletions) { _, _ in
                rebuildViewModel()
            }
            .onChange(of: cachedLedgers) { _, _ in
                rebuildViewModel()
            }
            .onChange(of: cachedAllowancePeriods) { _, _ in
                rebuildViewModel()
            }
            .onChange(of: cachedAchievements) { _, _ in
                rebuildViewModel()
            }
            .onChange(of: cachedProfileAchievements) { _, _ in
                rebuildViewModel()
            }
            .sheet(isPresented: $showRolePicker) {
                InviteRolePickerView { role in
                    await presentInviteShare(for: role)
                }
            }
            .sheet(item: $sharePresentation) { presentation in
                CloudSharingControllerWrapper(share: presentation.share, container: presentation.container)
            }
            .sheet(item: $heroToEdit) { hero in
                let zoneID = questService.cloudKitReference.resolvedZoneID
                HeroSettingsView(hero: hero.toProfile(zoneID: zoneID))
                    .onDisappear {
                        Task { await viewModel?.refresh() }
                    }
            }
            .onChange(of: actionError) { _, newError in
                if let error = newError {
                    toastManager.show(message: error, type: .error)
                    actionError = nil
                }
            }
            .onChange(of: viewModel?.loadError) { _, newError in
                // Revocation failures from the Invitations panel set the view
                // model's `loadError`; surface it so a failed share revocation
                // is never a silent no-op that leaves a departed identity with
                // live access. Toasts are transient, so also flag an unmissable
                // alert — the reached copy tells the GM to retry.
                if let error = newError {
                    toastManager.show(message: error, type: .error)
                    revokeError = error
                }
            }
            .alert("Revoke Failed",
                   isPresented: Binding(
                       get: { revokeError != nil },
                       set: {
                           if !$0 {
                               revokeError = nil
                           }
                       }
                   )) {
                Button("OK", role: .cancel) { revokeError = nil }
            } message: {
                Text(revokeError ?? "Could not revoke access. Please try again.")
            }
            .alert("Transfer Guild Master Role?",
                   isPresented: $isRoleTransferConfirmPresented)
            {
                Button("Transfer Ownership", role: .destructive) {
                    if let target = showRoleTransferConfirm {
                        Task { await confirmTransferGuildMaster(to: target) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\(showRoleTransferConfirm?.displayName ?? "member") will become the Guild Master. You will become a Ranger.")
            }
            .overlay {
                if isSigningOut {
                    ProgressView("Signing out…")
                        .padding(24)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
            }
        }
    }

    private func rebuildViewModel() {
        guard let vm = viewModel else { return }
        vm.rebuildLists(
            profiles: cachedProfiles,
            quests: cachedQuests,
            logs: cachedCompletions,
            ledgers: cachedLedgers,
            allowancePeriods: cachedAllowancePeriods,
            profileAchievements: cachedProfileAchievements,
            achievements: cachedAchievements
        )
    }

    @ViewBuilder
    private func loadedContent(vm: FamilyDashboardViewModel) -> some View {
        familyHeaderSection
        membersSection(vm: vm)
        if appState.currentProfile?.role == .guildMaster {
            invitationsSection(vm: vm)
            payoutSettingsSection
        }
        if let currentRole = appState.currentProfile?.role, currentRole != .guildMaster {
            leaveFamilySection
        }
        if let currentRole = appState.currentProfile?.role, currentRole == .guildMaster {
            deleteFamilySection
        }
    }
}

private extension GuildSettingsView {
    private var familyHeaderSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "house.fill")
                    .foregroundStyle(.tint)
                if isEditingFamilyName {
                    TextField("Family name",
                              text: $draftFamilyName)
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

            // Invites are Guild-Master-only (AD-5): only the zone owner can
            // mint a share, so exposing this to Rangers would be a dead affordance.
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
        .background(cardBackground)
        .padding(.horizontal)
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
            actionError = nil
        } catch {
            logger.error("Failed to rename family: \(error, privacy: .private)")
            actionError = "Could not rename the family. Please try again."
        }
    }

    @MainActor
    private func presentInviteShare(for role: UserRole) async {
        guard let share = await viewModel?.prepareInviteShare(for: role) else {
            toastManager.show(message: "Could not create an invitation. Please try again.", type: .error)
            return
        }
        sharePresentation = CloudSharePresentation(share: share, container: cloudKitService.container)
    }

    private var payoutSettingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Allowance & Payout Defaults")
                .font(.headline)
                .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 14) {
                // Payout Day Picker
                HStack {
                    Label("Weekly Payout Day", systemImage: "calendar.badge.clock")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Picker("Payout Day", selection: Binding(
                        get: { appState.family?.payoutDay ?? .sunday },
                        set: { newDay in
                            if let family = appState.family {
                                Task {
                                    do {
                                        try await familyService.updatePayoutDay(family: family, day: newDay)
                                    } catch {
                                        toastManager.show(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, type: .error)
                                    }
                                }
                            }
                        }
                    )) {
                        ForEach(PayoutDay.allCases) { day in
                            Text(day.displayName).tag(day)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            .padding(14)
            .background(cardBackground)

            // Collapsible Default Payout Policy Radio Cards
            VStack(alignment: .leading, spacing: 10) {
                DisclosureGroup(
                    isExpanded: $isPayoutPolicyExpanded,
                    content: {
                        VStack(spacing: 10) {
                            ForEach(PayoutPolicy.allCases, id: \.self) { policy in
                                familyPayoutPolicyOptionRow(policy: policy)
                            }
                        }
                        .padding(.top, 10)
                    },
                    label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Default Payout Policy")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.primary)
                                Text(appState.family?.payoutPolicy.displayName ?? "Pay Per Quest (Standard)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                )
            }
            .padding(14)
            .background(cardBackground)
        }
        .padding(.horizontal)
    }

    private func familyPayoutPolicyOptionRow(policy: PayoutPolicy) -> some View {
        let currentPolicy = appState.family?.payoutPolicy ?? .perQuest
        let isSelected = currentPolicy == policy
        return Button {
            if !isSelected, let family = appState.family {
                Task {
                    do {
                        _ = try await familyService.updatePayoutPolicy(family: family, policy: policy)
                    } catch {
                        toastManager.show(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, type: .error)
                    }
                }
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: policy.iconSystemName)
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        Text(policy.displayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.primary)
                    }

                    Text(policy.subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.tertiarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.8) : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func membersSection(vm: FamilyDashboardViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Members")
                    .font(.headline)
                Spacer()
                Text("\(vm.heroes.count + vm.parents.count)")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)

            VStack(spacing: 0) {
                ForEach(vm.parents) { member in
                    memberRow(member, vm: vm)
                    Divider().padding(.leading, 56)
                }
                ForEach(vm.heroes) { member in
                    memberRow(member, vm: vm)
                    Divider().padding(.leading, 56)
                }
            }
            .background(cardBackground)
            .padding(.horizontal)
            .alert("Remove \(memberToKick?.displayName ?? "Member")?", isPresented: Binding(
                get: { memberToKick != nil },
                set: {
                    if !$0 {
                        memberToKick = nil
                    }
                }
            )) {
                Button("Remove", role: .destructive) {
                    if let member = memberToKick {
                        Task { await kickMember(member) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This member will lose access to all guild quests, loot history, and weekly allowances.")
            }
        }
    }

    /// Invitation and departed-member rows from the family's `CKShare` participant
    /// list, backed by `FamilyDashboardViewModel.invitations`. A Guild Master
    /// can revoke a pending invite, and must revoke a departed member whose
    /// deactivated `Profile` still holds share access — a non-owner self-leave
    /// cannot remove its own participant entry from the share it does not own.
    private func invitationsSection(vm: FamilyDashboardViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Invitations")
                    .font(.headline)
                Spacer()
                if !vm.invitations.isEmpty {
                    Text("\(vm.invitations.count)")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)

            if vm.invitations.isEmpty {
                Text("No pending invitations")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(cardBackground)
                    .padding(.horizontal)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(vm.invitations.enumerated()), id: \.element.id) { index, invitation in
                        invitationRow(invitation, vm: vm)
                        if index < vm.invitations.count - 1 {
                            Divider().padding(.leading, 44)
                        }
                    }
                }
                .background(cardBackground)
                .padding(.horizontal)
            }
        }
        .alert("Revoke \(invitationToRevoke?.identity ?? "Invitation")?",
               isPresented: Binding(
                   get: { invitationToRevoke != nil },
                   set: {
                       if !$0 {
                           invitationToRevoke = nil
                       }
                   }
               )) {
            Button("Revoke", role: .destructive) {
                if let invitation = invitationToRevoke {
                    Task { await vm.revokeInvitation(invitation) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(revokeConfirmationMessage)
        }
    }

    /// Tailors the revoke confirmation to the row kind: a pending invite has no
    /// access yet (revoking prevents them from ever joining), while a departed
    /// member already lost their `Profile` and the revoke closes their lingering
    /// share access.
    private var revokeConfirmationMessage: String {
        switch invitationToRevoke?.kind {
        case .departedMember:
            "This member already left the guild. Revoking removes their remaining share access so they can no longer read this family's data."
        case .pendingInvite:
            "This invitation has not been accepted. Revoking it will prevent this person from joining the guild."
        default:
            "This will remove the member's access to the guild."
        }
    }

    private func invitationRow(_ invitation: FamilyInvitation, vm _: FamilyDashboardViewModel) -> some View {
        HStack(spacing: 12) {
            Image(systemName: Self.invitationIcon(for: invitation.kind))
                .font(.title3)
                .foregroundStyle(Self.invitationTint(for: invitation.kind))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(invitation.identity)
                        .font(.body.weight(.semibold))

                    if let role = invitation.targetRole {
                        roleBadge(for: role)
                    }
                }
                Text(invitation.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if invitation.kind != .removedIdentity {
                Button(role: .destructive) {
                    invitationToRevoke = invitation
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.red.opacity(0.7))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.revokeInvite-\(invitation.id)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private func roleBadge(for role: UserRole) -> some View {
        HStack(spacing: 4) {
            Image(systemName: role.iconSystemName)
                .font(.caption2.weight(.bold))
            Text(role.displayName)
                .font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(role == .ranger ? Color.gold.opacity(0.20) : Color.blue.opacity(0.15))
        )
        .foregroundStyle(role == .ranger ? Color.gold : Color.blue)
    }

    private static func invitationIcon(for kind: FamilyInvitationKind) -> String {
        switch kind {
        case .pendingInvite: "envelope.fill"
        case .departedMember: "person.fill.xmark"
        case .removedIdentity: "person.crop.circle.badge.xmark"
        }
    }

    private static func invitationTint(for kind: FamilyInvitationKind) -> Color {
        switch kind {
        case .pendingInvite: .blue
        case .departedMember: .orange
        case .removedIdentity: .secondary
        }
    }

    private func memberRow(_ member: ProfileCache, vm: FamilyDashboardViewModel) -> some View {
        let role = member.roleEnum ?? .hero
        return HStack(spacing: 12) {
            memberAvatarView(member)
            VStack(alignment: .leading, spacing: 2) {
                Text(member.displayName)
                    .font(.body.weight(.semibold))
                Text(role.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            roleManagementMenu(member, vm: vm)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private func memberAvatarView(_ member: ProfileCache) -> some View {
        let zoneID = questService.cloudKitReference.resolvedZoneID
        return ProfileAvatarView(profile: member.toProfile(zoneID: zoneID))
    }

    @ViewBuilder
    private func roleManagementMenu(_ member: ProfileCache, vm _: FamilyDashboardViewModel) -> some View {
        let isCurrent = appState.currentProfile?.id.recordName == member.recordName
        let role = member.roleEnum
        if appState.currentProfile?.role == .guildMaster, !isCurrent {
            Menu {
                if role == .hero {
                    Button {
                        heroToEdit = member
                    } label: {
                        Label("Hero Settings…", systemImage: "slider.horizontal.3")
                    }
                } else if role == .ranger {
                    Button {
                        showRoleTransferConfirm = member
                    } label: {
                        Label("Transfer Guild Master…",
                              systemImage: "crown.fill")
                    }
                }

                Divider()

                Button(role: .destructive) {
                    memberToKick = member
                } label: {
                    Label("Remove from Guild", systemImage: "person.crop.circle.badge.xmark")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(.tint)
            }
            .accessibilityIdentifier("settings.roleMenu-\(member.recordName)")
        } else if isCurrent {
            Text("You")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @MainActor
    private func kickMember(_ member: ProfileCache) async {
        let zoneID = questService.cloudKitReference.resolvedZoneID
        do {
            let result = try await familyService.kickMember(profile: member.toProfile(zoneID: zoneID))
            await viewModel?.refresh()
            rebuildViewModel()
            // A partial failure means the member is removed from the roster but
            // their share access could not be revoked. Surface it (via the
            // existing `actionError` toast path) so the GM knows to close the
            // lingering access from the Invitations panel — a silent log-only
            // failure left a deactivated identity with live read access.
            if case .partialRevocationFailed = result {
                actionError = "Member removed, but their share access could not be revoked. Revoke it in Invitations."
            } else {
                actionError = nil
            }
        } catch {
            logger.error("Failed to remove member: \(error, privacy: .private)")
            actionError = "Could not remove the member. Please try again."
        }
    }

    @MainActor
    private func confirmTransferGuildMaster(to newOwner: ProfileCache) async {
        guard let current = appState.currentProfile else { return }
        let zoneID = questService.cloudKitReference.resolvedZoneID
        do {
            try await familyService.updateMemberRole(profile: newOwner.toProfile(zoneID: zoneID), newRole: .guildMaster)
            try await familyService.updateMemberRole(profile: current, newRole: .ranger)
            if appState.currentProfile?.id == current.id {
                var updated = current
                updated.role = .ranger
                appState.currentProfile = updated
            }
            await viewModel?.refresh()
            showRoleTransferConfirm = nil
            actionError = nil
        } catch {
            logger.error("Failed to transfer Guild Master: \(error, privacy: .private)")
            actionError = "Could not transfer Guild Master. Please try again."
        }
    }

    private func roleColor(_ role: UserRole) -> Color {
        switch role {
        case .guildMaster: .purple
        case .ranger: .teal
        case .hero: .blue
        }
    }

    private var leaveFamilySection: some View {
        VStack(spacing: 0) {
            Button(role: .destructive) {
                showLeaveConfirm = true
            } label: {
                Label("Leave Family", systemImage: "rectangle.portrait.and.arrow.right")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.leaveFamily")
        }
        .background(cardBackground)
        .padding(.horizontal)
        .alert("Leave Family?", isPresented: $showLeaveConfirm) {
            Button("Leave", role: .destructive) {
                Task { await leaveFamily() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your profile will be marked inactive. Your Guild's history stays synced in iCloud.")
        }
    }

    @MainActor
    private func leaveFamily() async {
        guard let current = appState.currentProfile else { return }
        do {
            try await familyService.leaveFamily(profile: current)
            isSigningOut = true
            await appState.signOutAndDiscover(cloudKit: cloudKitService)
            isSigningOut = false
        } catch {
            logger.error("Failed to leave family: \(error, privacy: .private)")
            actionError = "Could not leave the family. Please try again."
        }
    }

    private var deleteFamilySection: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Danger Zone")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.red)
                Spacer()
            }
            .padding(.horizontal, 16)

            VStack(spacing: 0) {
                Button(role: .destructive) {
                    showDisbandConfirm = true
                } label: {
                    Label("Delete Family & Reset App", systemImage: "trash.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.disbandFamily")
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.red.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.red.opacity(0.35), lineWidth: 1)
            )
            .padding(.horizontal)
        }
        .alert("Delete Family & Reset App?", isPresented: $showDisbandConfirm) {
            Button("Continue", role: .destructive) {
                showDisbandFinalConfirm = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This will permanently delete your family zone, quest history, loot, and member profiles from iCloud, returning you to the onboarding screen. This cannot be undone."
            )
        }
        .alert("Final Confirmation", isPresented: $showDisbandFinalConfirm) {
            Button("Delete Forever & Start Fresh", role: .destructive) {
                Task { await deleteFamilyAndReset() }
            }
            Button("Keep Family", role: .cancel) {}
        } message: {
            Text("Are you sure you want to permanently erase \(appState.family?.name ?? "this family") and start over from onboarding?")
        }
    }

    @MainActor
    private func deleteFamilyAndReset() async {
        guard let family = appState.family else {
            appState.clearSession()
            return
        }

        do {
            try await familyService.deleteFamilyAndReset(family: family)
        } catch {
            logger.error("Failed to delete family zone: \(error, privacy: .private)")
            appState.clearSession()
        }
    }

    private var loadingPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "gear")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)
                .padding(.top, 120)
            Text("Loading guild settings…")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground))
    }
}

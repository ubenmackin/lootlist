//
//  GuildSettingsView.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import SwiftUI

struct GuildSettingsView: View {
    @Environment(ToastManager.self) private var toastManager
    @Environment(AppState.self) private var appState
    @Environment(QuestService.self) private var questService
    @Environment(TreasuryService.self) private var treasury
    @Environment(AchievementService.self) private var achievementService
    @Environment(FamilyService.self) private var familyService

    @State private var viewModel: FamilyDashboardViewModel?

    @State private var draftFamilyName: String = ""
    @State private var isEditingFamilyName: Bool = false

    @State private var showShareSheet: Bool = false
    @State private var heroToEdit: ProfileCache?

    @State private var showRoleTransferConfirm: ProfileCache?
    @State private var memberToKick: ProfileCache?
    @State private var showDisbandConfirm: Bool = false
    @State private var showDisbandFinalConfirm: Bool = false
    @State private var showLeaveConfirm: Bool = false

    @State private var actionError: String?

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
                await viewModel?.refresh()
            }
            .sheet(isPresented: $showShareSheet) {
                ShareSheet(items: shareInviteItems)
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
            .alert("Transfer Guild Master Role?",
                   isPresented: Binding(
                       get: { showRoleTransferConfirm != nil },
                       set: {
                           if !$0 {
                               showRoleTransferConfirm = nil
                           }
                       }
                   )) {
                if let target = showRoleTransferConfirm {
                    Button("Transfer Ownership", role: .destructive) {
                        Task { await confirmTransferGuildMaster(to: target) }
                    }
                    Button("Cancel", role: .cancel) {}
                }
            } message: {
                if let target = showRoleTransferConfirm {
                    Text("\(target.displayName) will become the Guild Master. You will become a Ranger.")
                }
            }
        }
    }

    @ViewBuilder
    private func loadedContent(vm: FamilyDashboardViewModel) -> some View {
        familyNameSection(vm: vm)
        inviteLinkSection
        if appState.currentProfile?.role == .guildMaster {
            payoutSettingsSection
        }
        membersSection(vm: vm)
        if let currentRole = appState.currentProfile?.role, currentRole != .guildMaster {
            leaveFamilySection
        }
        if let currentRole = appState.currentProfile?.role, currentRole == .guildMaster {
            deleteFamilySection
        }
    }
}

private extension GuildSettingsView {
    private func familyNameSection(vm _: FamilyDashboardViewModel) -> some View {
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
            actionError = "Could not rename family: \(error)"
        }
    }

    private var inviteLinkSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Guild Invitation Link")
                        .font(.subheadline.weight(.semibold))
                    Text("Invite heroes and members to join your family guild")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task {
                        await viewModel?.ensureActiveShareURL()
                        showShareSheet = true
                    }
                } label: {
                    Label("Share Link", systemImage: "square.and.arrow.up")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("settings.inviteShare")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .background(cardBackground)
        .padding(.horizontal)
    }

    private var shareInviteItems: [Any] {
        appState.shareInviteItems
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

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Default Payout Policy")
                        .font(.subheadline.weight(.semibold))
                    Text("New heroes added to the guild will inherit this policy by default.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(PayoutPolicy.allCases, id: \.self) { policy in
                        Button {
                            Task {
                                if let family = appState.family {
                                    do {
                                        _ = try await familyService.updatePayoutPolicy(family: family, policy: policy)
                                    } catch {
                                        toastManager.show(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, type: .error)
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: policy.iconSystemName)
                                    .foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(policy.displayName)
                                        .font(.body.weight(.semibold))
                                    Text(policy.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if policy == (appState.family?.payoutPolicy ?? .perQuest) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)

                        if policy != PayoutPolicy.allCases.last {
                            Divider()
                        }
                    }
                }
            }
            .padding(14)
            .background(cardBackground)
        }
        .padding(.horizontal)
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

    private func memberRow(_ member: ProfileCache, vm: FamilyDashboardViewModel) -> some View {
        let role = member.roleEnum ?? .hero
        return HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(roleColor(role).opacity(0.16))
                    .frame(width: 36, height: 36)
                Image(systemName: role.iconSystemName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(roleColor(role))
            }
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

                    Button {
                        Task { await changeRole(member, to: .ranger) }
                    } label: {
                        Label("Promote to Ranger", systemImage: "arrow.up.circle")
                    }
                } else if role == .ranger {
                    Button {
                        Task { await changeRole(member, to: .hero) }
                    } label: {
                        Label("Demote to Hero", systemImage: "arrow.down.circle")
                    }
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
            try await familyService.kickMember(profile: member.toProfile(zoneID: zoneID))
            await viewModel?.refresh()
            actionError = nil
        } catch {
            actionError = "Could not remove member: \(error)"
        }
    }

    @MainActor
    private func changeRole(_ member: ProfileCache, to newRole: UserRole) async {
        let zoneID = questService.cloudKitReference.resolvedZoneID
        do {
            try await familyService.updateMemberRole(profile: member.toProfile(zoneID: zoneID), newRole: newRole)
            await viewModel?.refresh()
            actionError = nil
        } catch {
            actionError = "Could not change role: \(error)"
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
            actionError = "Could not transfer Guild Master: \(error)"
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
            appState.signOut()
        } catch {
            actionError = "Could not leave family: \(error)"
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
            print("Failed to delete family zone: \(error)")
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

import CloudKit
import SwiftUI

struct GuildSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(QuestService.self) private var questService
    @Environment(TreasuryService.self) private var treasury
    @Environment(AchievementService.self) private var achievementService
    @Environment(FamilyService.self) private var familyService

    @State private var viewModel: FamilyDashboardViewModel?

    @State private var draftFamilyName: String = ""
    @State private var isEditingFamilyName: Bool = false

    @State private var showShareSheet: Bool = false

    @State private var showRoleTransferConfirm: Profile?
    @State private var memberToKick: Profile?
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
                        appState: appState
                    )
                }
                await viewModel?.refresh()
            }
            .sheet(isPresented: $showShareSheet) {
                ShareSheet(items: shareInviteItems)
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
        payoutPolicySection(vm: vm)
        membersSection(vm: vm)
        if let currentRole = appState.currentProfile?.role, currentRole != .guildMaster {
            leaveFamilySection
        }
        if let currentRole = appState.currentProfile?.role, currentRole == .guildMaster {
            deleteFamilySection
        }
        if let error = actionError {
            Text(error)
                .font(.footnote)
                .foregroundStyle(.red)
                .padding(.horizontal)
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
                    showShareSheet = true
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

    private func payoutPolicySection(vm: FamilyDashboardViewModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Weekly Allowance Payout Rules")
                .font(.headline)
            Text("Set rules per hero. Pay Per Quest pays gold for every completed quest. All-or-Nothing requires 100% completion for Sunday payout.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if vm.heroes.isEmpty {
                Text("No hero profiles in the family.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(cardBackground)
            } else {
                VStack(spacing: 8) {
                    ForEach(vm.heroes) { hero in
                        heroPayoutPolicyRow(hero: hero)
                    }
                }
            }
        }
        .padding(.horizontal)
    }

    private func heroPayoutPolicyRow(hero: Profile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "person.circle.fill")
                    .foregroundStyle(.tint)
                Text(hero.displayName)
                    .font(.body.weight(.semibold))
                Spacer()
            }

            Picker("Payout Rule", selection: Binding(
                get: { hero.payoutPolicy },
                set: { newPolicy in
                    Task { await updateHeroPayoutPolicy(hero: hero, newPolicy: newPolicy) }
                }
            )) {
                ForEach(PayoutPolicy.allCases, id: \.self) { policy in
                    Text(policy == .perQuest ? "Pay Per Quest" : "All-or-Nothing (100%)").tag(policy)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(14)
        .background(cardBackground)
    }

    @MainActor
    private func updateHeroPayoutPolicy(hero: Profile, newPolicy: PayoutPolicy) async {
        do {
            try await familyService.updateProfilePayoutPolicy(profile: hero, policy: newPolicy)
            await viewModel?.refresh()
            actionError = nil
        } catch {
            actionError = "Could not update payout policy for \(hero.displayName): \(error)"
        }
    }

    private var shareInviteItems: [Any] {
        let name = appState.family?.name ?? "our guild"
        if let shareURL = appState.activeShareURL {
            let message = "Join \(name) on LootList! Tap the link to join our guild:\n\(shareURL.absoluteString)"
            return [message, shareURL]
        } else {
            let message = "Join \(name) on LootList!"
            return [message]
        }
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

    private func memberRow(_ member: Profile, vm: FamilyDashboardViewModel) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(roleColor(member.role).opacity(0.16))
                    .frame(width: 36, height: 36)
                Image(systemName: member.role.iconSystemName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(roleColor(member.role))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(member.displayName)
                    .font(.body.weight(.semibold))
                Text(member.role.displayName)
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
    private func roleManagementMenu(_ member: Profile, vm _: FamilyDashboardViewModel) -> some View {
        let isCurrent = appState.currentProfile?.id == member.id
        if appState.currentProfile?.role == .guildMaster, !isCurrent {
            Menu {
                if member.role == .hero {
                    Button {
                        Task { await changeRole(member, to: .ranger) }
                    } label: {
                        Label("Promote to Ranger", systemImage: "arrow.up.circle")
                    }
                } else if member.role == .ranger {
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
            .accessibilityIdentifier("settings.roleMenu-\(member.id.recordName)")
        } else if isCurrent {
            Text("You")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @MainActor
    private func kickMember(_ member: Profile) async {
        do {
            try await familyService.kickMember(profile: member)
            await viewModel?.refresh()
            actionError = nil
        } catch {
            actionError = "Could not remove member: \(error)"
        }
    }

    @MainActor
    private func changeRole(_ member: Profile, to newRole: UserRole) async {
        do {
            try await familyService.updateMemberRole(profile: member, newRole: newRole)
            await viewModel?.refresh()
            actionError = nil
        } catch {
            actionError = "Could not change role: \(error)"
        }
    }

    @MainActor
    private func confirmTransferGuildMaster(to newOwner: Profile) async {
        guard let current = appState.currentProfile else { return }
        do {
            try await familyService.updateMemberRole(profile: newOwner, newRole: .guildMaster)
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
        guard let family = appState.family else { return }

        let vm = viewModel
        let allMembers = (vm?.heroes ?? []) + (vm?.parents ?? [])
        for member in allMembers {
            try? await familyService.leaveFamily(profile: member)
        }

        try? await familyService.deleteFamilyAndReset(family: family)
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

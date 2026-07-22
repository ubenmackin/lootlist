import SwiftUI
import CloudKit

struct GuildSettingsView: View {

    @Environment(AppState.self) private var appState
    @Environment(QuestService.self) private var questService
    @Environment(TreasuryService.self) private var treasury
    @Environment(AchievementService.self) private var achievementService
    @Environment(FamilyService.self) private var familyService

    @State private var viewModel: FamilyDashboardViewModel?

    @State private var draftFamilyName: String = ""
    @State private var isEditingFamilyName: Bool = false

    @State private var showCopiedToast: Bool = false
    @State private var showShareSheet: Bool = false

    @State private var showRoleTransferConfirm: Profile?
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
                if let family = appState.family, draftFamilyName.isEmpty {
                    draftFamilyName = family.name
                }
            }
            .sheet(isPresented: $showShareSheet) {
                if let family = appState.family {
                    ShareSheet(items: [shareInviteText(for: family)])
                }
            }
            .alert("Transfer Guild Master?",
                   isPresented: Binding(
                       get: { showRoleTransferConfirm != nil },
                       set: { if !$0 { showRoleTransferConfirm = nil } }
                   )) {
                Button("Transfer", role: .destructive) {
                    if let candidate = showRoleTransferConfirm {
                        Task { await confirmTransferGuildMaster(to: candidate) }
                    }
                }
                Button("Cancel", role: .cancel) {
                    showRoleTransferConfirm = nil
                }
            } message: {
                if let candidate = showRoleTransferConfirm {
                    Text("Hand the Guild Master title to \(candidate.displayName)? You will become a Ranger.")
                }
            }
        }
    }

    @ViewBuilder
    private func loadedContent(vm: FamilyDashboardViewModel) -> some View {
        familyNameSection(vm: vm)
        inviteCodeSection
        membersSection(vm: vm)
        leaveFamilySection
        if let currentRole = appState.currentProfile?.role, currentRole == .guildMaster {
            disbandFamilySection
        }
        if let error = actionError {
            Text(error)
                .font(.footnote)
                .foregroundStyle(.red)
                .padding(.horizontal)
        }
    }

    private func familyNameSection(vm: FamilyDashboardViewModel) -> some View {
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
        let trimmed = draftFamilyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            actionError = "Family name cannot be empty."
            isEditingFamilyName = false
            return
        }
        var updated = family
        updated.name = trimmed
        do {

            let saved = try await questService.cloudKitReference.save(updated)
            appState.family = saved
            isEditingFamilyName = false
            actionError = nil
        } catch {
            actionError = "Could not rename family: \(error)"
        }
    }

    private var inviteCodeSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Invite Code")
                        .font(.subheadline.weight(.semibold))
                    Text(appState.family?.inviteCode ?? "—")
                        .font(.title3.weight(.bold).monospaced())
                }
                Spacer()
                Button {
                    UIPasteboard.general.string = appState.family?.inviteCode ?? ""
                    DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                        if UIPasteboard.general.string == appState.family?.inviteCode {
                            UIPasteboard.general.string = nil
                        }
                    }
                    showCopiedToast = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        await MainActor.run { showCopiedToast = false }
                    }
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("settings.inviteCopy")

                Button {
                    showShareSheet = true
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("settings.inviteShare")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            if showCopiedToast {
                Text("Copied to clipboard")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }

            if appState.currentProfile?.role == .guildMaster {
                Divider().padding(.leading, 14)
                Button {
                    Task { await regenerateInviteCode() }
                } label: {
                    Label("Regenerate Invite Code",
                            systemImage: "arrow.clockwise.circle")
                        .font(.subheadline)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .accessibilityIdentifier("settings.inviteRegenerate")
            }
        }
        .background(cardBackground)
        .padding(.horizontal)
        .animation(.easeInOut(duration: 0.25), value: showCopiedToast)
    }

    @MainActor
    private func regenerateInviteCode() async {
        guard let family = appState.family else { return }

        let freshSeed = UUID().uuidString
        let newCode = FamilyService.generateInviteCode(seed: freshSeed)
        var updated = family
        updated.inviteCode = newCode
        do {
            let saved = try await questService.cloudKitReference.save(updated)
            appState.family = saved
            actionError = nil
        } catch {
            actionError = "Could not regenerate invite code: \(error)"
        }
    }

    private func shareInviteText(for family: Family) -> String {
        "Join \(family.name) on QuestLog! Your invite code: \(family.inviteCode)"
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
    private func roleManagementMenu(_ member: Profile, vm: FamilyDashboardViewModel) -> some View {
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
        case .guildMaster: return .purple
        case .ranger:      return .teal
        case .hero:        return .blue
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

    private var disbandFamilySection: some View {
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
                    Label("Disband Family", systemImage: "trash.fill")
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

        .alert("Disband Family?", isPresented: $showDisbandConfirm) {
            Button("Continue", role: .destructive) {
                showDisbandFinalConfirm = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will mark every family member inactive and cannot be undone. Are you sure?")
        }
        .alert("Final Confirmation", isPresented: $showDisbandFinalConfirm) {
            Button("Disband Forever", role: .destructive) {
                Task { await disbandFamily() }
            }
            Button("Keep Family", role: .cancel) {}
        } message: {
            Text("All quest history, gold, and trophies will remain in iCloud but this family will stop functioning. Type 'Disband Forever' to confirm.")
        }
    }

    @MainActor
    private func disbandFamily() async {
        guard let family = appState.family, let vm = viewModel else { return }

        let allMembers = vm.heroes + vm.parents
        for member in allMembers {
            try? await familyService.leaveFamily(profile: member)
        }
        _ = family
        appState.signOut()
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

struct ShareSheet: UIViewControllerRepresentable {

    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController,
                                    context: Context) {

    }
}

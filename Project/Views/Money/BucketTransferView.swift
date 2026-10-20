//
//  BucketTransferView.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import SwiftData
import SwiftUI

/// Child reallocation between buckets — validates funds, writes one
/// deterministic transfer entry per move (millisecond-timestamp ID, unlimited
/// moves per day), fires haptic.
struct BucketTransferView: View {
    @Environment(AppState.self) private var appState
    @Environment(BucketService.self) private var bucketService
    @Environment(ToastManager.self) private var toastManager: ToastManager?
    @Environment(\.dismiss) private var dismiss

    @State private var fromBucket: BucketKind = .spend
    @State private var toBucket: BucketKind = .shortTermSave
    @State private var amountText: String = ""
    @FocusState private var isAmountFocused: Bool
    @State private var isSaving: Bool = false
    @State private var showConfirmation: Bool = false

    private let profileRecordName: String?

    @Query private var ledgerCaches: [LedgerEntryCache]
    @Query private var subjectRows: [ProfileCache]
    @Query private var viewerRows: [ProfileCache]

    init(familyRecordName: String? = nil, profileRecordName: String? = nil) {
        self.profileRecordName = profileRecordName
        let targetFamily = familyRecordName ?? ""
        let targetProfile = profileRecordName ?? ""
        FamilyScopeValidator.validateOrFault(targetFamily: targetFamily, viewName: "BucketTransferView")
        // WHY predicate pushdown: per-profile query keeps store indexed (family, profile) — avoids loading N× ledgers for family with many heroes. Self-ownership gated (acting.id
        // == profile.id) requires profile scope.
        let filter = LedgerEntryCache.profilePredicate(familyRecordName: targetFamily, profileRecordName: targetProfile)
        _ledgerCaches = Query(filter: filter, sort: \LedgerEntryCache.date, order: .reverse)
        let subjectFilter = ProfileCache.recordPredicate(recordName: targetProfile, familyRecordName: targetFamily)
        _subjectRows = Query(filter: subjectFilter, sort: \ProfileCache.displayName)
        // WHY cache-derived viewer: role resolves from the cached row like HeroLedgerView so gating never reads session domain state.
        _viewerRows = Query(filter: ProfileCache.familyPredicate(familyRecordName: targetFamily), sort: \ProfileCache.displayName)
    }

    private var subjectProfileRow: ProfileCache? {
        ProfileRowResolver.resolve(rows: subjectRows, targetRecordName: profileRecordName)
    }

    private var subjectProfile: Profile? {
        guard let row = subjectProfileRow else { return nil }
        return row.toProfile(zoneID: appState.resolvedFamilyZoneID())
    }

    /// Viewer row from cache; session identity only selects the row, never the role.
    private var viewerRow: ProfileCache? {
        ProfileRowResolver.resolve(rows: viewerRows, targetRecordName: appState.currentProfile?.id.recordName)
    }

    /// Viewer role derived from cache so gating never reads session domain state.
    private var viewerRole: UserRole? {
        viewerRow?.roleEnum
    }

    private var family: Family? {
        appState.family
    }

    /// WHY subject versus viewer: balances and the transfer act on the ledger owner, the Long gate reads the viewer role only.
    /// WHY fail-closed Long gate: unknown role locks like hero so Long-Term Save never renders unlocked before cache resolves.
    private var isHeroViewer: Bool {
        viewerRole?.isParent != true
    }

    private var balances: [BucketKind: Int64] {
        // WHY no mid-thread profile filter: ledgerCaches already predicate-pushed to family+profile at store level.
        var result: [BucketKind: Int64] = [:]
        for entry in ledgerCaches {
            BucketService.applyBucketAttribution(entry, to: &result)
        }
        return result
    }

    /// Buckets available as the source — everything except the current to-bucket.
    private var fromOptions: [BucketKind] {
        BucketKind.allCases.filter { $0 != toBucket }
    }

    /// Buckets available as the destination — everything except the current from-bucket.
    private var toOptions: [BucketKind] {
        BucketKind.allCases.filter { $0 != fromBucket }
    }

    /// WHY fail-closed bounds: mirrors service debit validation so oversized payloads reject at the UI boundary.
    private var parsedAmount: Int64? {
        guard let value = CurrencyFormatter.pennies(from: amountText),
              (1 ... 100_000_000).contains(value)
        else { return nil }
        return value
    }

    private var canTransfer: Bool {
        guard let amount = parsedAmount, (1 ... 100_000_000).contains(amount) else { return false }
        return fromBucket != toBucket && subjectProfile != nil && family != nil
            && !(isHeroViewer && fromBucket == .longTermSave)
    }

    private var sourceAvailable: Int64 {
        balances[fromBucket] ?? 0
    }

    var body: some View {
        NavigationStack {
            Form {
                fromSection
                toSection
                amountSection
                summarySection
            }
            .formStyle(.grouped)
            .navigationTitle("Move Money")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                        .accessibilityIdentifier("transfer.cancelButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        showConfirmation = true
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text("Transfer")
                        }
                    }
                    .disabled(!canTransfer || isSaving)
                    .accessibilityIdentifier("transfer.confirmButton")
                }
            }
            .decimalPadDoneToolbar(isFocused: $isAmountFocused, amountText: $amountText)
            .interactiveDismissDisabled(isSaving)
            .alert("Confirm Transfer", isPresented: $showConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Move \(formattedConfirmAmount)") {
                    performTransfer()
                }
            } message: {
                Text("Move \(formattedConfirmAmount) from \(fromBucket.displayName) to \(toBucket.displayName)?")
            }
            .toastOverlay()
        }
        // WHY: view identity tracks profileRecordName so @Query predicates (init-captured) are recreated on profile switch.
        .id(profileRecordName)
    }

    // MARK: - Sections

    private var fromSection: some View {
        Section {
            Picker("From", selection: $fromBucket) {
                ForEach(fromOptions, id: \.self) { kind in
                    HStack {
                        Text(kind.displayName)
                        Spacer()
                        Text(balanceText(for: kind))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if isHeroViewer, kind == .longTermSave {
                            Image(systemName: "lock.fill")
                                .font(.caption)
                                .foregroundStyle(Color(DesignSystemConstants.Colors.pendingAmber))
                        }
                    }
                    .tag(kind)
                    // Stable ids per section — labels are locale-dependent.
                    .accessibilityIdentifier("transfer.fromOption-\(kind.rawValue)")
                    .disabled(isHeroViewer && kind == .longTermSave)
                }
            }
            .pickerStyle(.inline)
            .onAppear {
                if isHeroViewer, fromBucket == .longTermSave {
                    fromBucket = .spend
                }
            }
            .onChange(of: isHeroViewer) { _, isHero in
                if isHero, fromBucket == .longTermSave {
                    fromBucket = .spend
                }
            }
        } header: {
            Text("Source Bucket")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Available: \(CurrencyFormatter.string(sourceAvailable))")
                if isHeroViewer {
                    Text("Long-Term Save is locked. Ask a parent for help to move money from there.")
                }
            }
        }
    }

    private var toSection: some View {
        Section {
            Picker("To", selection: $toBucket) {
                ForEach(toOptions, id: \.self) { kind in
                    HStack {
                        Text(kind.displayName)
                        Spacer()
                        Text(balanceText(for: kind))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .tag(kind)
                    .accessibilityIdentifier("transfer.toOption-\(kind.rawValue)")
                }
            }
            .pickerStyle(.inline)
        } header: {
            Text("Destination Bucket")
        } footer: {
            Text("Money you move lands here and stays in this bucket until you move it again.")
        }
    }

    private var amountSection: some View {
        Section {
            HStack {
                Image(systemName: "arrow.left.arrow.right")
                    .foregroundStyle(.secondary)
                TextField("0.00", text: $amountText)
                    .keyboardType(.decimalPad)
                    .focused($isAmountFocused)
                    .font(.body.monospacedDigit())
                    .accessibilityLabel("Transfer amount in dollars")
                    .accessibilityIdentifier("transfer.amountField")
            }
        } header: {
            Text("Amount")
        } footer: {
            if let amount = parsedAmount, amount > sourceAvailable {
                Text("You only have \(CurrencyFormatter.string(sourceAvailable)) in \(fromBucket.displayName).")
                    .foregroundStyle(Color(DesignSystemConstants.Colors.dangerRed))
            }
        }
    }

    @ViewBuilder
    private var summarySection: some View {
        if let amount = parsedAmount, amount <= sourceAvailable, fromBucket != toBucket {
            Section("Summary") {
                HStack {
                    Text(fromBucket.displayName)
                    Spacer()
                    Text("-\(CurrencyFormatter.string(amount))")
                        .monospacedDigit()
                        .foregroundStyle(Color(DesignSystemConstants.Colors.dangerRed))
                }
                HStack {
                    Text(toBucket.displayName)
                    Spacer()
                    Text("+\(CurrencyFormatter.string(amount))")
                        .monospacedDigit()
                        .foregroundStyle(Color(DesignSystemConstants.Colors.primaryGreen))
                }
            }
        }
    }

    // MARK: - Helpers

    private func balanceText(for kind: BucketKind) -> String {
        CurrencyFormatter.string(balances[kind] ?? 0)
    }

    private var formattedConfirmAmount: String {
        guard let amount = parsedAmount else { return CurrencyFormatter.string(0) }
        return CurrencyFormatter.string(amount)
    }

    // MARK: - Transfer

    private func performTransfer() {
        guard let amount = parsedAmount,
              let subjectProfile,
              let family
        else {
            toastManager?.show(message: "Please check your transfer details.", type: .warning)
            return
        }
        // WHY locked bucket: heroes never debit Long-Term Save without parent help.
        if isHeroViewer, fromBucket == .longTermSave {
            toastManager?.show(message: "Long-Term Save is locked. Ask a parent for help.", type: .warning)
            return
        }

        // WHY snapshot: @State values cross suspension; Sendable copies ride the Task.
        let amountSnapshot = amount
        let fromSnapshot = fromBucket
        let toSnapshot = toBucket
        let profileSnapshot = subjectProfile
        let familySnapshot = family
        // WHY MainActor hop: isSaving/dismiss/toast mutate MainActor state so the task stays isolated.
        Task { @MainActor [bucketService, amountSnapshot, fromSnapshot, toSnapshot, profileSnapshot, familySnapshot, toastManager, dismiss] in
            isSaving = true
            defer { isSaving = false }
            do {
                // WHY single capture and atomic mint: view captures `Date()` once and passes the
                // raw instant to `BucketService.transfer(at:)` which derives the deterministic
                // `transferID` from that same instant — eliminating the double-Date()
                // TOCTOU where view and service mint mismatched IDs.
                let now = Date()
                _ = try await bucketService.transfer(
                    from: fromSnapshot,
                    to: toSnapshot,
                    amount: amountSnapshot,
                    profile: profileSnapshot,
                    family: familySnapshot,
                    at: now
                )
                HapticsService.rigid()
                dismiss()
            } catch let error as BucketServiceError {
                toastManager?.show(message: error.localizedDescription, type: .error)
            } catch {
                toastManager?.show(message: "Something went wrong. Please try again.", type: .error)
            }
        }
    }
}

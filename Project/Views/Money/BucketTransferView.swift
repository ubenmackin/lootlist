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

    init(familyRecordName: String? = nil, profileRecordName: String? = nil) {
        self.profileRecordName = profileRecordName
        let targetFamily = familyRecordName ?? ""
        let targetProfile = profileRecordName ?? ""
        FamilyScopeValidator.validateOrFault(targetFamily: targetFamily, viewName: "BucketTransferView")
        // WHY predicate pushdown: per-profile query keeps store indexed (family, profile) — avoids loading N× ledgers for family with many heroes. Self-ownership gated (acting.id
        // == profile.id) requires profile scope.
        let filter = LedgerEntryCache.profilePredicate(familyRecordName: targetFamily, profileRecordName: targetProfile)
        _ledgerCaches = Query(filter: filter, sort: \LedgerEntryCache.date, order: .reverse)
    }

    private var profile: Profile? {
        appState.currentProfile
    }

    private var family: Family? {
        appState.family
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

    private var parsedAmount: Int64? {
        guard let value = CurrencyFormatter.pennies(from: amountText),
              value > 0
        else { return nil }
        return value
    }

    private var canTransfer: Bool {
        parsedAmount != nil && fromBucket != toBucket && profile != nil && family != nil
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
                    }
                    .tag(kind)
                    // Stable ids per section — labels are locale-dependent.
                    .accessibilityIdentifier("transfer.fromOption-\(kind.rawValue)")
                }
            }
            .pickerStyle(.inline)
        } header: {
            Text("Source Bucket")
        } footer: {
            Text("Available: \(CurrencyFormatter.string(sourceAvailable))")
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
              let profile,
              let family
        else {
            toastManager?.show(message: "Please check your transfer details.", type: .warning)
            return
        }

        // WHY snapshot: @State values cross suspension; Sendable copies ride the Task.
        let amountSnapshot = amount
        let fromSnapshot = fromBucket
        let toSnapshot = toBucket
        let profileSnapshot = profile
        let familySnapshot = family
        // WHY MainActor view: isSaving mutates on the isolated task so Sendable captures stay race-free.
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

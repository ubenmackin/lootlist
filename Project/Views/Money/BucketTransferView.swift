//
//  BucketTransferView.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import SwiftData
import SwiftUI

/// Child reallocation between buckets — validates funds, blocks a repeat move
/// between the same pair on the same UTC day (deterministic-ID dedupe guard),
/// writes one deterministic transfer entry, fires haptic.
struct BucketTransferView: View {
    @Environment(AppState.self) private var appState
    @Environment(CKSyncEngineCoordinator.self) private var syncCoordinator: CKSyncEngineCoordinator?
    @Environment(ToastManager.self) private var toastManager: ToastManager?
    @Environment(\.dismiss) private var dismiss

    @State private var fromBucket: BucketKind = .spend
    @State private var toBucket: BucketKind = .shortTermSave
    @State private var amountText: String = ""
    @FocusState private var isAmountFocused: Bool
    @State private var isSaving: Bool = false
    @State private var showConfirmation: Bool = false

    private let familyRecordName: String?
    private let profileRecordName: String?

    @Query private var ledgerCaches: [LedgerEntryCache]

    init(familyRecordName: String? = nil, profileRecordName: String? = nil) {
        self.familyRecordName = familyRecordName
        self.profileRecordName = profileRecordName
        let targetFamily = familyRecordName ?? ""
        let targetProfile = profileRecordName ?? ""
        FamilyScopeValidator.validateOrFault(targetFamily: targetFamily, viewName: "BucketTransferView")
        // WHY predicate pushdown: per-profile query keeps store indexed (family, profile) — avoids loading N× ledgers for family with many heroes. Self-ownership gated (acting.id
        // == profile.id) requires profile scope; mirrors BucketService.hasTransferredToday indexed predicate.
        let filter = #Predicate<LedgerEntryCache> { $0.familyRecordName == targetFamily && $0.profileRecordName == targetProfile }
        _ledgerCaches = Query(filter: filter, sort: \LedgerEntryCache.date, order: .reverse)
    }

    private var bucketService: BucketService {
        BucketService(
            cacheService: appState.cacheService as (any CacheServicing)?,
            syncCoordinator: syncCoordinator,
            appState: appState
        )
    }

    private var profile: Profile? {
        appState.currentProfile
    }

    private var family: Family? {
        appState.family
    }

    private var balances: [BucketKind: Double] {
        // WHY no mid-thread profile filter: ledgerCaches already predicate-pushed to family+profile at store level.
        var result: [BucketKind: Double] = [:]
        for entry in ledgerCaches {
            BucketService.applyBucketAttribution(entry, to: &result)
        }
        return result
    }

    /// Limit to one transfer per bucket pair per UTC day (deterministic ID constraint).
    private var hasTransferredToday: Bool {
        // Single-sourced via BucketService indexed guard — avoids duplicated linear scan over @Query results.
        guard let profile, let family else { return false }
        let today = WeekMath.dayBucket(for: Date())
        return bucketService.hasTransferredToday(
            profileRecordName: profile.id.recordName,
            familyRecordName: family.id.recordName,
            dayBucket: today,
            from: fromBucket,
            to: toBucket
        )
    }

    /// Buckets available as the source — everything except the current to-bucket.
    private var fromOptions: [BucketKind] {
        BucketKind.allCases.filter { $0 != toBucket }
    }

    /// Buckets available as the destination — everything except the current from-bucket.
    private var toOptions: [BucketKind] {
        BucketKind.allCases.filter { $0 != fromBucket }
    }

    private var parsedAmount: Double? {
        guard let value = CurrencyFormatter.decimalDouble(from: amountText),
              value.isFinite, value > 0
        else { return nil }
        return value
    }

    private var canTransfer: Bool {
        parsedAmount != nil && fromBucket != toBucket && profile != nil && family != nil && !hasTransferredToday
    }

    private var sourceAvailable: Double {
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
            .decimalPadDoneToolbar(isFocused: $isAmountFocused)
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
            if hasTransferredToday {
                Text("You already moved money from \(fromBucket.displayName) to \(toBucket.displayName) today. You can move money between these buckets again tomorrow.")
            } else if let amount = parsedAmount, amount > sourceAvailable {
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
        guard let amount = parsedAmount else { return CurrencyFormatter.string(0.0) }
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

        Task {
            isSaving = true
            defer { isSaving = false }
            do {
                // WHY single capture and atomic mint: view captures `Date()` once and passes the
                // raw instant to `BucketService.transfer(at:)` which derives `dayBucket` and
                // deterministic `transferID` from that same instant — eliminating the double-Date()
                // TOCTOU where view and service straddle 00:00 UTC and produce mismatched buckets.
                let now = Date()
                _ = try await bucketService.transfer(
                    from: fromBucket,
                    to: toBucket,
                    amount: amount,
                    profile: profile,
                    family: family,
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

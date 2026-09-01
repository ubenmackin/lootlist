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

    @Query private var ledgerCaches: [LedgerEntryCache]

    init(familyRecordName: String? = nil) {
        let targetFamily = familyRecordName ?? ""
        #if DEBUG
            assert(!targetFamily.isEmpty || TestEnvironment.isRunningUnitOrUITests, "BucketTransferView: empty familyRecordName — predicate will match no rows (fail-closed)")
        #endif
        let filter = #Predicate<LedgerEntryCache> { $0.familyRecordName == targetFamily }
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
        guard let profile else { return [:] }
        let targetProfile = profile.id.recordName
        var result: [BucketKind: Double] = [:]
        for entry in ledgerCaches where entry.profileRecordName == targetProfile {
            BucketService.applyBucketAttribution(entry, to: &result)
        }
        return result
    }

    /// Limit to one transfer per bucket pair per UTC day (deterministic ID constraint).
    private var hasTransferredToday: Bool {
        guard let profile else { return false }
        let targetProfile = profile.id.recordName
        let today = WeekMath.dayBucket(for: Date())
        return ledgerCaches.contains { entry in
            entry.profileRecordName == targetProfile
                && entry.sourceEnum == .transfer
                && entry.fromBucket == fromBucket.rawValue
                && entry.toBucket == toBucket.rawValue
                && WeekMath.dayBucket(for: entry.date) == today
        }
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
                let dayKeyedID = "\(WeekMath.dayBucket(for: Date()))-\(fromBucket.rawValue)-\(toBucket.rawValue)"
                _ = try await bucketService.transfer(
                    from: fromBucket,
                    to: toBucket,
                    amount: amount,
                    profile: profile,
                    family: family,
                    transferID: dayKeyedID
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

//
//  SavingsSplitView.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import SwiftData
import SwiftUI

/// 3-jar split for FUTURE payouts only — never retroactive; save requires spend+short+long == 100.
struct SavingsSplitView: View {
    @Environment(AppState.self) private var appState
    @Environment(FamilyService.self) private var familyService
    @Environment(ToastManager.self) private var toastManager: ToastManager?
    @Environment(\.dismiss) private var dismiss

    @Query private var profileRows: [ProfileCache]

    @State private var spend: Int = 100
    @State private var shortSave: Int = 0
    @State private var longSave: Int = 0
    @State private var isSaving: Bool = false
    @State private var errorMessage: String?

    private let familyRecordName: String?

    init(familyRecordName: String? = nil, profileRecordName: String? = nil) {
        self.familyRecordName = familyRecordName
        let targetFamily = familyRecordName ?? ""
        // Single-row targeted fetch (e.g. parent inspecting a hero); otherwise family-scoped fetch resolved via currentProfile.
        if let profileRecordName, !profileRecordName.isEmpty {
            let targetProfile = profileRecordName
            let filter = #Predicate<ProfileCache> {
                $0.familyRecordName == targetFamily && $0.recordName == targetProfile
            }
            _profileRows = Query(filter: filter, sort: \ProfileCache.displayName)
        } else {
            // Family-wide fetch; active hero resolved via currentProfileRow.
            let filter = #Predicate<ProfileCache> { $0.familyRecordName == targetFamily }
            _profileRows = Query(filter: filter, sort: \ProfileCache.displayName)
        }
    }

    /// Resolved hero row — targeted single-row fetch returns directly; multi-row fetch requires active session, no fallback to arbitrary hero.
    private var currentProfileRow: ProfileCache? {
        if profileRows.count == 1 {
            return profileRows.first
        }
        guard let currentName = appState.currentProfile?.id.recordName else {
            return nil
        }
        return profileRows.first(where: { $0.recordName == currentName })
    }

    private var total: Int {
        spend + shortSave + longSave
    }

    private var isValid: Bool {
        total == 100 && spend >= 0 && shortSave >= 0 && longSave >= 0
    }

    private var validationMessage: String? {
        if total != 100 {
            return "Split must total 100% (currently \(total)%)."
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                presetsSection
                splitSection
                footerSection
            }
            .navigationTitle("3-Jar Split")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text("Save")
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(!isValid || isSaving)
                    .accessibilityIdentifier("split.saveButton")
                }
            }
            .task {
                syncFromProfile()
            }
            .onChange(of: profileRows) { _, _ in
                // Ingest may update cache row; sync only when not actively editing.
                if !isSaving {
                    syncFromProfile()
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Sections

    private var splitSection: some View {
        Section {
            bucketRow(
                title: "Spend",
                subtitle: "Everyday money",
                value: $spend,
                accessibilityID: "split.spend"
            )
            bucketRow(
                title: "Short Save",
                subtitle: "Goals you want soon",
                value: $shortSave,
                accessibilityID: "split.shortSave"
            )
            bucketRow(
                title: "Long Save",
                subtitle: "Big dreams for later",
                value: $longSave,
                accessibilityID: "split.longSave"
            )
        } header: {
            Text("Your Split")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let msg = validationMessage {
                    Text(msg)
                        .foregroundStyle(Color(DesignSystemConstants.Colors.dangerRed))
                    Button("Fix: balance to 100%") {
                        autocorrectTo100()
                    }
                    .font(.caption.weight(.semibold))
                    .accessibilityIdentifier("split.autocorrectButton")
                }
                Text("Total: \(total)%")
                    .foregroundStyle(isValid ? Color.secondary : Color(DesignSystemConstants.Colors.dangerRed))
                    .font(.caption.weight(.semibold))
                Text("Sliders step by 5%. Use presets or Fix to reach 100%.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var presetsSection: some View {
        Section("Quick Presets") {
            HStack(spacing: 8) {
                PresetPill(
                    text: "50/30/20",
                    isSelected: spend == 50 && shortSave == 30 && longSave == 20,
                    action: { applyPreset(spend: 50, short: 30, long: 20) }
                )
                .accessibilityIdentifier("split.preset-50-30-20")
                PresetPill(
                    text: "70/20/10",
                    isSelected: spend == 70 && shortSave == 20 && longSave == 10,
                    action: { applyPreset(spend: 70, short: 20, long: 10) }
                )
                .accessibilityIdentifier("split.preset-70-20-10")
                PresetPill(
                    text: "100/0/0",
                    isSelected: spend == 100 && shortSave == 0 && longSave == 0,
                    action: { applyPreset(spend: 100, short: 0, long: 0) }
                )
                .accessibilityIdentifier("split.preset-100-0-0")
            }
            .padding(.vertical, 4)
        }
    }

    private var footerSection: some View {
        Section {
            Text("Applies to future payouts and deposits only — not retroactively.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("split.footerNote")
        } footer: {
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(Color(DesignSystemConstants.Colors.dangerRed))
            }
        }
    }

    // MARK: - Bucket Row

    private func bucketRow(title: String, subtitle: String, value: Binding<Int>, accessibilityID: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(value.wrappedValue)%")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
                    .accessibilityIdentifier("\(accessibilityID).label")
            }

            Slider(
                value: Binding(
                    get: { Double(value.wrappedValue) },
                    set: { value.wrappedValue = Int($0.rounded()) }
                ),
                in: 0 ... 100,
                step: 5
            )
            .tint(Color(DesignSystemConstants.Colors.accentBlue))
            .accessibilityIdentifier("\(accessibilityID).slider")

            Stepper(
                "\(title): \(value.wrappedValue)%",
                value: value,
                in: 0 ... 100,
                step: 5
            )
            .labelsHidden()
            .accessibilityIdentifier("\(accessibilityID).stepper")
        }
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    private func applyPreset(spend: Int, short: Int, long: Int) {
        // Presets are known-good 100-sum combos.
        self.spend = spend
        self.shortSave = short
        self.longSave = long
        HapticsService.rigid()
    }

    private func autocorrectTo100() {
        // Auto-balance to 100% by adjusting Long Save first, then snapping to 5% steps.
        if total == 100 {
            return
        }
        if total == 0 {
            spend = 100; shortSave = 0; longSave = 0
            HapticsService.lightImpact()
            return
        }
        var spendValue = spend
        var shortValue = shortSave
        var longValue = 100 - spendValue - shortValue
        if longValue < 0 {
            shortValue = max(0, shortValue + longValue)
            longValue = 0
            if spendValue + shortValue > 100 {
                spendValue = max(0, 100 - shortValue)
            }
        } else if longValue > 100 {
            spendValue = 0; shortValue = 0; longValue = 100
        }
        // Snap spend/short to 5% steps, keep total at 100.
        spendValue = (spendValue / 5) * 5
        shortValue = (shortValue / 5) * 5
        longValue = 100 - spendValue - shortValue
        if longValue < 0 {
            if spendValue >= shortValue {
                spendValue = max(0, spendValue + longValue)
            } else {
                shortValue = max(0, shortValue + longValue)
            }
            longValue = 100 - spendValue - shortValue
        }
        spend = spendValue; shortSave = shortValue; longSave = max(0, longValue)
        HapticsService.lightImpact()
    }

    private func syncFromProfile() {
        guard let row = currentProfileRow else { return }
        spend = row.splitPercentSpend
        shortSave = row.splitPercentShort
        longSave = row.splitPercentLong
    }

    private func save() async {
        guard isValid else {
            errorMessage = validationMessage
            return
        }
        // Fail-closed: require explicit hero row and active family zone.
        guard let row = currentProfileRow, let zoneID = appState.familyZoneID else {
            errorMessage = "No active family session. Please reopen your family and try again."
            return
        }
        let profile = row.toProfile(zoneID: zoneID)
        isSaving = true
        errorMessage = nil
        do {
            _ = try await familyService.updateSavingsSplit(
                profile: profile,
                spend: spend,
                short: shortSave,
                long: longSave
            )
            HapticsService.success()
            dismiss()
        } catch let error as FamilyServiceError {
            errorMessage = error.localizedDescription
            toastManager?.show(message: error.localizedDescription, type: .error)
            isSaving = false
        } catch {
            errorMessage = error.localizedDescription
            toastManager?.show(message: error.localizedDescription, type: .error)
            isSaving = false
        }
    }
}

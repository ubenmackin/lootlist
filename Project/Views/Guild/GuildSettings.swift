//
//  GuildSettings.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import CloudKit
import os
import SwiftUI

// MARK: - Savings Automation: Interest

//
// Parent-facing config for the per-hero monthly interest engine. Kept as one
// self-contained section (own state, own service calls) so sibling savings-
// automation config — parent matching — composes alongside it later without
// entangling view state.

struct GuildInterestSectionView: View {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "GuildInterest")

    @Environment(InterestService.self) private var interestService
    @Environment(ToastManager.self) private var toastManager

    let heroes: [ProfileCache]

    @State private var selectedHeroRecordName: String?
    @State private var isEnabled = false
    @State private var selectedBucket: BucketKind = .longTermSave
    @State private var ratePercent: Double = 5
    @State private var isCompound = false
    @State private var isSaving = false
    @FocusState private var isRateFocused: Bool

    /// Fixed demo seed so the explainer table always shows friendly round
    /// numbers independent of any real wallet balance.
    private let exampleStartPennies = 1000

    private var selectedHero: ProfileCache? {
        heroes.first { $0.recordName == selectedHeroRecordName } ?? heroes.first
    }

    private var currentRateBps: Int {
        max(0, Int((ratePercent * 100).rounded()))
    }

    private var ratePercentDisplay: String {
        String(format: "%g%%", ratePercent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Savings Interest")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)

            VStack(alignment: .leading, spacing: 14) {
                if heroes.isEmpty {
                    Text("Heroes appear here once they join your guild.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Hero", selection: $selectedHeroRecordName) {
                        ForEach(heroes, id: \.recordName) { hero in
                            Text(hero.displayName).tag(Optional(hero.recordName))
                        }
                    }
                    .pickerStyle(.menu)

                    Toggle(isOn: $isEnabled) {
                        Label("Pay Monthly Interest", systemImage: "chart.line.uptrend.xyaxis")
                            .font(.subheadline.weight(.semibold))
                    }

                    if isEnabled {
                        bucketPickerRow
                        rateRow
                        compoundingPickerRow
                        explainerBlock
                    }

                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Save Interest Settings")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave || isSaving)
                }
            }
            .padding(14)
            .background(cardBackground)
            .padding(.horizontal)
        }
        .onAppear { reloadDraft() }
        .onChange(of: selectedHeroRecordName) { _, _ in reloadDraft() }
        .onChange(of: heroes) { _, _ in reloadDraft() }
    }

    private var canSave: Bool {
        !isEnabled || (currentRateBps > 0 && selectedHeroesExist)
    }

    private var selectedHeroesExist: Bool {
        selectedHero != nil
    }

    private var bucketPickerRow: some View {
        HStack {
            Label("Interest Bucket", systemImage: "archivebox")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Picker("Interest Bucket", selection: $selectedBucket) {
                ForEach(BucketKind.allCases, id: \.self) { kind in
                    Text(bucketLabel(for: kind)).tag(kind)
                }
            }
            .pickerStyle(.menu)
        }
    }

    private func bucketLabel(for kind: BucketKind) -> String {
        switch kind {
        case .spend: "Spend"
        case .shortTermSave: "Short-Term Save"
        case .longTermSave: "Long-Term Save"
        }
    }

    private var rateRow: some View {
        HStack {
            Label("Monthly Rate", systemImage: "percent")
                .font(.subheadline.weight(.semibold))
            Spacer()
            TextField("Rate", value: $ratePercent, format: .number.precision(.fractionLength(0 ... 2)))
                .keyboardType(.decimalPad)
                .focused($isRateFocused)
                .decimalPadDoneToolbar(isFocused: $isRateFocused)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Monthly interest rate percent")
            Text("%")
                .foregroundStyle(.secondary)
        }
    }

    private var compoundingPickerRow: some View {
        Picker("Compounding", selection: $isCompound) {
            Text("Simple").tag(false)
            Text("Compound").tag(true)
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Simple or compound interest")
    }

    /// MANDATORY plain-language explainer: side-by-side comparison plus a
    /// three-month table computed live from the entered rate, so parents see
    /// exactly how the two modes diverge before committing to one.
    private var explainerBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Simple: you earn \(ratePercentDisplay) of what you have each month.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Compound: your interest also earns interest — it grows faster.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            exampleTable
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.tertiarySystemGroupedBackground))
        )
    }

    private var exampleTable: some View {
        let simpleBalances = exampleBalances(isCompound: false)
        let compoundBalances = exampleBalances(isCompound: true)

        return VStack(alignment: .leading, spacing: 6) {
            Text("Example — starting with \(CurrencyFormatter.string(Double(exampleStartPennies) / 100.0)):")
                .font(.caption.weight(.semibold))

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    columnHeader("Simple")
                    columnHeader("Compound")
                }
                ForEach(simpleBalances.indices, id: \.self) { index in
                    GridRow {
                        Text("Month \(index + 1)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        amountCell(simpleBalances[index])
                        amountCell(compoundBalances[index])
                    }
                }
            }
        }
    }

    private func columnHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func amountCell(_ pennies: Int) -> some View {
        Text(CurrencyFormatter.string(Double(pennies) / 100.0))
            .font(.caption.monospacedDigit())
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// Running balance after each of the first three months under the entered
    /// rate, computed with the same whole-penny math the engine applies.
    private func exampleBalances(isCompound: Bool) -> [Int] {
        let credits = InterestService.projectionPennies(
            startingPennies: exampleStartPennies,
            rateBps: currentRateBps,
            isCompound: isCompound,
            months: 3
        )
        var balance = exampleStartPennies
        return credits.map { credit in
            balance += credit
            return balance
        }
    }

    private func reloadDraft() {
        guard let hero = selectedHero else { return }
        isEnabled = hero.interestEnabled
        selectedBucket = hero.interestBucket.flatMap { BucketKind(rawValue: $0) } ?? .longTermSave
        ratePercent = Double(hero.interestRateBps) / 100.0
        isCompound = hero.interestIsCompound
        if selectedHeroRecordName == nil {
            selectedHeroRecordName = hero.recordName
        }
    }

    @MainActor
    private func save() async {
        guard let hero = selectedHero else { return }
        let zoneID = hero.validatedZoneID(requestedZoneID: CKRecordZone.default().zoneID)
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await interestService.updateInterestConfig(
                profile: hero.toProfile(zoneID: zoneID),
                enabled: isEnabled,
                bucket: isEnabled ? selectedBucket : nil,
                rateBps: currentRateBps,
                isCompound: isCompound
            )
            toastManager.show(message: "Interest settings saved.", type: .success)
        } catch {
            logger.error("Failed to update interest config: \(error, privacy: .private)")
            toastManager.show(
                message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                type: .error
            )
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground))
    }
}

// MARK: - Savings Automation: Parent Match

//
// Parent-facing config for the per-hero parent-match engine. Composed
// alongside the interest section so both savings-automation controls share
// the same visual grouping without entangling view state.

struct GuildMatchSectionView: View {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "GuildMatch")

    @Environment(MatchService.self) private var matchService
    @Environment(ToastManager.self) private var toastManager

    let heroes: [ProfileCache]

    @State private var selectedHeroRecordName: String?
    @State private var isEnabled = false
    @State private var ratePercent: Double = 100
    @State private var capDollars: String = ""
    @State private var isSaving = false
    @FocusState private var isCapFocused: Bool

    private var selectedHero: ProfileCache? {
        heroes.first { $0.recordName == selectedHeroRecordName } ?? heroes.first
    }

    private var currentRateBps: Int {
        max(0, Int((ratePercent * 100).rounded()))
    }

    private var ratePercentDisplay: String {
        String(format: "%g%%", ratePercent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Parent Match")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)

            VStack(alignment: .leading, spacing: 14) {
                if heroes.isEmpty {
                    Text("Heroes appear here once they join your guild.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Hero", selection: $selectedHeroRecordName) {
                        ForEach(heroes, id: \.recordName) { hero in
                            Text(hero.displayName).tag(Optional(hero.recordName))
                        }
                    }
                    .pickerStyle(.menu)

                    Toggle(isOn: $isEnabled) {
                        Label("Match Goal Contributions", systemImage: "arrow.trianglehead.branch")
                            .font(.subheadline.weight(.semibold))
                    }

                    if isEnabled {
                        rateRow
                        capRow
                        explainerBlock
                    }

                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Save Match Settings")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave || isSaving)
                }
            }
            .padding(14)
            .background(cardBackground)
            .padding(.horizontal)
        }
        .onAppear { reloadDraft() }
        .onChange(of: selectedHeroRecordName) { _, _ in reloadDraft() }
        .onChange(of: heroes) { _, _ in reloadDraft() }
    }

    private var canSave: Bool {
        !isEnabled || (currentRateBps > 0 && selectedHeroesExist)
    }

    private var selectedHeroesExist: Bool {
        selectedHero != nil
    }

    /// Stepper-based rate with a text display. Allowed range starts at 1% and
    /// extends through 500% so a parent choosing a >100% multiplier can
    /// overmatch without hitting an artificial ceiling.
    private var rateRow: some View {
        HStack {
            Label("Match Rate", systemImage: "percent")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Stepper(value: $ratePercent, in: 1 ... 500, step: 1) {
                Text(ratePercentDisplay)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.primary)
            }
            .accessibilityLabel("Parent match rate percent")
        }
    }

    /// Optional monthly cap. An empty field means uncapped; the parent enters a
    /// dollar amount that is stored as pennies so the engine never rounds.
    private var capRow: some View {
        HStack {
            Label("Monthly Cap", systemImage: "dollarsign.circle")
                .font(.subheadline.weight(.semibold))
            Spacer()
            TextField("No limit", text: $capDollars)
                .keyboardType(.decimalPad)
                .focused($isCapFocused)
                .decimalPadDoneToolbar(isFocused: $isCapFocused)
                .multilineTextAlignment(.trailing)
                .frame(width: 100)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Monthly match cap in dollars")
        }
    }

    /// Plain-language explainer that shows the parent exactly what the
    /// configured rate produces for a sample contribution, so they can
    /// verify their intent before saving.
    private var explainerBlock: some View {
        let sampleContribution = 10.0
        let samplePennies = Int((sampleContribution * 100).rounded())
        let matchPennies = MatchService.matchPennies(
            contributionPennies: samplePennies,
            rateBps: currentRateBps
        )
        let matchDollars = Double(matchPennies) / 100.0

        return VStack(alignment: .leading, spacing: 8) {
            Text(
                "At \(ratePercentDisplay), a contribution of \(CurrencyFormatter.string(sampleContribution)) earns an extra \(CurrencyFormatter.string(matchDollars)) from you toward the same goal."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            if let capParsed = parseCapPennies(), capParsed > 0 {
                Text("Monthly match cap: \(CurrencyFormatter.string(Double(capParsed) / 100.0))")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            } else {
                Text("No monthly cap — every contribution is matched.")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.tertiarySystemGroupedBackground))
        )
    }

    private func parseCapPennies() -> Int64? {
        let trimmed = capDollars.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let dollars = Double(trimmed), dollars > 0 else {
            return nil
        }
        return Int64((dollars * 100).rounded())
    }

    private func reloadDraft() {
        guard let hero = selectedHero else { return }
        isEnabled = hero.matchEnabled
        ratePercent = Double(hero.matchRateBps) / 100.0
        if let capPennies = hero.matchMonthlyCapPennies, capPennies > 0 {
            capDollars = String(format: "%g", Double(capPennies) / 100.0)
        } else {
            capDollars = ""
        }
        if selectedHeroRecordName == nil {
            selectedHeroRecordName = hero.recordName
        }
    }

    @MainActor
    private func save() async {
        guard let hero = selectedHero else { return }
        let zoneID = hero.validatedZoneID(requestedZoneID: CKRecordZone.default().zoneID)
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await matchService.updateMatchConfig(
                profile: hero.toProfile(zoneID: zoneID),
                enabled: isEnabled,
                rateBps: currentRateBps,
                monthlyCapPennies: parseCapPennies()
            )
            toastManager.show(message: "Match settings saved.", type: .success)
        } catch {
            logger.error("Failed to update match config: \(error, privacy: .private)")
            toastManager.show(
                message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                type: .error
            )
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground))
    }
}

//
//  GoalEditorSheet.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import SwiftUI

/// Sheet for creating a new savings goal. Collects emoji icon, name, optional
/// category, target amount (dollars → pennies for CurrencyFormatter-safe storage),
/// and bucket kind. The save callback receives validated goal draft data.
struct GoalEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let onSave: (GoalDraft) async throws -> Void

    // MARK: - State

    @State private var selectedEmoji: String? = "🎯"
    @State private var nameText: String = ""
    @State private var categoryText: String = ""
    @State private var targetAmountText: String = ""
    @State private var bucketKind: BucketKind = .shortTermSave
    @State private var isSaving: Bool = false
    @State private var parsingError: String?

    init(onSave: @escaping (GoalDraft) async throws -> Void) {
        self.onSave = onSave
    }

    // MARK: - Curated emoji set (standalone, roughly 40 emoji across themes).

    private static let emojiGrid: [[String]] = [
        ["🎯", "🌟", "🚀", "🎮", "🎸", "🎨", "📚", "🎓"],
        ["🚲", "🎮", "💻", "📱", "🎧", "📸", "🎬", "🎹"],
        ["🏕️", "🎒", "🧸", "🛴", "🏀", "⚽", "🏈", "🎾"],
        ["🐶", "🐱", "🐰", "🦄", "🐉", "🌸", "🌊", "🏔️"],
        ["💰", "💎", "🎁", "🎪", "✈️", "🏰", "🎡", "🛍️"]
    ]

    var body: some View {
        NavigationStack {
            Form {
                emojiPickerSection
                nameSection
                categorySection
                targetAmountSection
                bucketPickerSection
            }
            .navigationTitle("New Goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveGoal() }
                        .disabled(!isValid || isSaving)
                }
            }
        }
    }

    // MARK: - Emoji Picker

    private var emojiPickerSection: some View {
        Section("Icon") {
            VStack(spacing: 10) {
                ForEach(Self.emojiGrid.indices, id: \.self) { rowIndex in
                    HStack(spacing: 0) {
                        ForEach(Self.emojiGrid[rowIndex], id: \.self) { emoji in
                            Button {
                                selectedEmoji = emoji
                            } label: {
                                Text(emoji)
                                    .font(.title)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                                    .background(
                                        selectedEmoji == emoji
                                            ? RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(Color(DesignSystemConstants.Colors.primaryGreen).opacity(0.2))
                                            : nil
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Name

    private var nameSection: some View {
        Section("Goal Name") {
            TextField("e.g. New Bike", text: $nameText)
                .submitLabel(.done)
        }
    }

    // MARK: - Category

    private static let categoryChips: [String] = [
        "Toys", "Electronics", "Activities", "Clothes", "Games", "Music", "Sports", "Travel"
    ]

    private var categorySection: some View {
        Section {
            // Category chips row.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Self.categoryChips, id: \.self) { chip in
                        PresetPill(
                            text: chip,
                            isSelected: categoryText == chip,
                            action: {
                                // Toggle: if already selected, clear; otherwise select.
                                if categoryText == chip {
                                    categoryText = ""
                                } else {
                                    categoryText = chip
                                }
                            }
                        )
                    }
                }
                .padding(.vertical, 4)
            }
            // Custom category input.
            TextField("Or type a custom category", text: $categoryText)
        } header: {
            Text("Category (optional)")
        }
    }

    // MARK: - Target Amount

    private var targetAmountSection: some View {
        Section {
            HStack(spacing: 4) {
                Text(Locale.current.currency?.identifier == "USD" ? "$" : Locale.current.currencySymbol ?? "$")
                    .foregroundStyle(.secondary)

                TextField("0.00", text: $targetAmountText)
                    .keyboardType(.decimalPad)
                    .onChange(of: targetAmountText) { _, newValue in
                        validateAmount(newValue)
                    }
            }

            if let error = parsingError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color(DesignSystemConstants.Colors.dangerRed))
            }
        } header: {
            Text("Target Amount")
        }
    }

    // MARK: - Bucket Picker

    private var bucketPickerSection: some View {
        Section("Savings Bucket") {
            Picker("Bucket", selection: $bucketKind) {
                Text("Short Save")
                    .tag(BucketKind.shortTermSave)
                Text("Long Save")
                    .tag(BucketKind.longTermSave)
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - Validation & Save

    private var isValid: Bool {
        !nameText.trimmingCharacters(in: .whitespaces).isEmpty
            && (parsedPennies ?? 0) > 0
    }

    private var parsedPennies: Int64? {
        let trimmed = targetAmountText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let dollars = Double(trimmed),
              dollars > 0
        else { return nil }
        return Int64((dollars * 100.0).rounded())
    }

    /// Validates input and surfaces parsing errors as the user types.
    private func validateAmount(_ value: String) {
        guard !value.isEmpty else {
            parsingError = nil
            return
        }
        if Double(value) == nil {
            parsingError = "Enter a valid dollar amount (e.g. 49.99)."
        } else {
            parsingError = nil
        }
    }

    private func saveGoal() {
        guard let pennies = parsedPennies, isValid else { return }
        let trimmedName = nameText.trimmingCharacters(in: .whitespaces)
        let trimmedCategory = categoryText.trimmingCharacters(in: .whitespaces)
        let finalCategory = trimmedCategory.isEmpty ? nil : trimmedCategory

        let draft = GoalDraft(
            name: trimmedName,
            emojiIcon: selectedEmoji,
            category: finalCategory,
            targetAmountPennies: pennies,
            bucketKind: bucketKind
        )

        isSaving = true
        Task {
            do {
                try await onSave(draft)
                await MainActor.run { dismiss() }
            } catch {
                // Save errors surface via the parent's error handling;
                // keep the sheet open so the user can retry.
                parsingError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                isSaving = false
            }
        }
    }
}

// MARK: - GoalDraft

/// Lightweight value type carrying validated goal-creation data from the
/// editor sheet back to the parent view's save handler.
struct GoalDraft: Sendable {
    let name: String
    let emojiIcon: String?
    let category: String?
    let targetAmountPennies: Int64
    let bucketKind: BucketKind
}

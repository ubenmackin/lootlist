//
//  GoalEditorSheet.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import SwiftUI

/// Sheet for creating or editing a savings goal — collects icon, name, category, target amount, and bucket.
struct GoalEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    private let initialGoal: GoalCache?
    private let onSave: (GoalDraft) async throws -> Void
    private let onDelete: (() async throws -> Void)?
    private let onPurchase: (() async throws -> Void)?
    private let familyRecordName: String?
    private let profileRecordName: String?

    // MARK: - State

    @State private var selectedEmoji: String?
    @State private var nameText: String
    @State private var categoryText: String
    @State private var targetAmountText: String
    @State private var bucketKind: BucketKind
    @State private var hasTargetDate: Bool
    @State private var targetDate: Date
    @State private var linkURLText: String
    @State private var resolvedTitle: String?
    @State private var resolvedImageURL: String?
    @State private var isResolvingLink: Bool = false
    @State private var suggestedPrice: ExtractedPrice?
    @State private var isExtractingPrice: Bool = false
    @FocusState private var isAmountFocused: Bool
    @State private var isSaving: Bool = false
    @State private var isDeleting: Bool = false
    @State private var isPurchasing: Bool = false
    @State private var showDeleteConfirmation: Bool = false
    @State private var showPurchaseConfirmation: Bool = false
    @State private var parsingError: String?
    @State private var isShowingSplit: Bool = false
    @State private var isShowingBucketHelp: Bool = false

    init(
        goal: GoalCache? = nil,
        familyRecordName: String? = nil,
        profileRecordName: String? = nil,
        onSave: @escaping (GoalDraft) async throws -> Void,
        onDelete: (() async throws -> Void)? = nil,
        onPurchase: (() async throws -> Void)? = nil
    ) {
        self.initialGoal = goal
        // WHY sanitize empty string to nil: "" fails closed to 0 rows in predicate; the split sheet resolves nil via the active session so it never renders silent-empty.
        self.familyRecordName = familyRecordName.sanitizedNilIfEmpty
        self.profileRecordName = profileRecordName.sanitizedNilIfEmpty
        self.onSave = onSave
        self.onDelete = onDelete
        self.onPurchase = onPurchase
        _selectedEmoji = State(initialValue: goal?.emojiIcon ?? "🎯")
        _nameText = State(initialValue: goal?.name ?? "")
        _categoryText = State(initialValue: goal?.category ?? "")
        if let goal {
            _targetAmountText = State(initialValue: CurrencyFormatter.editingString(goal.targetAmountPennies))
            _hasTargetDate = State(initialValue: goal.targetDate != nil)
            _targetDate = State(initialValue: goal.targetDate ?? Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date())
            _linkURLText = State(initialValue: goal.linkURL ?? "")
            _resolvedImageURL = State(initialValue: goal.imageURL)
            _resolvedTitle = State(initialValue: nil)
        } else {
            _targetAmountText = State(initialValue: "")
            _hasTargetDate = State(initialValue: false)
            _targetDate = State(initialValue: Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date())
            _linkURLText = State(initialValue: "")
            _resolvedImageURL = State(initialValue: nil)
            _resolvedTitle = State(initialValue: nil)
        }
        _bucketKind = State(initialValue: goal?.bucketKindEnum ?? .shortTermSave)
    }

    // MARK: - Curated emoji set (standalone, roughly 40 emoji across themes).

    private static let emojiGrid: [[String]] = [
        ["🎯", "🌟", "🚀", "🎮", "🎸", "🎨", "📚", "🎓"],
        ["🚲", "🧩", "💻", "📱", "🎧", "📸", "🎬", "🎹"],
        ["🏕️", "🎒", "🧸", "🛴", "🏀", "⚽", "🏈", "🎾"],
        ["🐶", "🐱", "🐰", "🦄", "🐉", "🌸", "🌊", "🏔️"],
        ["💰", "💎", "🎁", "🎪", "✈️", "🏰", "🎡", "🛍️"]
    ]

    private static let flatEmojis: [String] = emojiGrid.flatMap(\.self)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DesignSystemConstants.Padding.large) {
                    emojiPickerSection
                    nameSection
                    targetAmountSection
                    bucketPickerSection
                    categorySection
                    targetDateSection
                    wishlistLinkSection

                    if shouldShowPurchase {
                        purchaseSection
                    }

                    if onDelete != nil {
                        deleteSection
                    }
                }
                .padding(.horizontal, DesignSystemConstants.Padding.standard)
                .padding(.vertical, DesignSystemConstants.Padding.standard)
            }
            .background(Color(DesignSystemConstants.Colors.background).ignoresSafeArea())
            .navigationTitle(initialGoal != nil ? "Edit Goal" : "New Goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving || isDeleting || isPurchasing)
                        .accessibilityIdentifier("goalEditor.cancelButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveGoal() }
                        .disabled(!isValid || isSaving || isDeleting || isPurchasing)
                        .accessibilityIdentifier("goalEditor.saveButton")
                }
            }
            .decimalPadDoneToolbar(isFocused: $isAmountFocused)
            .alert("Delete Goal?", isPresented: $showDeleteConfirmation) {
                Button("Delete", role: .destructive) {
                    deleteGoal()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Are you sure you want to delete “\(nameText)”? This action cannot be undone.")
            }
            .alert("Mark Purchased?", isPresented: $showPurchaseConfirmation) {
                Button("Mark Purchased") {
                    purchaseGoal()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                // WHY region currency: purchase copy renders the target through CurrencyFormatter.
                Text("This will deduct \(purchaseAmountText) from your savings bucket and archive this goal.")
            }
        }
    }

    /// Purchase is available when editing an unarchived goal with a purchase handler.
    private var shouldShowPurchase: Bool {
        // WHY gate on archive only: purchased goals set both flags, while FIFO-completed goals stay purchasable to resolve.
        guard onPurchase != nil, let goal = initialGoal else { return false }
        return !goal.isArchived
    }

    /// Target formatted for purchase confirmation copy.
    private var purchaseAmountText: String {
        // WHY stored target: purchase deducts the saved target,
        // so unsaved edits never mismatch the confirmation copy.
        guard let goal = initialGoal else { return CurrencyFormatter.string(0) }
        return CurrencyFormatter.string(goal.targetAmountPennies)
    }

    // MARK: - Card Background Helper

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.card, style: .continuous)
            .fill(Color(DesignSystemConstants.Colors.cardSurface))
    }

    // MARK: - Emoji Picker

    private var emojiPickerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ICON")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 8), spacing: 8) {
                ForEach(Self.flatEmojis, id: \.self) { emoji in
                    Button {
                        selectedEmoji = emoji
                    } label: {
                        Text(emoji)
                            .font(.title)
                            .padding(.vertical, 4)
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
            .padding(DesignSystemConstants.Padding.medium)
            .background(cardBackground)
        }
    }

    // MARK: - Name

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GOAL NAME")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 8) {
                TextField("e.g. New Bike", text: $nameText)
                    .submitLabel(.done)
                    .accessibilityIdentifier("goalEditor.nameField")

                if let title = resolvedTitle, !title.isEmpty, nameText.isEmpty {
                    Button {
                        nameText = title
                    } label: {
                        Label("Use “\(title)” from link", systemImage: "arrow.up.left")
                            .font(.caption)
                            .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
                    }
                }
            }
            .padding(DesignSystemConstants.Padding.medium)
            .background(cardBackground)
        }
    }

    // MARK: - Target Amount

    private var targetAmountSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TARGET AMOUNT")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(CurrencyFormatter.currencySymbol)
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    TextField("0.00", text: $targetAmountText)
                        .font(.headline.monospacedDigit())
                        .keyboardType(.decimalPad)
                        .focused($isAmountFocused)
                        .accessibilityIdentifier("goalEditor.amountField")
                        .onChange(of: targetAmountText) { _, newValue in
                            validateAmount(newValue)
                        }
                }

                if let error = parsingError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Color(DesignSystemConstants.Colors.dangerRed))
                }
            }
            .padding(DesignSystemConstants.Padding.medium)
            .background(cardBackground)
        }
    }

    // MARK: - Bucket Picker

    private var bucketPickerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("SAVINGS BUCKET")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    isShowingBucketHelp = true
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Bucket help")
                .accessibilityIdentifier("goalEditor.bucketHelpButton")
                .sheet(isPresented: $isShowingBucketHelp) {
                    NavigationStack {
                        VStack(alignment: .leading, spacing: 12) {
                            BucketExplainer()
                            Text("Spend — everyday money you can use anytime.")
                                .font(.subheadline)
                            Text("Short Save — goals you want soon.")
                                .font(.subheadline)
                            Text("Long Save — big dreams for later.")
                                .font(.subheadline)
                            Text("Your % split decides where future payouts go; oldest goal in that bucket fills first (FIFO).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                        }
                        .padding(DesignSystemConstants.Padding.large)
                        .navigationTitle("Buckets")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { isShowingBucketHelp = false }
                            }
                        }
                    }
                    .presentationDetents([.medium])
                }
            }
            .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 10) {
                Picker("Bucket", selection: $bucketKind) {
                    Text("Short Save")
                        .tag(BucketKind.shortTermSave)
                    Text("Long Save")
                        .tag(BucketKind.longTermSave)
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 6) {
                    Text("This bucket fills from your % split. Future payouts flow FIFO — oldest goal in that bucket fills first.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Edit my split") {
                        isShowingSplit = true
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
                    .accessibilityIdentifier("goalEditor.editSplitButton")
                }
            }
            .padding(DesignSystemConstants.Padding.medium)
            .background(cardBackground)
            .sheet(isPresented: $isShowingSplit) {
                SavingsSplitView(
                    familyRecordName: familyRecordName ?? appState.family?.id.recordName,
                    profileRecordName: profileRecordName ?? appState.currentProfile?.id.recordName
                )
            }
        }
    }

    // MARK: - Category

    private static let categoryChips: [String] = [
        "Toys", "Electronics", "Activities", "Clothes", "Games", "Music", "Sports", "Travel"
    ]

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CATEGORY (OPTIONAL)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Self.categoryChips, id: \.self) { chip in
                            PresetPill(
                                text: chip,
                                isSelected: categoryText == chip,
                                action: {
                                    if categoryText == chip {
                                        categoryText = ""
                                    } else {
                                        categoryText = chip
                                    }
                                }
                            )
                        }
                    }
                }
                .frame(height: 36)

                TextField("Or type a custom category", text: $categoryText)
            }
            .padding(DesignSystemConstants.Padding.medium)
            .background(cardBackground)
        }
    }

    // MARK: - Target Date & Pacing

    private var targetDateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TARGET DATE & PACING (OPTIONAL)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 12) {
                Toggle("Set Target Date", isOn: $hasTargetDate)

                if hasTargetDate {
                    DatePicker(
                        "Target Date",
                        selection: $targetDate,
                        in: Date()...,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.compact)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            PresetPill(text: "1 Month", isSelected: isPresetMatching(months: 1)) {
                                setPresetDate(months: 1)
                            }
                            PresetPill(text: "3 Months", isSelected: isPresetMatching(months: 3)) {
                                setPresetDate(months: 3)
                            }
                            PresetPill(text: "6 Months", isSelected: isPresetMatching(months: 6)) {
                                setPresetDate(months: 6)
                            }
                        }
                    }
                    .frame(height: 36)

                    if let pennies = parsedPennies, pennies > 0 {
                        if let summary = GoalPacingCalculator.calculatePacing(
                            targetAmountPennies: pennies,
                            savedPennies: 0,
                            createdAt: initialGoal?.createdAt ?? Date(),
                            targetDate: targetDate
                        ) {
                            HStack(spacing: 8) {
                                Image(systemName: "speedometer")
                                    .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
                                Text("Save \(CurrencyFormatter.string(pennies: summary.weeklyRequiredSavingsPennies))/week (\(summary.weeksRemaining) weeks)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(DesignSystemConstants.Padding.medium)
            .background(cardBackground)
        }
    }

    // MARK: - Wishlist Link

    private var wishlistLinkSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WISHLIST WEB LINK (OPTIONAL)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "link")
                        .foregroundStyle(.secondary)
                    TextField("https://amazon.com/... or product link", text: $linkURLText)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: linkURLText) { _, newURL in
                            resolveURLMetadata(newURL)
                        }

                    if !linkURLText.isEmpty {
                        Button {
                            linkURLText = ""
                            resolvedTitle = nil
                            resolvedImageURL = nil
                            suggestedPrice = nil
                            isExtractingPrice = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let imageString = resolvedImageURL,
                   let imageURL = URL(string: imageString)
                {
                    HStack(spacing: 10) {
                        AsyncImage(url: imageURL) { phase in
                            switch phase {
                            case .empty:
                                ProgressView()
                                    .frame(width: 40, height: 40)
                                    .background(Color(DesignSystemConstants.Colors.cardSurface))
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            case let .success(image):
                                image
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 40, height: 40)
                                    .clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            case .failure:
                                Text(selectedEmoji ?? "🎯")
                                    .font(.title3)
                                    .frame(width: 40, height: 40)
                                    .background(Color(DesignSystemConstants.Colors.cardSurface))
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            @unknown default:
                                Color(DesignSystemConstants.Colors.cardSurface)
                                    .frame(width: 40, height: 40)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                        }
                        .frame(width: 40, height: 40)

                        VStack(alignment: .leading, spacing: 2) {
                            if let title = resolvedTitle, !title.isEmpty {
                                Text(title)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                            }
                            Text(imageURL.host?.replacingOccurrences(of: "www.", with: "") ?? "Preview")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }

                if isResolvingLink {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Fetching product details...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let url = LinkMetadataService.normalizeURL(from: linkURLText) {
                    HStack {
                        Text("Store: \(url.host?.replacingOccurrences(of: "www.", with: "") ?? "Web Link")")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color(DesignSystemConstants.Colors.primaryGreen))
                            .font(.caption)
                    }
                }

                if isExtractingPrice {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Checking price...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let suggested = suggestedPrice {
                    Button {
                        targetAmountText = CurrencyFormatter.editingString(suggested.amount)
                        validateAmount(targetAmountText)
                    } label: {
                        Label("Use suggested price \(CurrencyFormatter.string(suggested.amount))", systemImage: "dollarsign.circle.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(Color(DesignSystemConstants.Colors.primaryGreen))
                    .accessibilityIdentifier("goalEditor.useSuggestedPriceButton")
                }
            }
            .padding(DesignSystemConstants.Padding.medium)
            .background(cardBackground)
        }
    }

    // MARK: - Purchase Section

    private var purchaseSection: some View {
        Button {
            showPurchaseConfirmation = true
        } label: {
            HStack {
                Spacer()
                if isPurchasing {
                    ProgressView()
                } else {
                    Label("Mark Purchased (\(purchaseAmountText))", systemImage: "cart.fill")
                        .foregroundStyle(Color(DesignSystemConstants.Colors.primaryGreen))
                }
                Spacer()
            }
            .padding(DesignSystemConstants.Padding.medium)
            .background(cardBackground)
        }
        .disabled(isSaving || isDeleting || isPurchasing)
        .accessibilityIdentifier("goalEditor.purchaseButton")
    }

    // MARK: - Delete Section

    private var deleteSection: some View {
        Button(role: .destructive) {
            showDeleteConfirmation = true
        } label: {
            HStack {
                Spacer()
                if isDeleting {
                    ProgressView()
                } else {
                    Label("Delete Goal", systemImage: "trash")
                        .foregroundStyle(Color(DesignSystemConstants.Colors.dangerRed))
                }
                Spacer()
            }
            .padding(DesignSystemConstants.Padding.medium)
            .background(cardBackground)
        }
        .disabled(isSaving || isDeleting || isPurchasing)
        .accessibilityIdentifier("goalEditor.deleteButton")
    }

    // MARK: - Validation & Save

    private var isValid: Bool {
        !nameText.trimmingCharacters(in: .whitespaces).isEmpty
            && (parsedPennies ?? 0) > 0
    }

    private var parsedPennies: Int64? {
        guard let pennies = CurrencyFormatter.pennies(from: targetAmountText),
              pennies > 0
        else { return nil }
        return pennies
    }

    /// Validates input and surfaces parsing errors as the user types.
    private func validateAmount(_ value: String) {
        guard !value.isEmpty else {
            parsingError = nil
            return
        }
        if CurrencyFormatter.pennies(from: value) == nil {
            parsingError = "Enter a valid dollar amount (e.g. 49.99)."
        } else {
            parsingError = nil
        }
    }

    private func isPresetMatching(months: Int) -> Bool {
        guard let candidate = Calendar.current.date(byAdding: .month, value: months, to: Date()) else { return false }
        return Calendar.current.isDate(candidate, inSameDayAs: targetDate)
    }

    private func setPresetDate(months: Int) {
        if let target = Calendar.current.date(byAdding: .month, value: months, to: Date()) {
            targetDate = target
        }
    }

    private func resolveURLMetadata(_ rawURL: String) {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = LinkMetadataService.normalizeURL(from: trimmed) else {
            resolvedTitle = nil
            resolvedImageURL = nil
            suggestedPrice = nil
            isExtractingPrice = false
            return
        }

        isResolvingLink = true
        suggestedPrice = nil
        isExtractingPrice = false
        resolvedImageURL = nil
        // WHY snapshot: link fetch suspends; Sendable URL rides the Task while @State stays on MainActor.
        Task { [url] in
            if let metadata = await LinkMetadataService.fetchMetadata(for: url) {
                if let title = metadata.title, !title.isEmpty {
                    resolvedTitle = title
                    if nameText.isEmpty {
                        nameText = title
                    }
                } else {
                    resolvedTitle = nil
                }
                resolvedImageURL = metadata.imageURL.flatMap { $0.isEmpty ? nil : $0 }
            } else {
                resolvedTitle = nil
                resolvedImageURL = nil
            }
            isResolvingLink = false

            // One-time price suggestion — only when amount is empty, never auto-overwrite.
            let amountEmpty = targetAmountText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if amountEmpty {
                isExtractingPrice = true
                suggestedPrice = nil
                if let price = await PriceExtractionService.extractPrice(from: url) {
                    // Re-check emptiness — user may have typed while fetch was in flight.
                    if targetAmountText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        suggestedPrice = price
                    }
                }
                isExtractingPrice = false
            }
        }
    }

    private func saveGoal() {
        guard let pennies = parsedPennies, isValid else { return }
        let trimmedName = nameText.trimmingCharacters(in: .whitespaces)
        let trimmedCategory = categoryText.trimmingCharacters(in: .whitespaces)
        let finalCategory = trimmedCategory.isEmpty ? nil : trimmedCategory
        let trimmedLink = linkURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalLink = trimmedLink.isEmpty ? nil : trimmedLink

        let draft = GoalDraft(
            name: trimmedName,
            emojiIcon: selectedEmoji,
            category: finalCategory,
            targetAmountPennies: pennies,
            bucketKind: bucketKind,
            targetDate: hasTargetDate ? targetDate : nil,
            linkURL: finalLink,
            imageURL: resolvedImageURL
        )

        isSaving = true
        // WHY snapshot: draft crosses suspension; Sendable copy rides the Task.
        Task { [draft] in
            do {
                try await onSave(draft)
                dismiss()
            } catch {
                // Keep sheet open on failure — parent surfaces the error.
                parsingError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                isSaving = false
            }
        }
    }

    private func deleteGoal() {
        guard let onDelete else { return }
        isDeleting = true
        // WHY MainActor hop: @State mutations resume on MainActor after suspension.
        Task {
            do {
                try await onDelete()
                dismiss()
            } catch {
                parsingError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                isDeleting = false
            }
        }
    }

    private func purchaseGoal() {
        guard let onPurchase else { return }
        isPurchasing = true
        // WHY MainActor hop: @State mutations resume on MainActor after suspension.
        Task {
            do {
                try await onPurchase()
                dismiss()
            } catch {
                // Keep sheet open on failure so the balance error stays visible.
                parsingError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                isPurchasing = false
            }
        }
    }
}

// MARK: - GoalDraft

/// Validated goal-creation payload passed to the parent save handler.
struct GoalDraft: Sendable {
    let name: String
    let emojiIcon: String?
    let category: String?
    let targetAmountPennies: Int64
    let bucketKind: BucketKind
    var targetDate: Date?
    var linkURL: String?
    var imageURL: String?
}

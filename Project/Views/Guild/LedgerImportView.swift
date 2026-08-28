//
//  LedgerImportView.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import os
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Parent-only staging sheet for CSV transaction imports. Rows are editable
/// until the explicit "Import N Transactions" confirmation; nothing touches
/// the ledger before that button fires.
struct LedgerImportView: View {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "LedgerImportView")
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @Environment(ToastManager.self) private var toastManager: ToastManager?

    private let importService: LedgerImportService
    private let familyRecordName: String?

    @State private var viewModel: LedgerImportViewModel?
    @State private var isShowingFilePicker: Bool = false

    init(importService: LedgerImportService, familyRecordName: String?) {
        self.importService = importService
        self.familyRecordName = familyRecordName
    }

    var body: some View {
        NavigationStack {
            Group {
                if let vm = viewModel {
                    content(viewModel: vm)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Import Transactions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task {
            if viewModel == nil {
                let vm = LedgerImportViewModel(
                    importService: importService,
                    appState: appState,
                    familyRecordName: familyRecordName
                )
                viewModel = vm
                // UI tests cannot drive the system document picker, so a
                // staged CSV path short-circuits straight into the normal
                // review flow; production launches never set it.
                if let csvPath = TestEnvironment.uiTestImportCSVPath {
                    stageForUITests(path: csvPath, viewModel: vm)
                }
            }
        }
    }

    private func stageForUITests(path: String, viewModel vm: LedgerImportViewModel) {
        let text: String
        do {
            text = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            return
        }
        vm.stage(csvText: text)
    }

    @ViewBuilder
    private func content(viewModel vm: LedgerImportViewModel) -> some View {
        if vm.stagedRows.isEmpty {
            emptyState
        } else {
            stagingList(viewModel: vm)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 20) {
            EmptyStateView(
                systemImage: "square.and.arrow.down.on.square",
                title: "Choose a CSV File",
                description: "Pick an exported transactions file to review it here before anything is imported.",
                topPadding: 0
            )
            Button {
                isShowingFilePicker = true
            } label: {
                Label("Choose CSV File", systemImage: "folder")
                    .font(.subheadline.weight(.bold))
                    .padding(.vertical, 10)
                    .padding(.horizontal, 18)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor.opacity(0.15)))
            }
            .accessibilityIdentifier("import.chooseFileButton")
            if let message = viewModel?.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Color(DesignSystemConstants.Colors.dangerRed))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fileImporter(
            isPresented: $isShowingFilePicker,
            allowedContentTypes: [.commaSeparatedText],
            allowsMultipleSelection: false
        ) { result in
            handleFileResult(result)
        }
    }

    // MARK: - Staging list

    private func stagingList(viewModel vm: LedgerImportViewModel) -> some View {
        List {
            Section {
                ForEach(vm.stagedRows) { row in
                    StagedRowEditor(
                        row: row,
                        childOptions: vm.childProfiles,
                        onAssign: { vm.assign(rowID: row.id, to: $0) },
                        onExclude: { vm.setExcluded(rowID: row.id, $0) },
                        onDescriptionChange: { vm.updateDescription(rowID: row.id, text: $0) },
                        onMerchantChange: { vm.updateMerchant(rowID: row.id, text: $0) },
                        onAmountChange: { vm.updateAmount(rowID: row.id, text: $0) },
                        onDateChange: { vm.updateDate(rowID: row.id, text: $0) }
                    )
                }
            } header: {
                Text("\(vm.includedRows.count) included · \(vm.blockedRowCount) blocked")
            } footer: {
                confirmFooter(viewModel: vm)
            }
        }
        .fileImporter(
            isPresented: $isShowingFilePicker,
            allowedContentTypes: [.commaSeparatedText],
            allowsMultipleSelection: false
        ) { result in
            handleFileResult(result)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isShowingFilePicker = true
                } label: {
                    Image(systemName: "doc.badge.plus")
                }
                .accessibilityLabel("Choose another CSV file")
                .accessibilityIdentifier("import.chooseAnotherFileButton")
            }
        }
        .onChange(of: vm.didComplete) { _, completed in
            guard completed else { return }
            toastManager?.show(message: "Transactions imported", type: .success)
            dismiss()
        }
    }

    /// Confirmation stays disabled while any included row is unassigned or
    /// unreadable; excluded rows are skipped silently by design because the
    /// parent explicitly chose to leave them out.
    private func confirmFooter(viewModel vm: LedgerImportViewModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if vm.blockedRowCount > 0 {
                Label(
                    "\(vm.blockedRowCount) row(s) still need a child assignment or a fix.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(DesignSystemConstants.Colors.dangerRed))
            }
            Button {
                Task { await vm.finalize() }
            } label: {
                HStack {
                    if vm.isFinalizing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                    }
                    Text("Import \(vm.includedRows.count) Transactions")
                        .font(.subheadline.weight(.bold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!vm.canFinalize)
            .accessibilityIdentifier("import.confirmButton")
            if let message = vm.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Color(DesignSystemConstants.Colors.dangerRed))
            }
        }
    }

    // MARK: - File handling

    private func handleFileResult(_ result: Result<[URL], Error>) {
        switch result {
        case let .failure(error):
            Self.logger.error("File selection failed: \(error, privacy: .private)")
            viewModel?.loadingFailed("Could not open the selected file.")
            toastManager?.show(message: "Could not open the selected file.", type: .error)
        case let .success(urls):
            guard let url = urls.first else { return }
            let secured = url.startAccessingSecurityScopedResource()
            defer {
                if secured {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let data = try Data(contentsOf: url)
                guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                    Self.logger.error("Failed to decode CSV text from file data at \(url.lastPathComponent, privacy: .private)")
                    viewModel?.loadingFailed("That file could not be read as text.")
                    toastManager?.show(message: "That file could not be read as text.", type: .error)
                    return
                }
                viewModel?.stage(csvText: text)
            } catch {
                Self.logger.error("Failed to read file contents from \(url.lastPathComponent, privacy: .private): \(error, privacy: .private)")
                viewModel?.loadingFailed("That file could not be read.")
                toastManager?.show(message: "That file could not be read.", type: .error)
            }
        }
    }
}

// MARK: - Staged row editor

/// One editable staging row. Red state marks UNASSIGNED or unreadable rows;
/// the Purchased By dropdown offers actual child profiles only.
private struct StagedRowEditor: View {
    let row: StagedImportRow
    let childOptions: [ProfileCache]

    let onAssign: (ProfileCache?) -> Void
    let onExclude: (Bool) -> Void
    let onDescriptionChange: (String) -> Void
    let onMerchantChange: (String) -> Void
    let onAmountChange: (String) -> Void
    let onDateChange: (String) -> Void

    /// Decimal pad has no return key — Done button dismisses keyboard.
    @FocusState private var isAmountFocused: Bool

    private var isBlocked: Bool {
        !row.isExcluded && (!row.isAssigned || row.parseIssue != nil || row.amount == nil || row.date == nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Description", text: binding(get: \.descriptionText, onChange: onDescriptionChange))
                    .textFieldStyle(.roundedBorder)
                    .font(.subheadline.weight(.semibold))
                Toggle("Skip", isOn: Binding(
                    get: { row.isExcluded },
                    set: { onExclude($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
            }

            HStack(spacing: 8) {
                TextField("Merchant", text: binding(get: \.merchant, onChange: onMerchantChange))
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)

                TextField("Amount", text: binding(get: \.amountText, onChange: onAmountChange))
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospacedDigit())
                    .keyboardType(.decimalPad)
                    .focused($isAmountFocused)
                    .frame(width: 90)
                    .decimalPadDoneToolbar(isFocused: $isAmountFocused)

                TextField("Date", text: binding(get: \.dateText, onChange: onDateChange))
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .frame(width: 110)
            }

            Picker("Purchased By", selection: assignmentBinding) {
                Text("UNASSIGNED").tag(nil as ProfileCache?)
                ForEach(childOptions, id: \.recordName) { child in
                    Text(child.displayName).tag(child as ProfileCache?)
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(isBlocked ? Color(DesignSystemConstants.Colors.dangerRed) : Color.primary)

            if let issue = row.parseIssue {
                Label(issue, systemImage: "exclamationmark.circle.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color(DesignSystemConstants.Colors.dangerRed))
            }
            if !row.isAssigned, !row.isExcluded {
                Label("Assign a hero before importing", systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color(DesignSystemConstants.Colors.dangerRed))
            }
        }
        .opacity(row.isExcluded ? 0.45 : 1)
        .overlay(alignment: .leading) {
            if isBlocked {
                Rectangle()
                    .fill(Color(DesignSystemConstants.Colors.dangerRed))
                    .frame(width: 3)
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 2)
    }

    private var assignmentBinding: Binding<ProfileCache?> {
        Binding(
            get: { childOptions.first { $0.recordName == row.assignedProfileRecordName } },
            set: { onAssign($0) }
        )
    }

    private func binding(
        get keyPath: KeyPath<StagedImportRow, String>,
        onChange: @escaping (String) -> Void
    ) -> Binding<String> {
        Binding(
            get: { row[keyPath: keyPath] },
            set: { onChange($0) }
        )
    }
}

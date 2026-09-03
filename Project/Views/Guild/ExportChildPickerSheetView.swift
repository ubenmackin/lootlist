//
//  ExportChildPickerSheetView.swift
//  LootList
//
//  Created by Ben Mackin on 9/01/26.
//

import SwiftUI

/// Sheet that lets a parent pick a child, optionally set a date range, and
/// confirm the export. All-time range is the default; a toggle reveals the
/// start/end date pickers.
struct ExportChildPickerSheet: View {
    let heroes: [ProfileCache]
    let onExport: (ProfileCache, Date, Date) -> Void

    @State private var selectedChild: ProfileCache?
    @State private var useDateFilter = false
    @State private var startDate = Date.distantPast
    @State private var endDate = Date()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Select Child") {
                    if heroes.isEmpty {
                        Text("No children in this family.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Child", selection: $selectedChild) {
                            Text("Choose a child…").tag(nil as ProfileCache?)
                            ForEach(heroes, id: \.recordName) { hero in
                                Text(hero.displayName).tag(hero as ProfileCache?)
                            }
                        }
                    }
                }

                Section("Date Range (Optional)") {
                    Toggle("Filter by date range", isOn: $useDateFilter)
                    if useDateFilter {
                        DatePicker("Start", selection: $startDate, displayedComponents: .date)
                        DatePicker("End", selection: $endDate, displayedComponents: .date)
                    } else {
                        Text("All-time (no date filtering)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Export Ledger")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Export") {
                        guard let child = selectedChild else { return }
                        dismiss()
                        let effectiveStart = useDateFilter ? startDate : Date.distantPast
                        let effectiveEnd = useDateFilter ? endDate : Date.distantFuture
                        onExport(child, effectiveStart, effectiveEnd)
                    }
                    .disabled(selectedChild == nil)
                }
            }
        }
        .onAppear {
            // Pre-select the first hero if none is chosen yet.
            if selectedChild == nil, let first = heroes.first {
                selectedChild = first
            }
        }
    }
}

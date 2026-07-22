import SwiftUI
import CloudKit

struct QuestAssignmentView: View {

    @Bindable var viewModel: QuestManagerViewModel

    @Environment(\.dismiss) private var dismiss

    @State private var selectedTemplate: QuestTemplate?
    @State private var selectedHero: Profile?
    @State private var goldOverrideText: String = ""
    @State private var xpOverrideText: String = ""
    @State private var approvalOverride: ApprovalModeSelection = .useTemplate
    @State private var weekOf: Date = defaultWeekOf()
    @State private var validationError: String?
    @State private var isSubmitting: Bool = false

    enum ApprovalModeSelection: String, CaseIterable, Identifiable {
        case useTemplate = "Use Template Default"
        case autoApproveOverride = "Auto-Approve (override)"
        case parentVerifyOverride = "Parent Verifies (override)"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Template") {
                    if viewModel.templates.filter({ $0.isActive }).isEmpty {
                        Text("No active templates. Create one in the Templates tab first.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Template", selection: $selectedTemplate) {
                            Text("Choose…").tag(nil as QuestTemplate?)
                            ForEach(viewModel.templates.filter { $0.isActive }) { template in
                                Text(template.name).tag(template as QuestTemplate?)
                            }
                        }
                    }
                }

                Section("Hero") {
                    if viewModel.heroes.isEmpty {
                        Text("No heroes in the family.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Hero", selection: $selectedHero) {
                            Text("Choose…").tag(nil as Profile?)
                            ForEach(viewModel.heroes) { hero in
                                Text(hero.displayName).tag(hero as Profile?)
                            }
                        }
                    }
                }

                Section {
                    HStack {
                        Text("Gold Override")
                            .foregroundStyle(.secondary)
                        Spacer()
                        TextField(selectedTemplate?.defaultGold.mapToText() ?? "",
                                  text: $goldOverrideText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }

                    HStack {
                        Text("XP Override")
                            .foregroundStyle(.secondary)
                        Spacer()
                        TextField(selectedTemplate?.xpReward.mapToText() ?? "",
                                  text: $xpOverrideText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }

                    Picker("Approval", selection: $approvalOverride) {
                        ForEach(ApprovalModeSelection.allCases) { sel in
                            Text(sel.rawValue).tag(sel)
                        }
                    }
                } header: {
                    Text("Overrides (optional)")
                } footer: {
                    Text("Leaving a field blank uses the template's default value.")
                }

                Section("Week Of") {
                    DatePicker("Week Starting Monday",
                               selection: $weekOf,
                               displayedComponents: .date)
                }

                if let validationError {
                    Section {
                        Text(validationError)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("Assign Quest")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: submit) {
                        if isSubmitting { ProgressView() } else { Text("Assign") }
                    }
                    .disabled(isSubmitting || selectedTemplate == nil || selectedHero == nil)
                }
            }
            .onAppear {

                if selectedTemplate == nil {
                    selectedTemplate = viewModel.templates.first { $0.isActive }
                }
                if selectedHero == nil {
                    selectedHero = viewModel.heroes.first
                }
            }
        }
    }

    private func submit() {
        guard let template = selectedTemplate, let hero = selectedHero else {
            validationError = "Select a template and a hero."
            return
        }

        let gold: Double? = {
            guard let v = Double(goldOverrideText.trimmingCharacters(in: .whitespaces)) else {
                return nil
            }
            return v
        }()

        let xp: Int? = {
            guard let v = Int(xpOverrideText.trimmingCharacters(in: .whitespaces)) else {
                return nil
            }
            return v
        }()

        let approval: ApprovalMode? = {
            switch approvalOverride {
            case .useTemplate:            return nil
            case .autoApproveOverride:    return .autoApprove
            case .parentVerifyOverride:   return .parentVerify
            }
        }()

        isSubmitting = true
        Task {
            do {
                try await viewModel.assignQuest(
                    template: template,
                    assignee: hero,
                    goldOverride: gold,
                    xpOverride: xp,
                    approvalOverride: approval,
                    weekOf: weekOf
                )
                isSubmitting = false
                dismiss()
            } catch {
                isSubmitting = false
                validationError = error.localizedDescription
            }
        }
    }

    private static func defaultWeekOf() -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())
        return cal.date(from: comps) ?? Date()
    }
}

private extension Double {

    func mapToText() -> String { String(format: "%.2f", self) }
}

private extension Int {

    func mapToText() -> String { String(self) }
}

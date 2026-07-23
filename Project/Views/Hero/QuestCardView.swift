import CloudKit
import SwiftUI

struct QuestCardView: View {
    let quest: Quest

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: quest.approvalMode.iconSystemName)
                .font(.title3)
                .foregroundStyle(quest.approvalMode == .parentVerify ? .indigo : .green)
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill((quest.approvalMode == .parentVerify ? Color.indigo : Color.green)
                            .opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 4) {
                Text("Quest \(templateNameGuess)")
                    .font(.headline)
                HStack(spacing: 10) {
                    Label(String(format: "%.2f", quest.goldReward), systemImage: "dollarsign.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.subheadline)
                        .foregroundStyle(.yellow)

                    Label("\(quest.xpReward) XP", systemImage: "star.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.subheadline)
                        .foregroundStyle(.purple)

                    if quest.approvalMode == .parentVerify {
                        Text("Parent Verifies")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.indigo.opacity(0.15)))
                            .foregroundStyle(.indigo)
                    }
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .contentShape(Rectangle())
    }

    private var templateNameGuess: String {
        let name = quest.template.recordID.recordName
        if name.count > 6 {
            return String(name.suffix(6))
        }
        return name
    }
}

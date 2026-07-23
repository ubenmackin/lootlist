import SwiftUI

struct FamilyCreationView: View {
    @Bindable var viewModel: OnboardingViewModel

    var body: some View {
        VStack(spacing: 24) {
            header

            Spacer()

            VStack(alignment: .leading, spacing: 12) {
                Label("Name your guild", systemImage: "person.3.fill")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.primary)

                TextField("The Pan Family", text: $viewModel.familyName)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .font(.title3)
                    .padding(16)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                    )
                    .accessibilityIdentifier("createFamily.familyNameField")

                Text("Your family will share this name across all devices.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)

            Spacer()

            Button {
                viewModel.advanceToAvatarSelection()
            } label: {
                Label("Next: Forge Your Character", systemImage: "shield.fill")
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(viewModel.familyName.trimmingCharacters(in: .whitespaces).isEmpty)
            .padding(.horizontal, 24)

            Spacer().frame(height: 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [Color(.systemBackground), Color.orange.opacity(0.12)],
                startPoint: .top, endPoint: .bottom
            )
        )
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    viewModel.backToRoleSelection()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "crown.fill")
                .font(.system(size: 56))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.yellow, .orange],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            Text("Found Your Guild")
                .font(.system(size: 28, weight: .heavy, design: .rounded))
            Text("As Guild Master you'll forge a shared realm "
                + "for the whole family.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
        }
        .padding(.top, 24)
    }
}

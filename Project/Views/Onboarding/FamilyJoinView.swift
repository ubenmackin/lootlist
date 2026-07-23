import SwiftUI

struct FamilyJoinView: View {
    @Bindable var viewModel: OnboardingViewModel

    var body: some View {
        VStack(spacing: 24) {
            header

            Spacer()

            if viewModel.hasShareInvitation {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)

                    Text("Invitation Link Received!")
                        .font(.headline.weight(.bold))

                    Text("You're ready to join your family's guild party.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 24)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Invitation Link", systemImage: "link.badge.plus")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.primary)

                    TextField("https://www.icloud.com/share/...", text: $viewModel.shareURLString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.subheadline)
                        .padding(16)
                        .background(.thinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                        )
                        .accessibilityIdentifier("joinFamily.linkField")

                    Text("Tap the invitation link sent by your Guild Master, or paste the link here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24)
            }

            Spacer()

            Button {
                viewModel.advanceToAvatarSelection()
            } label: {
                Label("Next: Choose Your Hero", systemImage: "sparkles")
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .disabled(!viewModel.hasShareInvitation && viewModel.shareURLString.trimmingCharacters(in: .whitespaces).isEmpty)
            .padding(.horizontal, 24)

            Spacer().frame(height: 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [Color(.systemBackground), Color.blue.opacity(0.15)],
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
            Image(systemName: "figure.and.child.holdinghands")
                .font(.system(size: 56))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.blue, .purple],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            Text("Join Your Party")
                .font(.system(size: 28, weight: .heavy, design: .rounded))
            Text("Heroes partake in quests to earn gold and glory.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
        }
        .padding(.top, 24)
    }
}

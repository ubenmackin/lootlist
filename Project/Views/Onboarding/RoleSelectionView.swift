import SwiftUI

struct RoleSelectionView: View {
    @Bindable var viewModel: OnboardingViewModel

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text("Choose Your Path")
                    .font(.system(size: 32, weight: .heavy,
                                  design: .rounded))
                Text("Are you the master of a guild, or a brave hero?")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 32)

            Spacer()

            VStack(spacing: 20) {
                roleCard(
                    role: .guildMaster,
                    title: "I'm a Parent",
                    subtitle: "Found the family & become the Guild Master.",
                    icon: "crown.fill",
                    gradient: [.orange, .yellow]
                )

                roleCard(
                    role: .hero,
                    title: "I'm a Hero",
                    subtitle: "Join an existing guild to slay quests for gold.",
                    icon: "figure.and.child.holdinghands",
                    gradient: [.blue, .purple]
                )
            }
            .padding(.horizontal, 24)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [Color(.systemBackground), Color.purple.opacity(0.1)],
                startPoint: .top, endPoint: .bottom
            )
        )
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    viewModel.backToWelcome()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
            }
        }
    }

    private func roleCard(role: UserRole,
                          title: String,
                          subtitle: String,
                          icon: String,
                          gradient: [Color]) -> some View
    {
        Button {
            viewModel.selectedRole = role
            viewModel.advanceFromRoleSelection()
        } label: {
            HStack(spacing: 20) {
                Image(systemName: icon)
                    .font(.system(size: 36, weight: .semibold))
                    .frame(width: 72, height: 72)
                    .foregroundStyle(.white)
                    .background(
                        LinearGradient(
                            colors: gradient,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 18))

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .padding(20)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(.white.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("role.\(role.rawValue)")
    }
}

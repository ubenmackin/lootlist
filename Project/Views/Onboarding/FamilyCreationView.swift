//
//  FamilyCreationView.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import SwiftUI

struct FamilyCreationView: View {
    @Bindable var viewModel: OnboardingViewModel

    @FocusState private var isFieldFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header

                VStack(alignment: .leading, spacing: 12) {
                    Label("Name your guild", systemImage: "person.3.fill")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.primary)

                    TextField("The Pan Family", text: $viewModel.familyName)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .font(.title3)
                        .focused($isFieldFocused)
                        .submitLabel(.done)
                        .onSubmit {
                            isFieldFocused = false
                        }
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

                Button {
                    isFieldFocused = false
                    viewModel.advanceToAvatarSelection()
                } label: {
                    Label("Next: Forge Your Character", systemImage: "shield.fill")
                        .font(.headline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(DesignSystemConstants.Colors.pendingAmber))
                .disabled(viewModel.familyName.trimmingCharacters(in: .whitespaces).isEmpty)
                .padding(.horizontal, 24)
                .padding(.top, 16)
            }
            .padding(.vertical, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(
            LinearGradient(
                colors: [Color(DesignSystemConstants.Colors.background), Color(DesignSystemConstants.Colors.pendingAmber).opacity(0.12)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
        )
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    isFieldFocused = false
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
                        colors: [Color.gold, Color(DesignSystemConstants.Colors.pendingAmber)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            Text("Found Your Guild")
                .font(.system(size: 28, weight: .heavy, design: .rounded))
            Text("As Guild Master you'll set up a shared space "
                + "for the whole family.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
        }
        .padding(.top, 24)
    }
}

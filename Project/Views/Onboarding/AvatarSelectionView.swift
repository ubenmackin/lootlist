import SwiftUI

struct AvatarSelectionView: View {

    @Bindable var viewModel: OnboardingViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                header

                classGrid

                nameSection

                presetSection

                finalizeButton

                if let error = viewModel.error {
                    Text(error)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .accessibilityIdentifier("avatar.errorBanner")
                }
            }
            .padding(.vertical, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [Color(.systemBackground), Color.purple.opacity(0.1)],
                startPoint: .top, endPoint: .bottom))
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {

                    viewModel.pushBackFromAvatar()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 48))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.yellow, .purple],
                        startPoint: .top, endPoint: .bottom))
            Text("Forge Your Hero")
                .font(.system(size: 28, weight: .heavy, design: .rounded))
            Text("Choose a class, name your character, and pick a look.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }

    private var classGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Choose a class", systemImage: "shield.fill")
                .font(.headline.weight(.bold))

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ], spacing: 12) {
                ForEach(AvatarClass.allCases, id: \.self) { klass in
                    classCard(klass)
                }
            }
        }
        .padding(.horizontal, 24)
    }

    @ViewBuilder
    private func classCard(_ klass: AvatarClass) -> some View {
        let isSelected = viewModel.avatarClass == klass
        Button {
            viewModel.avatarClass = klass

            viewModel.avatarPresetID = nil
        } label: {
            VStack(spacing: 10) {
                Image(systemName: klass.iconSystemName)
                    .font(.system(size: 32, weight: .semibold))
                Text(klass.displayName)
                    .font(.headline.weight(.bold))
                Text(klass.tagline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .padding(.horizontal, 8)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(
                        isSelected ? Color.yellow : Color.white.opacity(0.15),
                        lineWidth: isSelected ? 3 : 1))
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.yellow)
                        .padding(8)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("avatar.class.\(klass.rawValue)")
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Name your hero", systemImage: "person.fill")
                .font(.headline.weight(.bold))
            TextField("Sir Cleanup", text: $viewModel.displayName)
                .textInputAutocapitalization(.words)
                .font(.title3)
                .padding(16)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(.white.opacity(0.15), lineWidth: 1))
                .accessibilityIdentifier("avatar.displayNameField")
        }
        .padding(.horizontal, 24)
    }

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Choose a look", systemImage: "wand.and.rays")
                .font(.headline.weight(.bold))

            HStack(spacing: 12) {
                ForEach(1...3, id: \.self) { variation in
                    presetButton(variation)
                }
            }
        }
        .padding(.horizontal, 24)
    }

    @ViewBuilder
    private func presetButton(_ variation: Int) -> some View {
        if let klass = viewModel.avatarClass {
            let presetID = String(format: "%@_%02d",
                                   klass.presetPrefix, variation)
            let isSelected = viewModel.avatarPresetID == presetID

            Button {
                viewModel.avatarPresetID = presetID
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: klass.iconSystemName)
                        .font(.system(size: 28, weight: .semibold))
                    Text("\(klass.displayName) \(variation)")
                        .font(.caption.weight(.medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(
                            isSelected ? Color.yellow : Color.white.opacity(0.15),
                            lineWidth: isSelected ? 3 : 1))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("avatar.preset.\(presetID)")
        } else {

            RoundedRectangle(cornerRadius: 12)
                .fill(Color.gray.opacity(0.1))
                .overlay(
                    Image(systemName: "questionmark")
                        .foregroundStyle(.secondary))
                .aspectRatio(1, contentMode: .fit)
        }
    }

    private var finalizeButton: some View {
        Button {
            Task {
                if viewModel.isParentFlow {
                    await viewModel.createFamily(name: viewModel.familyName)
                } else {
                    await viewModel.joinFamilyWithCode()
                }
            }
        } label: {
            HStack(spacing: 8) {
                if viewModel.isLoading {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "checkmark.shield.fill")
                }
                Text(finalizeLabel)
                    .font(.headline.weight(.bold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
        .buttonStyle(.borderedProminent)
        .tint(viewModel.isParentFlow ? .orange : .blue)
        .disabled(viewModel.isLoading
                    || viewModel.avatarClass == nil
                    || viewModel.displayName.trimmingCharacters(in: .whitespaces).isEmpty)
        .padding(.horizontal, 24)
        .accessibilityIdentifier("avatar.finalizeButton")
    }

    private var finalizeLabel: String {
        viewModel.isLoading
            ? "Forging..."
            : (viewModel.isParentFlow
                ? "Found the Guild"
                : "Join the Quest")
    }
}

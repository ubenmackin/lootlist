//
//  AvatarSelectionView.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import PhotosUI
import SwiftUI

/// Curated emoji set for lightweight avatar selection during onboarding.
/// Emoji are kept family-friendly and visually distinctive at small sizes.
private let onboardingEmojiGrid: [String] = [
    // Smileys & faces
    "😀", "😃", "😄", "😁", "😆", "😊", "😇", "🙂", "😉", "😍",
    "🥰", "😎", "🤩", "😋", "🤓", "🧐",
    // Animals
    "🐶", "🐱", "🐭", "🐹", "🐰", "🦊", "🐻", "🐼", "🐨", "🐯",
    "🦁", "🐮", "🐷", "🐸", "🐵", "🦄",
    // Nature & symbols
    "⭐", "🌟", "🔥", "🌈", "🌸", "🍀", "🌙", "💫",
    // Fun
    "🎨", "🎵", "🚀", "💎", "🎯"
]

struct AvatarSelectionView: View {
    @Bindable var viewModel: OnboardingViewModel

    @Environment(ToastManager.self) private var toastManager

    @FocusState private var isNameFocused: Bool
    @State private var isRPGExpanded: Bool = false
    @State private var selectedPhotoItem: PhotosPickerItem?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 7)

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header

                nameSection

                emojiGridSection

                if FeatureFlags.rpgImmersive {
                    rpgDisclosureSection
                }

                finalizeButton
            }
            .padding(.vertical, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: viewModel.error) { _, newError in
            if let error = newError {
                toastManager.show(message: error, type: .error)
            }
        }
        .background(
            LinearGradient(
                colors: [Color(.systemBackground), Color.purple.opacity(0.1)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
        )
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
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 48))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.yellow, .purple],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            Text("Setup Profile")
                .font(.system(size: 28, weight: .heavy, design: .rounded))
            Text("Enter your name and pick a profile emoji.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Your Name", systemImage: "person.fill")
                .font(.headline.weight(.bold))
            TextField("Alex", text: $viewModel.displayName)
                .textInputAutocapitalization(.words)
                .font(.title3)
                .focused($isNameFocused)
                .submitLabel(.done)
                .onSubmit {
                    isNameFocused = false
                }
                .padding(16)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                )
                .accessibilityIdentifier("avatar.displayNameField")
        }
        .padding(.horizontal, 24)
    }

    /// Lightweight emoji avatar picker — always visible regardless of
    /// whether the RPG immersive layer is enabled.
    private var emojiGridSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Choose a Profile Emoji", systemImage: "face.smiling")
                .font(.headline.weight(.bold))

            if let selectedEmoji = viewModel.avatarEmoji {
                HStack(spacing: 12) {
                    Text(selectedEmoji)
                        .font(.system(size: 44))
                        .frame(width: 56, height: 56)
                        .background(
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [Color.blue.opacity(0.3), Color.purple.opacity(0.3)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        )
                        .overlay(
                            Circle().strokeBorder(Color.gold.opacity(0.6), lineWidth: 2)
                        )

                    Text("Your emoji avatar appears next to your name throughout the app.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        viewModel.avatarEmoji = nil
                    } label: {
                        Text("Clear")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(.secondary)
                }
            }

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(onboardingEmojiGrid, id: \.self) { emoji in
                    let isSelected = viewModel.avatarEmoji == emoji
                    Button {
                        isNameFocused = false
                        viewModel.avatarEmoji = isSelected ? nil : emoji
                    } label: {
                        Text(emoji)
                            .font(.system(size: 24))
                            .frame(width: 36, height: 36)
                            .background(
                                Circle()
                                    .fill(isSelected ? Color.blue.opacity(0.25) : Color.clear)
                            )
                            .overlay(
                                Circle()
                                    .strokeBorder(
                                        isSelected ? Color.gold : Color.clear,
                                        lineWidth: 2
                                    )
                            )
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("avatar.emoji.\(emoji)")
                }
            }
        }
        .padding(16)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.white.opacity(0.15), lineWidth: 1)
        )
        .padding(.horizontal, 24)
    }

    /// RPG avatar customisation is hidden behind the feature flag so the
    /// default onboarding path stays lightweight (name + emoji only).
    private var rpgDisclosureSection: some View {
        DisclosureGroup(
            isExpanded: $isRPGExpanded,
            content: {
                VStack(alignment: .leading, spacing: 20) {
                    customPhotoSection
                    classGrid
                    presetSection
                }
                .padding(.top, 12)
            },
            label: {
                Label("RPG Customization (Class & Avatar)", systemImage: "sparkles")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.primary)
            }
        )
        .padding(16)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.white.opacity(0.15), lineWidth: 1)
        )
        .padding(.horizontal, 24)
    }

    private var customPhotoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Device Photo Avatar", systemImage: "photo.fill")
                .font(.subheadline.weight(.bold))

            HStack(spacing: 16) {
                if let customData = viewModel.customAvatarImageData,
                   let uiImage = UIImage(data: customData)
                {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 54, height: 54)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.gold, lineWidth: 2))
                } else {
                    Circle()
                        .fill(Color.gray.opacity(0.2))
                        .frame(width: 54, height: 54)
                        .overlay(Image(systemName: "person.fill").foregroundStyle(.secondary))
                }

                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    Label("Choose Photo", systemImage: "photo.on.rectangle")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)

                if viewModel.customAvatarImageData != nil {
                    Button(role: .destructive) {
                        viewModel.customAvatarImageData = nil
                        selectedPhotoItem = nil
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .onChange(of: selectedPhotoItem) { _, newItem in
            Task {
                if let data = try? await newItem?.loadTransferable(type: Data.self),
                   let rawImage = UIImage(data: data)
                {
                    let resized = resizeImageIfNeeded(rawImage, maxDimension: 512)
                    viewModel.customAvatarImageData = resized.jpegData(compressionQuality: 0.8)
                }
            }
        }
    }

    private var classGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Choose a Class (Optional)", systemImage: "shield.fill")
                .font(.subheadline.weight(.bold))

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ], spacing: 12) {
                ForEach(AvatarClass.allCases, id: \.self) { klass in
                    classCard(klass)
                }
            }
        }
    }

    @ViewBuilder
    private func classCard(_ klass: AvatarClass) -> some View {
        let isSelected = viewModel.avatarClass == klass
        Button {
            if isSelected {
                viewModel.avatarClass = nil
                viewModel.avatarPresetID = nil
            } else {
                viewModel.avatarClass = klass
                viewModel.avatarPresetID = nil
            }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: klass.iconSystemName)
                    .font(.system(size: 28, weight: .semibold))
                Text(klass.displayName)
                    .font(.subheadline.weight(.bold))
                Text(klass.tagline)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .padding(.horizontal, 6)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(
                        isSelected ? Color.yellow : Color.white.opacity(0.15),
                        lineWidth: isSelected ? 3 : 1
                    )
            )
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.yellow)
                        .padding(6)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("avatar.class.\(klass.rawValue)")
    }

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Choose a Look (Optional)", systemImage: "wand.and.rays")
                .font(.subheadline.weight(.bold))

            if let klass = viewModel.avatarClass {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10)
                ], spacing: 10) {
                    ForEach(AvatarPreset.presets(for: klass), id: \.self) { preset in
                        presetButton(preset)
                    }
                }
            } else {
                Text("Select an RPG class above to choose a preset avatar look.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func presetButton(_ preset: AvatarPreset) -> some View {
        let isSelected = viewModel.avatarPresetID == preset.id

        Button {
            viewModel.avatarPresetID = isSelected ? nil : preset.id
        } label: {
            ZStack {
                PixelCanvasView(sprite: HeroAvatarSprites.sprite(for: preset), animated: false)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 50 * 0.22, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 50 * 0.22, style: .continuous)
                            .stroke(Color.gold.opacity(0.6), lineWidth: 1.5)
                    )
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(
                        isSelected ? Color.yellow : Color.white.opacity(0.15),
                        lineWidth: isSelected ? 3 : 1
                    )
            )
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.yellow)
                        .padding(4)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("avatar.preset.\(preset.id)")
    }

    private var finalizeButton: some View {
        Button {
            Task {
                if viewModel.isParentFlow {
                    await viewModel.createFamily(name: viewModel.familyName)
                } else {
                    await viewModel.completeJoinedProfile()
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

    private func resizeImageIfNeeded(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let maxSide = max(image.size.width, image.size.height)
        guard maxSide > maxDimension else { return image }
        let scale = maxDimension / maxSide
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

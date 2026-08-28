//
//  EditAvatarSheet.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import os
import PhotosUI
import SwiftUI

/// Curated emoji set shared with onboarding for profile avatar selection.
private let profileEmojiGrid: [String] = [
    "😀", "😃", "😄", "😁", "😆", "😊", "😇", "🙂", "😉", "😍",
    "🥰", "😎", "🤩", "😋", "🤓", "🧐",
    "🐶", "🐱", "🐭", "🐹", "🐰", "🦊", "🐻", "🐼", "🐨", "🐯",
    "🦁", "🐮", "🐷", "🐸", "🐵", "🦄",
    "⭐", "🌟", "🔥", "🌈", "🌸", "🍀", "🌙", "💫",
    "🎨", "🎵", "🚀", "💎", "🎯"
]

/// Visual avatar and class editor for heroes, writing edits through ProfileService.
@MainActor
struct EditAvatarSheet: View {
    let profileCache: ProfileCache

    @Environment(ToastManager.self) private var toastManager
    @Environment(AppState.self) private var appState
    @Environment(FamilyService.self) private var familyService
    @Environment(\.dismiss) private var dismiss

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "EditAvatarSheet")

    @State private var selectedClass: AvatarClass?
    @State private var selectedPresetID: String?
    @State private var customData: Data?
    @State private var photoItem: PhotosPickerItem?
    @State private var selectedEmoji: String?
    @State private var isSaving: Bool = false

    private let emojiColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 8)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // 1. Live Hero Preview
                    livePreviewCard

                    // 2. Emoji avatar grid — always visible
                    emojiGridSection

                    if FeatureFlags.rpgImmersive {
                        // 3. Class Selection Grid
                        classSelectionSection

                        // 4. Look / Variant Sprite Grid
                        presetSelectionSection

                        // 5. Custom Device Photo Option
                        customPhotoSection

                        // 6. Reset Option
                        resetSection
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Customize Avatar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        saveAvatar()
                    } label: {
                        if isSaving {
                            ProgressView()
                                .tint(Color.gold)
                        } else {
                            Text("Save")
                                .font(.body.weight(.bold))
                                .foregroundStyle(Color.gold)
                        }
                    }
                    .disabled(isSaving)
                }
            }
            .onChange(of: photoItem) { _, newItem in
                Task {
                    guard let newItem else { return }
                    do {
                        guard let data = try await newItem.loadTransferable(type: Data.self) else { return }
                        customData = AvatarService.resizeImageData(data, maxDimension: 400)
                    } catch is CancellationError {
                        // user cancelled picker — no log/toast
                    } catch {
                        logger.debug("Avatar photo load failed: \(error, privacy: .private)")
                        toastManager.show(message: "Couldn’t load that photo. Try another.", type: .error)
                    }
                }
            }
            .onAppear {
                selectedClass = profileCache.avatarClassEnum
                selectedPresetID = profileCache.avatarName
                customData = profileCache.customAvatarImageData
                selectedEmoji = profileCache.avatarEmoji
            }
        }
    }

    // MARK: - Live Preview Card

    private var livePreviewCard: some View {
        VStack(spacing: 12) {
            ZStack {
                // Background radial glow
                RadialGradient(
                    colors: [
                        Color(DesignSystemConstants.Colors.accentBlue).opacity(0.4),
                        Color(DesignSystemConstants.Colors.accentBlue).opacity(0.2),
                        Color.clear
                    ],
                    center: .center,
                    startRadius: 10,
                    endRadius: 60
                )
                .frame(width: 120, height: 120)

                // Avatar Display
                if let customData, let uiImage = UIImage(data: customData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 84, height: 84)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.gold, lineWidth: 2.5))
                        .shadow(color: Color.black.opacity(0.4), radius: 8, x: 0, y: 4)
                } else if let emoji = selectedEmoji, !emoji.isEmpty {
                    // Emoji avatar preview — lightweight, always available path
                    Text(emoji)
                        .font(.system(size: 56))
                        .frame(width: 84, height: 84)
                        .background(
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color(DesignSystemConstants.Colors.accentBlue).opacity(0.3),
                                            Color(DesignSystemConstants.Colors.accentBlue).opacity(0.18)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        )
                        .overlay(
                            Circle().strokeBorder(Color.gold, lineWidth: 2.5)
                        )
                        .shadow(color: Color.black.opacity(0.4), radius: 8, x: 0, y: 4)
                } else if FeatureFlags.rpgImmersive {
                    // RPG sprite rendering — only when no emoji or photo is set
                    let resolvedPreset = currentResolvedPreset
                    let sprite = HeroAvatarSprites.sprite(
                        for: resolvedPreset ?? .knightV1,
                        equippedGear: profileCache.equippedItems ?? []
                    )

                    PixelCanvasView(sprite: sprite, animated: true)
                        .frame(width: 84, height: 84)
                        .shadow(color: Color.black.opacity(0.5), radius: 8, x: 0, y: 4)
                } else {
                    // When RPG is off and no emoji/photo, show fallback
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 64))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.gold)
                }
            }
            .frame(height: 94)

            // Character Name & Selected Look Tagline
            VStack(spacing: 3) {
                Text(profileCache.displayName)
                    .font(.title3.bold())
                    .foregroundStyle(.primary)

                if customData != nil {
                    Text("Custom Photo Avatar")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.gold)
                } else if let emoji = selectedEmoji, !emoji.isEmpty {
                    Text("Emoji Avatar \(emoji)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.gold)
                } else if FeatureFlags.rpgImmersive, let selectedClass {
                    let presetName = currentResolvedPreset?.displayName ?? selectedClass.displayName
                    Text("\(selectedClass.displayName) • \(presetName)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.gold)
                } else {
                    Text("Generic Hero Look")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                if !(profileCache.equippedItems ?? []).isEmpty {
                    Text("\((profileCache.equippedItems ?? []).count) equipped gear visible")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.gold.opacity(0.35), lineWidth: 1)
        )
    }

    // MARK: - Emoji Grid Section

    private var emojiGridSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Choose an Emoji Avatar", systemImage: "face.smiling")
                .font(.headline.weight(.bold))
                .foregroundStyle(.primary)

            LazyVGrid(columns: emojiColumns, spacing: 8) {
                ForEach(profileEmojiGrid, id: \.self) { emoji in
                    let isSelected = selectedEmoji == emoji
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            selectedEmoji = isSelected ? nil : emoji
                            // Choosing an emoji clears RPG selections so the
                            // emoji takes priority in the avatar render chain.
                            if selectedEmoji != nil {
                                customData = nil
                                photoItem = nil
                            }
                        }
                    } label: {
                        Text(emoji)
                            .font(.system(size: 28))
                            .frame(width: 38, height: 38)
                            .background(
                                Circle()
                                    .fill(isSelected ? Color(DesignSystemConstants.Colors.accentBlue).opacity(0.25) : Color.clear)
                            )
                            .overlay(
                                Circle()
                                    .strokeBorder(
                                        isSelected ? Color.gold : Color.clear,
                                        lineWidth: 2
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            if selectedEmoji != nil {
                HStack {
                    Spacer()
                    Button("Clear Emoji") {
                        withAnimation {
                            selectedEmoji = nil
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .tint(.secondary)
                    Spacer()
                }
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Class Selection Section

    // Gated behind FeatureFlags.rpgImmersive because this is the legacy RPG
    // avatar layer; the default profile path uses emoji-only avatars.

    private var classSelectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Select RPG Class", systemImage: "shield.fill")
                .font(.headline.weight(.bold))
                .foregroundStyle(.primary)

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
        let isSelected = selectedClass == klass && customData == nil

        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                customData = nil
                photoItem = nil
                if selectedClass == klass {
                    // Already selected: keep
                } else {
                    selectedClass = klass
                    selectedPresetID = AvatarService.defaultPresetID(for: klass)
                }
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: klass.iconSystemName)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.gold : .primary)

                Text(klass.displayName)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)

                Text(klass.tagline)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.gold : Color.white.opacity(0.12),
                        lineWidth: isSelected ? 2.5 : 1
                    )
            )
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.gold)
                        .padding(6)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Preset Look Grid

    @ViewBuilder
    private var presetSelectionSection: some View {
        if let klass = selectedClass, customData == nil {
            VStack(alignment: .leading, spacing: 12) {
                Label("Choose a Look", systemImage: "sparkles")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.primary)

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
            }
        }
    }

    @ViewBuilder
    private func presetButton(_ preset: AvatarPreset) -> some View {
        let isSelected = selectedPresetID == preset.id

        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                selectedPresetID = preset.id
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            VStack(spacing: 4) {
                let sprite = HeroAvatarSprites.sprite(for: preset, equippedGear: profileCache.equippedItems ?? [])
                PixelCanvasView(sprite: sprite, animated: false)
                    .frame(width: 48, height: 48)

                Text(presetShortName(preset))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.gold : .secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.gold : Color.white.opacity(0.12),
                        lineWidth: isSelected ? 2.5 : 1
                    )
            )
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.gold)
                        .padding(4)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func presetShortName(_ preset: AvatarPreset) -> String {
        "V\(preset.variationNumber)"
    }

    // MARK: - Custom Photo Section

    @ViewBuilder
    private var customPhotoSection: some View {
        let hasCustomPhoto = customData != nil

        VStack(alignment: .leading, spacing: 12) {
            Label("Device Photo Avatar", systemImage: "photo.fill")
                .font(.headline.weight(.bold))
                .foregroundStyle(.primary)

            HStack(spacing: 16) {
                if let customData, let uiImage = UIImage(data: customData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 50, height: 50)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.gold, lineWidth: 2))
                } else {
                    Circle()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 50, height: 50)
                        .overlay(Image(systemName: "person.fill").foregroundStyle(.secondary))
                }

                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label(hasCustomPhoto ? "Change Photo" : "Choose Photo", systemImage: "photo.on.rectangle")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(Color.gold)

                if hasCustomPhoto {
                    Button(role: .destructive) {
                        withAnimation {
                            customData = nil
                            photoItem = nil
                        }
                    } label: {
                        Image(systemName: "trash")
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
        }
    }

    // MARK: - Reset Section

    private var resetSection: some View {
        Button(role: .destructive) {
            withAnimation {
                selectedClass = nil
                selectedPresetID = nil
                customData = nil
                photoItem = nil
            }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } label: {
            HStack {
                Spacer()
                Label("Reset to Generic Hero", systemImage: "arrow.counterclockwise")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private var currentResolvedPreset: AvatarPreset? {
        guard let selectedClass else { return nil }
        return AvatarPreset.resolve(selectedClass, id: selectedPresetID)
            ?? AvatarPreset.presets(for: selectedClass).first
    }

    private func saveAvatar() {
        isSaving = true
        let targetClass = selectedClass
        let targetPresetID = selectedPresetID
        let targetCustomData = customData
        let targetEmoji = selectedEmoji
        Task {
            do {
                try await familyService.updateProfileAvatar(
                    profileCache: profileCache,
                    avatarClass: targetClass,
                    avatarPresetID: targetPresetID,
                    customAvatarImageData: targetCustomData,
                    avatarEmoji: targetEmoji
                )
                dismiss()
            } catch {
                toastManager.show(
                    message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                    type: .error
                )
                isSaving = false
            }
        }
    }
}

//
//  EditAvatarSheet.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import PhotosUI
import SwiftUI

/// Full visual avatar and class editor for heroes, featuring a live interactive preview
/// with equipped gear, visual RPG class selection cards, and a sprite variant grid.
@MainActor
struct EditAvatarSheet: View {
    let profile: Profile

    @Environment(ToastManager.self) private var toastManager
    @Environment(AppState.self) private var appState
    @Environment(FamilyService.self) private var familyService
    @Environment(\.dismiss) private var dismiss

    @State private var selectedClass: AvatarClass?
    @State private var selectedPresetID: String?
    @State private var customData: Data?
    @State private var photoItem: PhotosPickerItem?
    @State private var isSaving: Bool = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // 1. Live Hero Preview
                    livePreviewCard

                    // 2. Class Selection Grid
                    classSelectionSection

                    // 3. Look / Variant Sprite Grid
                    presetSelectionSection

                    // 4. Custom Device Photo Option
                    customPhotoSection

                    // 5. Reset Option
                    resetSection
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
                Task { @MainActor in
                    guard let newItem else { return }
                    if let data = try? await newItem.loadTransferable(type: Data.self) {
                        customData = AvatarService.resizeImageData(data, maxDimension: 400)
                    }
                }
            }
            .onAppear {
                selectedClass = profile.avatarClass
                selectedPresetID = profile.avatarPresetID
                customData = profile.customAvatarImageData
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
                        Color.purple.opacity(0.4),
                        Color.blue.opacity(0.2),
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
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 84, height: 84)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.gold, lineWidth: 2.5))
                        .shadow(color: Color.black.opacity(0.4), radius: 8, x: 0, y: 4)
                } else {
                    let resolvedPreset = currentResolvedPreset
                    let sprite = HeroAvatarSprites.sprite(
                        for: resolvedPreset ?? .knightV1,
                        equippedGear: profile.equippedItems
                    )

                    PixelCanvasView(sprite: sprite, animated: true)
                        .frame(width: 84, height: 84)
                        .shadow(color: Color.black.opacity(0.5), radius: 8, x: 0, y: 4)
                }
            }
            .frame(height: 94)

            // Character Name & Selected Look Tagline
            VStack(spacing: 3) {
                Text(profile.displayName)
                    .font(.title3.bold())
                    .foregroundStyle(.primary)

                if customData != nil {
                    Text("Custom Photo Avatar")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.gold)
                } else if let selectedClass {
                    let presetName = currentResolvedPreset?.displayName ?? selectedClass.displayName
                    Text("\(selectedClass.displayName) • \(presetName)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.gold)
                } else {
                    Text("Generic Hero Look")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                if !profile.equippedItems.isEmpty {
                    Text("\(profile.equippedItems.count) equipped gear visible")
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

    // MARK: - Class Selection Section

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
                let sprite = HeroAvatarSprites.sprite(for: preset, equippedGear: profile.equippedItems)
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
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 50, height: 50)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.gold, lineWidth: 2))
                } else {
                    Circle()
                        .fill(Color.gray.opacity(0.2))
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
        Task { @MainActor in
            do {
                try await familyService.updateProfileAvatar(
                    profile: profile,
                    avatarClass: targetClass,
                    avatarPresetID: targetPresetID,
                    customAvatarImageData: targetCustomData
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

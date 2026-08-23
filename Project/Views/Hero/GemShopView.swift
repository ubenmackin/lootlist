//
//  GemShopView.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import CloudKit
import os
import SwiftData
import SwiftUI

@MainActor
struct GemShopView: View {
    @Environment(AppState.self) private var appState
    @Environment(GemService.self) private var gemService
    @Environment(EquipmentService.self) private var equipmentService
    @Environment(AvatarService.self) private var avatarService
    @Environment(SoundManager.self) private var soundManager
    @Environment(ToastManager.self) private var toastManager

    @State private var selectedCategory: ShopCategory = .headwear
    @State private var pendingPurchaseItem: ShopItem?
    @State private var isPurchasing: Bool = false
    @State private var celebratedItem: ShopItem?
    @State private var showCelebration: Bool = false

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "GemShopView")

    private var currentProfile: Profile? {
        appState.currentProfile
    }

    private var gemBalance: Int? {
        guard let profile = currentProfile else { return nil }
        let familyRecordName = appState.family?.id.recordName ?? profile.family.recordID.recordName
        do {
            return try gemService.balance(for: profile.id.recordName, familyRecordName: familyRecordName)
        } catch {
            logger.warning("GemShopView.gemBalance: failed to fetch gem balance: \(error, privacy: .private)")
            return nil
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: DesignSystemConstants.Padding.large) {
                gemBalanceHeader
                liveAvatarPreview
                categoryPicker
                itemsGrid
            }
            .padding(.horizontal, DesignSystemConstants.Padding.standard)
            .padding(.vertical, DesignSystemConstants.Padding.standard)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Gem Shop")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if showCelebration, let item = celebratedItem {
                purchaseCelebrationOverlay(item: item)
            }
        }
        .confirmationDialog(
            "Purchase Item",
            isPresented: Binding(
                get: { pendingPurchaseItem != nil },
                set: {
                    if !$0 {
                        pendingPurchaseItem = nil
                    }
                }
            ),
            titleVisibility: .visible,
            presenting: pendingPurchaseItem
        ) { item in
            Button("Buy \(item.name) for \(item.gemPrice) 💎") {
                executePurchase(item)
            }
            Button("Cancel", role: .cancel) {
                pendingPurchaseItem = nil
            }
        } message: { item in
            if let gemBalance {
                Text("Are you sure you want to purchase \(item.name) for \(item.gemPrice) Gems?\nYour remaining balance will be \(max(0, gemBalance - item.gemPrice)) 💎.")
            } else {
                Text("Are you sure you want to purchase \(item.name) for \(item.gemPrice) Gems?")
            }
        }
    }

    // MARK: - Gem Balance Header

    private var gemBalanceHeader: some View {
        HStack(spacing: DesignSystemConstants.Padding.standard) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.gold.opacity(0.35), Color.clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 36
                        )
                    )
                    .frame(width: 56, height: 56)

                Text("💎")
                    .font(.system(size: 36))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Gem Balance")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(gemBalance.map(String.init) ?? "–")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.gold)
                        .contentTransition(.numericText())

                    Text("Gems")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(DesignSystemConstants.Padding.standard)
        .background(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.card, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.card, style: .continuous)
                .strokeBorder(Color.gold.opacity(0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(gemBalance.map { "Current Gem Balance: \($0) Gems" } ?? "Current Gem Balance unavailable")
    }

    // MARK: - Live Avatar Preview

    private var liveAvatarPreview: some View {
        VStack(spacing: DesignSystemConstants.Padding.medium) {
            HStack {
                Label("Hero Fitting Room", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.gold)
                Spacer()
                Text("Live Gear Preview")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let profile = currentProfile {
                let spec = avatarService.renderSpec(for: profile)
                let equipped = equipmentService.equippedItems(for: profile)

                ZStack {
                    // Aura Background Glow
                    if let aura = equipped[.auras] {
                        auraGlowView(aura: aura)
                    }

                    // Avatar View
                    VStack(spacing: 8) {
                        ZStack(alignment: .topTrailing) {
                            AvatarView(spec: spec, size: .large, showsNameAndTitle: false)
                                .padding(8)

                            // Headwear badge
                            if let headwear = equipped[.headwear] {
                                gearBadge(item: headwear, alignment: .topLeading)
                                    .offset(x: -8, y: -4)
                            }

                            // Weapon badge
                            if let weapon = equipped[.weapons] {
                                gearBadge(item: weapon, alignment: .bottomTrailing)
                                    .offset(x: 8, y: 8)
                            }

                            // Cape badge
                            if let cape = equipped[.capes] {
                                gearBadge(item: cape, alignment: .bottomLeading)
                                    .offset(x: -8, y: 8)
                            }

                            // Companion badge
                            if let companion = equipped[.companions] {
                                companionPreviewBadge(companion: companion)
                                    .offset(x: 48, y: -10)
                            }
                        }

                        Text(profile.displayName)
                            .font(.headline.weight(.bold))

                        Text(spec.levelTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.gold)
                    }
                }
                .padding(.vertical, DesignSystemConstants.Padding.medium)

                // Equipped Gear Pills
                if !equipped.isEmpty {
                    equippedPillsRow(equipped: equipped, profile: profile)
                } else {
                    Text("No cosmetics equipped. Pick gear below to customize your hero!")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
            } else {
                Text("No profile loaded")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(DesignSystemConstants.Padding.standard)
        .frame(maxWidth: .infinity)
        .background(
            ZStack {
                LinearGradient(
                    colors: [
                        Color.purple.opacity(0.20),
                        Color.blue.opacity(0.15),
                        Color.indigo.opacity(0.25)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                RadialGradient(
                    colors: [Color.gold.opacity(0.12), .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: 100
                )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.card, style: .continuous)
                .strokeBorder(Color.gold.opacity(0.30), lineWidth: 1)
        )
    }

    private func auraGlowView(aura _: ShopItem) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [Color.gold.opacity(0.4), Color.blue.opacity(0.25), .clear],
                    center: .center,
                    startRadius: 20,
                    endRadius: 90
                )
            )
            .frame(width: 180, height: 180)
            .overlay(
                Circle()
                    .strokeBorder(Color.gold.opacity(0.6), lineWidth: 2)
                    .scaleEffect(1.1)
            )
            .accessibilityHidden(true)
    }

    private func gearBadge(item: ShopItem, alignment _: Alignment) -> some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.7))
                .frame(width: 28, height: 28)
            Image(systemName: item.iconSystemName)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.gold)
        }
        .overlay(Circle().strokeBorder(Color.gold.opacity(0.6), lineWidth: 1))
        .accessibilityLabel("\(item.category.displayName): \(item.name)")
    }

    private func companionPreviewBadge(companion: ShopItem) -> some View {
        HStack(spacing: 4) {
            Image(systemName: companion.iconSystemName)
                .font(.system(size: 16))
                .foregroundStyle(Color.gold)
            Text(companion.name)
                .font(.caption2.bold())
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.black.opacity(0.75)))
        .overlay(Capsule().strokeBorder(Color.gold.opacity(0.6), lineWidth: 1))
        .accessibilityLabel("Companion: \(companion.name)")
    }

    private func equippedPillsRow(equipped: [ShopCategory: ShopItem], profile: Profile) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignSystemConstants.Padding.small) {
                ForEach(ShopCategory.allCases) { category in
                    if let item = equipped[category] {
                        Button {
                            equipmentService.unequip(category: category, profile: profile)
                            soundManager.play(.equipItem)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: item.iconSystemName)
                                    .font(.caption2)
                                Text(item.name)
                                    .font(.caption2.weight(.semibold))
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color(.tertiarySystemFill)))
                            .foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Equipped \(item.name). Tap to unequip.")
                    }
                }
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: - Category Picker

    private var categoryPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignSystemConstants.Padding.small) {
                ForEach(ShopCategory.allCases) { category in
                    let isSelected = selectedCategory == category
                    Button {
                        withAnimation(.snappy) {
                            selectedCategory = category
                        }
                        soundManager.play(.buttonTap)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: category.iconSystemName)
                                .font(.subheadline)
                            Text(category.displayName)
                                .font(.subheadline.weight(.semibold))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(isSelected ? Color.gold : Color(.secondarySystemGroupedBackground))
                        )
                        .foregroundStyle(isSelected ? Color.black : Color.primary)
                        .overlay(
                            Capsule()
                                .strokeBorder(isSelected ? Color.gold : Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(category.displayName)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
    }

    // MARK: - Items Grid

    private var itemsGrid: some View {
        let items = ShopItem.items(for: selectedCategory)
        let columns = [
            GridItem(.flexible(), spacing: DesignSystemConstants.Padding.medium),
            GridItem(.flexible(), spacing: DesignSystemConstants.Padding.medium)
        ]

        return LazyVGrid(columns: columns, spacing: DesignSystemConstants.Padding.medium) {
            ForEach(items) { item in
                itemCard(item: item)
            }
        }
    }

    @ViewBuilder
    private func itemCard(item: ShopItem) -> some View {
        if let profile = currentProfile {
            let isOwned = equipmentService.isOwned(item: item, profile: profile)
            let isEquipped = equipmentService.isEquipped(item: item, profile: profile)
            let isLocked = profile.level < item.requiredLevel
            let canAfford = gemBalance.map { $0 >= item.gemPrice } ?? false

            VStack(alignment: .leading, spacing: 10) {
                // Icon Header Box
                ZStack {
                    RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.small, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    categoryColor(for: item.category).opacity(0.35),
                                    Color.black.opacity(0.3)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(height: 90)

                    Image(systemName: item.iconSystemName)
                        .font(.system(size: 36))
                        .foregroundStyle(isLocked ? .secondary : Color.gold)
                        .symbolRenderingMode(.hierarchical)

                    // Badges
                    VStack {
                        HStack {
                            if isLocked {
                                Label("Lv \(item.requiredLevel)", systemImage: "lock.fill")
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(Color.black.opacity(0.75)))
                                    .foregroundStyle(.orange)
                            } else if isEquipped {
                                Label("EQUIPPED", systemImage: "checkmark")
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(Color.green))
                                    .foregroundStyle(.white)
                            } else if isOwned {
                                Text("OWNED")
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(Color.blue.opacity(0.8)))
                                    .foregroundStyle(.white)
                            }
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(6)
                }

                // Title & Description
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(item.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(height: 32, alignment: .topLeading)
                }

                Spacer(minLength: 0)

                // Action Button Area
                cardActionButton(item: item, profile: profile, isOwned: isOwned, isEquipped: isEquipped, isLocked: isLocked, canAfford: canAfford)
            }
            .padding(DesignSystemConstants.Padding.medium)
            .background(
                RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.card, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.card, style: .continuous)
                    .strokeBorder(isEquipped ? Color.green.opacity(0.6) : Color.gold.opacity(0.2), lineWidth: isEquipped ? 2 : 1)
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel(itemAccessibilityLabel(item: item, isLocked: isLocked, isEquipped: isEquipped, isOwned: isOwned))
        }
    }

    private func itemAccessibilityLabel(item: ShopItem, isLocked: Bool, isEquipped: Bool, isOwned: Bool) -> String {
        let statusText = isLocked ? "Locked" : (isEquipped ? "Currently Equipped" : (isOwned ? "Owned" : "Not Owned"))
        return "\(item.name), \(item.category.displayName). \(item.description). Price: \(item.gemPrice) gems. Required Level: \(item.requiredLevel). \(statusText)"
    }

    @ViewBuilder
    private func cardActionButton(
        item: ShopItem,
        profile: Profile,
        isOwned: Bool,
        isEquipped: Bool,
        isLocked: Bool,
        canAfford: Bool
    ) -> some View {
        if isLocked {
            HStack {
                Spacer()
                Label("Requires Lv. \(item.requiredLevel)", systemImage: "lock.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.button)
                    .fill(Color(.tertiarySystemFill))
            )
        } else if isEquipped {
            Button {
                equipmentService.unequip(category: item.category, profile: profile)
                soundManager.play(.equipItem)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Equipped")
                }
                .font(.caption.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
        } else if isOwned {
            Button {
                equipmentService.equip(item: item, profile: profile)
                soundManager.play(.equipItem)
            } label: {
                Text("Equip")
                    .font(.caption.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
            .tint(Color.gold)
        } else {
            Button {
                pendingPurchaseItem = item
            } label: {
                HStack(spacing: 4) {
                    Text("💎")
                    Text("\(item.gemPrice)")
                        .font(.caption.bold())
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(canAfford ? Color.gold : Color.gray)
            .disabled(!canAfford || isPurchasing)
        }
    }

    private func categoryColor(for category: ShopCategory) -> Color {
        switch category {
        case .headwear: .blue
        case .weapons: .red
        case .capes: .purple
        case .auras: .orange
        case .companions: .pink
        }
    }

    // MARK: - Purchase Action

    private func executePurchase(_ item: ShopItem) {
        guard let profile = currentProfile else { return }
        isPurchasing = true

        Task {
            defer {
                isPurchasing = false
                pendingPurchaseItem = nil
            }
            do {
                try await equipmentService.buyItem(
                    item: item,
                    profile: profile
                )

                celebratedItem = item
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                    showCelebration = true
                }
            } catch {
                toastManager.show(
                    message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                    type: .error
                )
            }
        }
    }

    // MARK: - Purchase Celebration Overlay

    private func purchaseCelebrationOverlay(item: ShopItem) -> some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.65))
                .background(.ultraThinMaterial)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation { showCelebration = false }
                }

            VStack(spacing: DesignSystemConstants.Padding.large) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [Color.gold.opacity(0.45), Color.orange.opacity(0.25)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(width: 100, height: 100)

                    Circle()
                        .strokeBorder(Color.gold, lineWidth: 2)
                        .frame(width: 100, height: 100)

                    Image(systemName: item.iconSystemName)
                        .font(.system(size: 44))
                        .foregroundStyle(Color.gold)
                }

                VStack(spacing: 6) {
                    Text("🎉 ITEM UNLOCKED!")
                        .font(.subheadline.bold())
                        .foregroundStyle(Color.gold)
                        .textCase(.uppercase)

                    Text(item.name)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)

                    Text(item.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    Text("Equipped to your Hero!")
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                        .padding(.top, 4)
                }

                Button {
                    withAnimation { showCelebration = false }
                } label: {
                    Text("Awesome!")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.gold)
                .padding(.horizontal, 32)
            }
            .padding(28)
            .background(
                RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.modal, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.modal, style: .continuous)
                    .strokeBorder(Color.gold.opacity(0.5), lineWidth: 1.5)
            )
            .padding(24)
            .scaleEffect(showCelebration ? 1.0 : DesignSystemConstants.Celebration.initialScale)
            .animation(.spring(response: 0.45, dampingFraction: 0.65), value: showCelebration)
        }
    }
}

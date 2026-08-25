//
//  SpriteGalleryView.swift
//  LootList
//
//  Created by Ben Mackin on 8/17/26.
//

import SwiftUI

struct SpriteGalleryView: View {
    @State private var category: GalleryCategory = .heroes
    @State private var index: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("Category", selection: $category) {
                Text("Heroes").tag(GalleryCategory.heroes)
                Text("Mascots").tag(GalleryCategory.mascots)
                Text("Gear").tag(GalleryCategory.gear)
            }
            .pickerStyle(.segmented)
            .padding()

            // Large sprite display
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.black.opacity(0.05))
                spriteView
                    .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal)

            // Item label
            Text(itemLabel)
                .font(.headline)
                .padding(.top, 12)

            Text("\(index + 1) of \(itemCount)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // Navigation buttons
            HStack(spacing: 40) {
                Button {
                    previous()
                } label: {
                    Image(systemName: "chevron.left.circle.fill")
                        .font(.title)
                }
                .disabled(itemCount <= 1)

                Button {
                    next()
                } label: {
                    Image(systemName: "chevron.right.circle.fill")
                        .font(.title)
                }
                .disabled(itemCount <= 1)
            }
            .padding()
        }
        .navigationTitle("Sprite Gallery")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: category) { _, _ in
            index = 0
        }
    }

    // MARK: - Sprite Rendering

    @ViewBuilder
    private var spriteView: some View {
        switch category {
        case .heroes:
            let preset = AvatarPreset.allCases[index]
            PixelCanvasView(sprite: HeroAvatarSprites.sprite(for: preset), animated: false)
                .frame(width: 300, height: 300)

        case .mascots:
            let item = mascotItems[index]
            PixelCanvasView(
                sprite: MascotSpriteRenderer.sprite(
                    for: item.companion,
                    state: item.state,
                    frameIndex: item.frame
                ),
                animated: false
            )
            .frame(width: 300, height: 300)

        case .gear:
            let item = gearItems[index]
            PixelCanvasView(
                sprite: HeroAvatarSprites.sprite(
                    for: .knightV1,
                    equippedGear: [item.id]
                ),
                animated: false
            )
            .frame(width: 300, height: 300)
        }
    }

    // MARK: - Data

    enum GalleryCategory: Hashable {
        case heroes, mascots, gear
    }

    struct MascotItem {
        let companion: MascotCompanion
        let state: MascotState
        let frame: Int
    }

    struct GearItem {
        let id: String
        let name: String
    }

    private var mascotItems: [MascotItem] {
        let states: [MascotState] = [.idle, .inProgress, .encouraging, .celebrating, .bonusClaimed]
        var items: [MascotItem] = []
        for companion in MascotCompanion.allCases {
            for state in states {
                for frame in 0 ..< 2 {
                    items.append(MascotItem(companion: companion, state: state, frame: frame))
                }
            }
        }
        return items
    }

    private let gearItems: [GearItem] = [
        GearItem(id: "headwear_crown", name: "Crown"),
        GearItem(id: "headwear_bandana", name: "Bandana"),
        GearItem(id: "headwear_viking_helm", name: "Viking Helm"),
        GearItem(id: "headwear_knight_visor", name: "Knight Visor"),
        GearItem(id: "headwear_wizard_hat", name: "Wizard Hat"),
        GearItem(id: "weapon_flaming_sword", name: "Flaming Sword"),
        GearItem(id: "weapon_astral_staff", name: "Astral Staff"),
        GearItem(id: "weapon_holy_mace", name: "Holy Mace"),
        GearItem(id: "weapon_dragon_bow", name: "Dragon Bow"),
        GearItem(id: "weapon_shadow_daggers", name: "Shadow Daggers"),
        GearItem(id: "cape_shadow_cloak", name: "Shadow Cloak"),
        GearItem(id: "cape_royal_cape", name: "Royal Cape"),
        GearItem(id: "cape_frostweave", name: "Frostweave"),
        GearItem(id: "cape_phoenix_wings", name: "Phoenix Wings"),
        GearItem(id: "golden_wings", name: "Golden Wings"),
        GearItem(id: "aura_cosmic", name: "Cosmic Aura"),
        GearItem(id: "aura_starlight", name: "Star Aura"),
        GearItem(id: "aura_mystic_runes", name: "Mystic Runes"),
        GearItem(id: "aura_lightning", name: "Lightning"),
        GearItem(id: "sparkles", name: "Sparkles"),
        GearItem(id: "companion_glow_sprite", name: "Glow Sprite")
    ]

    // MARK: - Computed

    private var itemCount: Int {
        switch category {
        case .heroes: AvatarPreset.allCases.count
        case .mascots: mascotItems.count
        case .gear: gearItems.count
        }
    }

    private var itemLabel: String {
        switch category {
        case .heroes:
            return AvatarPreset.allCases[index].displayName
        case .mascots:
            let item = mascotItems[index]
            return "\(item.companion.name) (\(item.companion.rawValue.capitalized)) — \(stateLabel(item.state)) — Frame \(item.frame == 0 ? "A" : "B")"
        case .gear:
            return gearItems[index].name
        }
    }

    private func stateLabel(_ state: MascotState) -> String {
        switch state {
        case .idle: "Idle"
        case .inProgress: "In Progress"
        case .encouraging: "Encouraging"
        case .celebrating: "Celebrating"
        case .bonusClaimed: "Bonus Claimed"
        }
    }

    // MARK: - Navigation

    private func next() {
        index = (index + 1) % itemCount
    }

    private func previous() {
        index = (index - 1 + itemCount) % itemCount
    }
}

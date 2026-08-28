//
//  HeroAvatarSprites+Equipment.swift
//  LootList
//
//  Created by Ben Mackin on 8/17/26.
//

import SwiftUI

extension HeroAvatarSprites {
    // MARK: - Equipment Layers

    // Gear grids are generated at full 64x64 canvas resolution (1px density, matching the pixel bases) by
    // tools/generate_pixel_gear.py, so they stamp at scale 1 with no offset.

    private static func gearLayer(
        id: String,
        grid: [String],
        palette: [Character: Color],
        zIndex: Int
    ) -> PixelLayer {
        stampedLayer(id: id, grid: grid, palette: palette, zIndex: zIndex, originX: 0, originY: 0, scale: 1)
    }

    // MARK: Crown (foreground)

    static func crownLayer() -> PixelLayer {
        gearLayer(
            id: "gear_crown",
            grid: HeroAvatarPixelGear.CrownGrid,
            palette: HeroAvatarPixelGear.CrownPalette,
            zIndex: 25
        )
    }

    // MARK: Wizard Hat (foreground)

    static func wizardHatLayer() -> PixelLayer {
        gearLayer(
            id: "gear_wizard_hat",
            grid: HeroAvatarPixelGear.WizardHatGrid,
            palette: HeroAvatarPixelGear.WizardHatPalette,
            zIndex: 25
        )
    }

    // MARK: Flaming Sword (foreground)

    static func flamingSwordLayer() -> PixelLayer {
        gearLayer(
            id: "gear_flaming_sword",
            grid: HeroAvatarPixelGear.FlamingSwordGrid,
            palette: HeroAvatarPixelGear.FlamingSwordPalette,
            zIndex: 25
        )
    }

    // MARK: Crystal Staff (foreground)

    static func crystalStaffLayer() -> PixelLayer {
        gearLayer(
            id: "gear_crystal_staff",
            grid: HeroAvatarPixelGear.CrystalStaffGrid,
            palette: HeroAvatarPixelGear.CrystalStaffPalette,
            zIndex: 25
        )
    }

    // MARK: Golden Wings (background)

    static func goldenWingsLayer() -> PixelLayer {
        gearLayer(
            id: "gear_golden_wings",
            grid: HeroAvatarPixelGear.GoldenWingsGrid,
            palette: HeroAvatarPixelGear.GoldenWingsPalette,
            zIndex: -5
        )
    }

    // MARK: Shadow Cloak (background)

    static func shadowCloakLayer() -> PixelLayer {
        gearLayer(
            id: "gear_shadow_cloak",
            grid: HeroAvatarPixelGear.ShadowCloakGrid,
            palette: HeroAvatarPixelGear.ShadowCloakPalette,
            zIndex: -5
        )
    }

    // MARK: Bandana (foreground)

    static func bandanaLayer() -> PixelLayer {
        gearLayer(id: "gear_bandana", grid: HeroAvatarPixelGear.BandanaGrid,
                  palette: HeroAvatarPixelGear.BandanaPalette, zIndex: 25)
    }

    // MARK: Viking Helm (foreground)

    static func vikingHelmLayer() -> PixelLayer {
        gearLayer(id: "gear_viking_helm", grid: HeroAvatarPixelGear.VikingHelmGrid,
                  palette: HeroAvatarPixelGear.VikingHelmPalette, zIndex: 25)
    }

    // MARK: Knight Visor (foreground)

    static func knightVisorLayer() -> PixelLayer {
        gearLayer(id: "gear_knight_visor", grid: HeroAvatarPixelGear.KnightVisorGrid,
                  palette: HeroAvatarPixelGear.KnightVisorPalette, zIndex: 25)
    }

    // MARK: Shadow Daggers (foreground)

    static func shadowDaggersLayer() -> PixelLayer {
        gearLayer(id: "gear_shadow_daggers", grid: HeroAvatarPixelGear.ShadowDaggersGrid,
                  palette: HeroAvatarPixelGear.ShadowDaggersPalette, zIndex: 25)
    }

    // MARK: Holy Mace (foreground)

    static func holyMaceLayer() -> PixelLayer {
        gearLayer(id: "gear_holy_mace", grid: HeroAvatarPixelGear.HolyMaceGrid,
                  palette: HeroAvatarPixelGear.HolyMacePalette, zIndex: 25)
    }

    // MARK: Dragon Bow (foreground)

    static func dragonBowLayer() -> PixelLayer {
        gearLayer(id: "gear_dragon_bow", grid: HeroAvatarPixelGear.DragonBowGrid,
                  palette: HeroAvatarPixelGear.DragonBowPalette, zIndex: 25)
    }

    // MARK: Royal Cape (background)

    static func royalCapeLayer() -> PixelLayer {
        gearLayer(id: "gear_royal_cape", grid: HeroAvatarPixelGear.RoyalCapeGrid,
                  palette: HeroAvatarPixelGear.RoyalCapePalette, zIndex: -6)
    }

    // MARK: Frostweave (background)

    static func frostweaveLayer() -> PixelLayer {
        gearLayer(id: "gear_frostweave", grid: HeroAvatarPixelGear.FrostweaveGrid,
                  palette: HeroAvatarPixelGear.FrostweavePalette, zIndex: -6)
    }

    // MARK: Mystic Runes (background)

    static func mysticRunesLayer() -> PixelLayer {
        gearLayer(id: "gear_mystic_runes", grid: HeroAvatarPixelGear.MysticRunesGrid,
                  palette: HeroAvatarPixelGear.MysticRunesPalette, zIndex: -8)
    }

    // MARK: Phoenix Wings (background)

    static func phoenixWingsLayer() -> PixelLayer {
        gearLayer(id: "gear_phoenix_wings", grid: HeroAvatarPixelGear.PhoenixWingsGrid,
                  palette: HeroAvatarPixelGear.PhoenixWingsPalette, zIndex: -5)
    }

    // MARK: Glow Sprite companion (foreground)

    static func glowSpriteLayer() -> PixelLayer {
        gearLayer(id: "gear_glow_sprite", grid: HeroAvatarPixelGear.GlowSpriteGrid,
                  palette: HeroAvatarPixelGear.GlowSpritePalette, zIndex: 15)
    }

    // MARK: Familiar Cat companion (foreground)

    static func familiarCatLayer() -> PixelLayer {
        gearLayer(id: "gear_familiar_cat", grid: HeroAvatarPixelGear.FamiliarCatGrid,
                  palette: HeroAvatarPixelGear.FamiliarCatPalette, zIndex: 15)
    }

    // MARK: Baby Griffin companion (foreground)

    static func babyGriffinLayer() -> PixelLayer {
        gearLayer(id: "gear_baby_griffin", grid: HeroAvatarPixelGear.BabyGriffinGrid,
                  palette: HeroAvatarPixelGear.BabyGriffinPalette, zIndex: 15)
    }

    // MARK: Dragon Hatchling companion (foreground)

    static func dragonHatchlingLayer() -> PixelLayer {
        gearLayer(id: "gear_dragon_hatchling", grid: HeroAvatarPixelGear.DragonHatchlingGrid,
                  palette: HeroAvatarPixelGear.DragonHatchlingPalette, zIndex: 15)
    }

    // MARK: Cosmic Aura (background ring + foreground sparkle)

    static func cosmicAuraBackgroundLayer() -> PixelLayer {
        gearLayer(
            id: "gear_cosmic_aura_bg",
            grid: HeroAvatarPixelGear.StarAuraGrid,
            palette: HeroAvatarPixelGear.StarAuraPalette,
            zIndex: -10
        )
    }

    static func cosmicAuraForegroundLayer() -> PixelLayer {
        gearLayer(
            id: "gear_cosmic_aura_fg",
            grid: HeroAvatarPixelGear.SparklesGrid,
            palette: HeroAvatarPixelGear.SparklesPalette,
            zIndex: 20
        )
    }

    // MARK: Lightning Sparks (background)

    static func lightningSparksBackgroundLayer() -> PixelLayer {
        gearLayer(
            id: "gear_lightning",
            grid: HeroAvatarPixelGear.LightningGrid,
            palette: HeroAvatarPixelGear.LightningPalette,
            zIndex: -8
        )
    }

    // MARK: Sparkles (foreground)

    static func sparklesLayer() -> PixelLayer {
        gearLayer(
            id: "gear_sparkles",
            grid: HeroAvatarPixelGear.SparklesGrid,
            palette: HeroAvatarPixelGear.SparklesPalette,
            zIndex: 20
        )
    }

    // MARK: Star Aura (background)

    static func starAuraLayer() -> PixelLayer {
        gearLayer(
            id: "gear_star_aura",
            grid: HeroAvatarPixelGear.StarAuraGrid,
            palette: HeroAvatarPixelGear.StarAuraPalette,
            zIndex: -10
        )
    }
}

//
//  HeroAvatarSprites+Accessories.swift
//  LootList
//
//  Created by Ben Mackin on 8/21/26.
//

import SwiftUI

// MARK: - Class Accessory Overlays

//
// Stamped onto the traced base grids (24x30) before upscaling.
// Characters are restricted to the uppercase accessory set defined in
// tools/generate_hero_bases.py (ACCESSORY_COLORS) so they never collide
// with k-means cluster characters and always have palette entries.

extension HeroAvatarSprites {
    static func accessoryOverlays(for cls: AvatarClass) -> [SpriteOverlay] {
        switch cls {
        case .knight: knightOverlays
        case .mage: mageOverlays
        case .rogue: rogueOverlays
        case .guardian: guardianOverlays
        case .healer: healerOverlays
        }
    }

    // MARK: Knight — helm + plume, sword, heater shield

    private static let knightOverlays: [SpriteOverlay] = [
        SpriteOverlay(grid: knightHelm, offsetX: 0, offsetY: 0),
        SpriteOverlay(grid: knightSword, offsetX: 0, offsetY: 12),
        SpriteOverlay(grid: knightShield, offsetX: 17, offsetY: 13)
    ]

    private static let knightHelm: [String] = [
        "..........JJJ...........",
        ".........JJJJJ..........",
        "...kkkkkkkkkkkkkkkkk....",
        "..kMMMMMMMMMMMMMMMMMk...",
        ".kMEMMMMMMMMMMMMMMMMNk..",
        ".kMMMMMMMMMMMMMMMMMMNk..",
        "kMMMMMMMMMMMMMMMMMMMNNk.",
        "kMEMMMMMMMMMMMMMMMMMMNk.",
        "kMMMMMMMMMMMMMMMMMMMMNk.",
        "kNNNNNNNNNNNNNNNNNNNNNk."
    ]

    private static let knightSword: [String] = [
        ".EM.",
        ".EM.",
        ".EM.",
        ".EM.",
        ".EM.",
        ".EM.",
        ".EM.",
        ".EM.",
        ".EM.",
        ".EM.",
        "GGGG",
        ".K..",
        ".K..",
        ".G.."
    ]

    private static let knightShield: [String] = [
        "kkkkkkk",
        "MEMEMEM",
        "MEEJEEM",
        "MEJJJEM",
        "MEEJEEM",
        "MNNNNNM",
        ".kNMNk.",
        "..kkk.."
    ]

    // MARK: Mage — floppy hat, staff with glowing orb

    private static let mageOverlays: [SpriteOverlay] = [
        SpriteOverlay(grid: mageHat, offsetX: 0, offsetY: 0),
        SpriteOverlay(grid: mageStaff, offsetX: 0, offsetY: 3)
    ]

    private static let mageHat: [String] = [
        "............kk..........",
        "...........kPPk.........",
        "..........kPPPPk........",
        ".........kPPPPPPk.......",
        "........kPPPPPPPPk......",
        ".......kPPXPPPPPPPk.....",
        "......kGGGGGGGGGGGGk....",
        "....kPPPPPPPPPPPPPPPPk..",
        "...kPPPPPPPPPPPPPPPPPPk."
    ]

    private static let mageStaff: [String] = [
        ".QQ.",
        "QFFQ",
        "QFFQ",
        ".QQ.",
        ".TT.",
        ".TT.",
        ".TT.",
        ".TT.",
        ".TT.",
        ".TT.",
        ".TT.",
        ".TT.",
        ".GG.",
        ".TT.",
        ".TT.",
        ".TT.",
        ".TT.",
        ".TT.",
        ".TT.",
        ".TT.",
        ".TT.",
        ".TT.",
        ".TT.",
        ".TT.",
        ".TT.",
        ".TT."
    ]

    // MARK: Rogue — hood, dagger

    private static let rogueOverlays: [SpriteOverlay] = [
        SpriteOverlay(grid: rogueHood, offsetX: 3, offsetY: 0),
        SpriteOverlay(grid: rogueDagger, offsetX: 21, offsetY: 14)
    ]

    private static let rogueHood: [String] = [
        "........ZZZZ......",
        "......ZZZZZZZZ....",
        ".....ZZZZZZZZZZ...",
        "....ZZZZZZZZZZZZ..",
        "...ZZZZZZZZZZZZZZ.",
        "...ZZZZZZZZZZZZZZ.",
        "...ZZ..........ZZ.",
        "...ZZ..........ZZ.",
        "..ZZZ..........ZZZ"
    ]

    private static let rogueDagger: [String] = [
        "EM",
        "EM",
        "EM",
        "EM",
        "GG",
        "K.",
        "G."
    ]

    // MARK: Guardian — great helm, pauldrons, tower shield

    private static let guardianOverlays: [SpriteOverlay] = [
        SpriteOverlay(grid: guardianHelm, offsetX: 2, offsetY: 0),
        SpriteOverlay(grid: guardianPauldrons, offsetX: 1, offsetY: 13),
        SpriteOverlay(grid: guardianTowerShield, offsetX: 16, offsetY: 12)
    ]

    private static let guardianHelm: [String] = [
        "......kkkkkkkk......",
        "....kkMMMMMMMMkk....",
        "...kMMMMMMMMMMMMk...",
        "..kMEMMMMMMMMMMMNk..",
        "..kMMMMMMMMMMMMMNk..",
        "..kUUUUUUUUUUUUUUk..",
        "..kMMMMMMMMMMMMMNk..",
        "..kMMMMMMMMMMMMMNk..",
        "...kMMMMMMMMMMMMk...",
        "...kNNNNNNNNNNNNk..."
    ]

    private static let guardianPauldrons: [String] = [
        "MMMMEEEEEEEEEEEEMMMM",
        "NMMMEEEEEEEEEEEEMMN"
    ]

    private static let guardianTowerShield: [String] = [
        "kkkkkkkk",
        "MEMEEEEM",
        "MEEGGEEM",
        "MEGHHGEM",
        "MEEGGEEM",
        "MEEEEEM.",
        "MENNNNM.",
        ".kMNMNk.",
        "..kkkk.."
    ]

    // MARK: Healer — white cowl, staff with golden cross

    private static let healerOverlays: [SpriteOverlay] = [
        SpriteOverlay(grid: healerCowl, offsetX: 3, offsetY: 0),
        SpriteOverlay(grid: healerStaff, offsetX: 0, offsetY: 3)
    ]

    private static let healerCowl: [String] = [
        "........WWWW......",
        "......WWWWWWWW....",
        ".....WWWWWWWWWW...",
        "....WWWGGGGGWWW...", // gold band across brow
        "...WWWWWWWWWWWWWW.",
        "...WWWWWWWWWWWWWW.",
        "...WW..........WW.",
        "...WW..........WW.",
        "..WWW..........WWW"
    ]

    private static let healerStaff: [String] = [
        ".G..",
        "GGG.",
        ".G..",
        ".G..",
        ".K..",
        ".K..",
        ".K..",
        ".K..",
        ".K..",
        ".K..",
        ".K..",
        ".K..",
        ".K..",
        ".K..",
        ".K..",
        ".K..",
        ".K..",
        ".K..",
        ".K..",
        ".K..",
        ".K..",
        ".K..",
        ".K..",
        ".K..",
        ".K..",
        ".K.."
    ]
}

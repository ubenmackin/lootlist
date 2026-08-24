#!/usr/bin/env python3
"""Hand-authored semantic chibi bases (Option B).

Emits Project/Resources/SpriteData/HeroAvatarSprites+TracedGrids.swift with:
  - male/female base templates on a lowercase-only semantic alphabet
    (no collision with the uppercase accessory charset)
  - one palette per class/variant: semantic base colors + shared accessory colors

Every grid row is asserted to be nativeWidth chars so malformed art fails here,
not in Xcode.
"""

NATIVE_W = 24

# Semantic alphabet:
#   . transparent   k outline      w highlight(glint)
#   h hair          i hair shadow  e eye
#   s skin          r skin shadow
#   b tunic         d tunic shade  a sleeve
#   m belt          v pants        u boots


def R(s):
    assert len(s) == NATIVE_W, f"row '{s}' is {len(s)} wide, want {NATIVE_W}"
    return s


def male_base():
    g = []
    g.append(R("." * 6 + "k" * 12 + "." * 6))                      # 0 crown
    g.append(R("." * 5 + "kk" + "h" * 10 + "kk" + "." * 5))        # 1
    g.append(R("." * 4 + "k" + "h" * 14 + "k" + "." * 4))          # 2
    for _ in range(3):                                             # 3-5 dome
        g.append(R("." * 3 + "k" + "h" * 16 + "k" + "." * 3))
    g.append(R("." * 3 + "k" + "hh" + "i" * 12 + "hh" + "k" + "." * 3))   # 6 fringe shadow
    g.append(R("." * 3 + "k" + "hh" + "s" * 12 + "hh" + "k" + "." * 3))   # 7 forehead
    g.append(R("." * 3 + "k" + "hh" + "s" + "we" + "ssssss" + "we" + "s" + "hh" + "k" + "." * 3))  # 8 eyes+glints
    g.append(R("." * 3 + "k" + "hh" + "s" + "ee" + "ssssss" + "ee" + "s" + "hh" + "k" + "." * 3))  # 9 eyes solid
    g.append(R("." * 3 + "k" + "hh" + "s" * 12 + "hh" + "k" + "." * 3))   # 10 cheeks
    g.append(R("." * 3 + "k" + "hh" + "s" * 10 + "rr" + "hh" + "k" + "." * 3))  # 11 cheek shade
    g.append(R("." * 4 + "k" + "s" * 12 + "rr" + "k" + "." * 4))   # 12 jaw
    g.append(R("." * 6 + "k" + "s" * 10 + "k" + "." * 6))          # 13 neck
    g.append(R("." * 4 + "k" + "b" * 14 + "k" + "." * 4))          # 14 shoulders
    g.append(R("." * 3 + "k" + "b" * 16 + "k" + "." * 3))          # 15 chest
    g.append(R("." * 3 + "k" + "aa" + "b" * 12 + "aa" + "k" + "." * 3))   # 16 arms
    g.append(R("." * 3 + "k" + "aa" + "b" * 9 + "ddd" + "aa" + "k" + "." * 3))  # 17 arms+shade
    g.append(R("." * 3 + "k" + "ss" + "b" * 9 + "ddd" + "ss" + "k" + "." * 3))  # 18 hands
    g.append(R("." * 3 + "k" + "m" * 16 + "k" + "." * 3))          # 19 belt
    g.append(R("." * 4 + "k" + "v" * 14 + "k" + "." * 4))          # 20 hips
    g.append(R("." * 5 + "k" + "v" * 12 + "k" + "." * 5))          # 21 taper
    for _ in range(5):                                             # 22-26 legs split
        g.append(R("." * 5 + "k" + "vvvvv" + "kk" + "vvvvv" + "k" + "." * 5))
    for _ in range(3):                                             # 27-29 boots
        g.append(R("." * 5 + "k" + "uuuuu" + "kk" + "uuuuu" + "k" + "." * 5))
    return g


def female_base():
    g = []
    g.append(R("." * 6 + "k" * 12 + "." * 6))                      # 0 crown
    g.append(R("." * 5 + "kk" + "h" * 10 + "kk" + "." * 5))        # 1
    g.append(R("." * 4 + "k" + "h" * 14 + "k" + "." * 4))          # 2
    for _ in range(3):
        g.append(R("." * 3 + "k" + "h" * 16 + "k" + "." * 3))      # 3-5 dome
    g.append(R("." * 3 + "k" + "hh" + "i" * 12 + "hh" + "k" + "." * 3))   # 6 fringe shadow
    g.append(R("." * 3 + "k" + "hh" + "s" * 12 + "hh" + "k" + "." * 3))   # 7 forehead
    g.append(R("." * 3 + "k" + "hh" + "s" + "we" + "ssssss" + "we" + "s" + "hh" + "k" + "." * 3))  # 8 eyes
    g.append(R("." * 3 + "k" + "hh" + "s" + "ee" + "ssssss" + "ee" + "s" + "hh" + "k" + "." * 3))  # 9 eyes solid
    g.append(R("." * 3 + "k" + "hh" + "s" * 12 + "hh" + "k" + "." * 3))   # 10 cheeks
    g.append(R("." * 3 + "k" + "hh" + "s" * 10 + "rr" + "hh" + "k" + "." * 3))  # 11 cheek shade
    g.append(R("." * 4 + "k" + "s" * 12 + "rr" + "k" + "." * 4))   # 12 jaw
    g.append(R("." * 4 + "k" + "hh" + "s" * 10 + "hh" + "k" + "." * 4))   # 13 neck + locks
    g.append(R("." * 4 + "k" + "hh" + "b" * 10 + "hh" + "k" + "." * 4))   # 14 shoulders + locks
    g.append(R("." * 4 + "k" + "hh" + "b" * 10 + "hh" + "k" + "." * 4))   # 15 locks end
    g.append(R("." * 4 + "k" + "aa" + "b" * 10 + "aa" + "k" + "." * 4))   # 16 arms
    g.append(R("." * 4 + "k" + "aa" + "b" * 8 + "dd" + "aa" + "k" + "." * 4))   # 17 arms+shade
    g.append(R("." * 4 + "k" + "ss" + "b" * 8 + "dd" + "ss" + "k" + "." * 4))   # 18 hands
    g.append(R("." * 4 + "k" + "m" * 14 + "k" + "." * 4))          # 19 belt
    g.append(R("." * 4 + "k" + "v" * 14 + "k" + "." * 4))          # 20 skirt
    g.append(R("." * 3 + "k" + "v" * 16 + "k" + "." * 3))          # 21 skirt flare
    g.append(R("." * 3 + "k" + "d" * 16 + "k" + "." * 3))          # 22 hem shade
    g.append(R("." * 5 + "k" + "v" * 12 + "k" + "." * 5))          # 23 legs
    for _ in range(3):                                             # 24-26 together
        g.append(R("." * 6 + "k" + "v" * 10 + "k" + "." * 6))
    for _ in range(3):                                             # 27-29 boots
        g.append(R("." * 6 + "k" + "u" * 10 + "k" + "." * 6))
    return g


# Per-class outfit colors (main, shade) keyed [class][variant 1-4]
OUTFITS = {
    "knight":   [(0x2563EB, 0x1E3A8A), (0xDC2626, 0x7F1D1D), (0x15803D, 0x14532D), (0x7C3AED, 0x4C1D95)],
    "mage":     [(0x7C3AED, 0x4C1D95), (0x0891B2, 0x155E75), (0xC026D3, 0x701A75), (0xEA580C, 0x7C2D12)],
    "rogue":    [(0x166534, 0x052E16), (0x475569, 0x1E293B), (0x6B21A8, 0x3B0764), (0x991B1B, 0x450A0A)],
    "guardian": [(0x64748B, 0x334155), (0x505A8A, 0x272E48), (0x9F5F80, 0x5C3049), (0xB45309, 0x713306)],
    "healer":   [(0xC9A83C, 0x8A7322), (0x6B9E4E, 0x3F6130), (0xC26478, 0x7A3A4B), (0x7BA43C, 0x4A6622)],
}

# Hair & skin tones per variant (V1-V4)
HAIR = [(0x6B4423, 0x4A2E17), (0x2A2A3A, 0x16161F), (0xE8C468, 0xC79A2F), (0xA0430A, 0x6E2C06)]
SKIN = [(0xFCD0B1, 0xE8A588), (0xE0AC69, 0xC68642), (0xFCD0B1, 0xE8A588), (0xD9A066, 0xB0713A)]

# Shared uppercase accessory charset (must match tools/generate_hero_bases.py ACCESSORY_COLORS)
ACCESSORY = [
    ("M", 0xCBD5E1), ("N", 0x94A3B8), ("E", 0xE2E8F0), ("U", 0x475569),
    ("G", 0xFDE047), ("H", 0xCA8A04), ("J", 0xDC2626), ("R", 0x7F1D1D),
    ("K", 0x854D0E), ("T", 0x451A03), ("V", 0xFFFFFF), ("W", 0xF8FAFC),
    ("F", 0x22D3EE), ("Q", 0x06B6D4), ("O", 0xF97316), ("P", 0x9333EA),
    ("X", 0x5B21B6), ("Z", 0x23232D),
]


def hexc(v):
    return f"HeroAvatarSprites.color(hex: 0x{v:06X})"


def swift_grid(name, doc, rows):
    lines = [f"    /// {doc}", f"    static let {name}: [String] = ["]
    lines += [f'        "{r}",' for r in rows[:-1]]
    lines += [f'        "{rows[-1]}"']
    lines.append("    ]")
    return "\n".join(lines)


def main():
    male, female = male_base(), female_base()
    assert len(male) == 30 and len(female) == 30, (len(male), len(female))

    out = ["""//
//  HeroAvatarSprites+TracedGrids.swift
//  LootList
//
//  GENERATED by tools/generate_semantic_bases.py — edit that script, not this file.
//  Hand-authored semantic bases (Option B): lowercase-only character contract,
//  merged with the uppercase accessory charset per preset.
//

import SwiftUI

enum HeroAvatarTracedGrids {
"""]

    out.append(swift_grid("maleBase",
                          "Male chibi: big head (~47% height), square shoulders, straight-leg stance.",
                          male))
    out.append("")
    out.append(swift_grid("femaleBase",
                          "Female chibi: shoulder-length locks, narrower torso, flared skirt hem.",
                          female))
    out.append("""
    // MARK: - Palettes

    /// Shared uppercase colors used by class accessory overlays.
    private static let accessoryColors: [Character: Color] = [
""")
    out.append(",\n".join(f'        "{ch}": {hexc(v)}' for ch, v in ACCESSORY))
    out.append("""    ]

    private static func basePalette(
        hair: UInt32, hairShadow: UInt32,
        skin: UInt32, skinShadow: UInt32,
        tunic: UInt32, tunicShade: UInt32
    ) -> [Character: Color] {
        [
            ".": HeroAvatarSprites.cClear,
            "k": HeroAvatarSprites.cCharcoal,
            "w": HeroAvatarSprites.cWhite,
            "h": HeroAvatarSprites.color(hex: hair),
            "i": HeroAvatarSprites.color(hex: hairShadow),
            "e": HeroAvatarSprites.cCharcoal,
            "s": HeroAvatarSprites.color(hex: skin),
            "r": HeroAvatarSprites.color(hex: skinShadow),
            "b": HeroAvatarSprites.color(hex: tunic),
            "d": HeroAvatarSprites.color(hex: tunicShade),
            "a": HeroAvatarSprites.color(hex: tunic),
            "m": HeroAvatarSprites.cLeatherBrown,
            "v": HeroAvatarSprites.color(hex: tunicShade),
            "u": HeroAvatarSprites.cDarkWood
        ]
    }

    private static func presetPalette(
        hair: UInt32, hairShadow: UInt32,
        skin: UInt32, skinShadow: UInt32,
        tunic: UInt32, tunicShade: UInt32
    ) -> [Character: Color] {
        var palette = basePalette(
            hair: hair, hairShadow: hairShadow,
            skin: skin, skinShadow: skin,
            tunic: tunic, tunicShade: tunicShade
        )
        for (char, color) in accessoryColors {
            palette[char] = color
        }
        return palette
    }
""")

    for cls, colors in OUTFITS.items():
        cap = cls[0].lower() + cls[1:]
        for v in range(1, 5):
            h, hs = HAIR[v - 1]
            s, ss = SKIN[v - 1]
            t, td = colors[v - 1]
            out.append(f"    static let {cap}V{v}Palette: [Character: Color] = presetPalette(")
            out.append(f"        hair: 0x{h:06X}, hairShadow: 0x{hs:06X},")
            out.append(f"        skin: 0x{s:06X}, skinShadow: 0x{ss:06X},")
            out.append(f"        tunic: 0x{t:06X}, tunicShade: 0x{td:06X}")
            out.append("    )")
        out.append("")

    body = "\n".join(out).rstrip() + "\n}\n"

    target = "Project/Resources/SpriteData/HeroAvatarSprites+TracedGrids.swift"
    with open(target, "w") as f:
        f.write(body)
    print(f"wrote {target} ({len(body.splitlines())} lines)")


if __name__ == "__main__":
    main()

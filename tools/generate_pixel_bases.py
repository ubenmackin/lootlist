#!/usr/bin/env python3
"""Pixel base generator (Option C): lossless PNG bases -> Swift char grids.

Reads the flat-color pixel art in assets/blanks/, applies per-preset
recolors / drawn hats, and emits HeroAvatarSprites+PixelBases.swift with one
64x64 char grid + palette per AvatarPreset. Encoding is lossless: every
unique opaque RGBA becomes one character; transparency is '.'.
"""

from PIL import Image, ImageDraw

SRC = "assets/blanks"
TARGET = "Project/Resources/SpriteData/HeroAvatarSprites+PixelBases.swift"
CHARS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"


def hexc(s):
    s = s.lstrip("#")
    return (int(s[0:2], 16), int(s[2:4], 16), int(s[4:6], 16), 255)


def load(name):
    return Image.open(f"{SRC}/{name}").convert("RGBA")


def recolor(img, mapping):
    out = img.copy()
    po = out.load()
    px = img.load()
    for y in range(img.height):
        for x in range(img.width):
            p = px[x, y]
            if p in mapping:
                po[x, y] = mapping[p]
    return out


def m(*pairs):
    return {(hexc(a)): hexc(b) for a, b in pairs}


# --- Recolor recipes -------------------------------------------------------

ARMOR_DARK = m(
    ("867E7F", "565B68"), ("726B7E", "434754"), ("4D4A5D", "2E313B"),
    ("2E2533", "1F2129"), ("FFFFFF", "B9C0CC"), ("C4B59F", "9A8C74"),
)

ROGUE_DARK = m(
    ("E5E6C7", "3A3F4E"),                       # shirt -> charcoal
    ("3C49AD", "4A3524"), ("466AC9", "5C4330"),  # pants -> leather browns
    ("322D6A", "33241A"), ("281E41", "221710"),
)

MALE1_ROGUE = m(
    ("EF7E19", "3A3F4E"), ("D75B1A", "2E3240"), ("FFA749", "4A5060"),
    ("AE682A", "262A36"), ("B7996A", "4A3A28"), ("B3AFA1", "2A2E38"),
)

FEMALE3_ROGUE = m(
    ("AB1E1E", "3A3F4E"), ("82171C", "2E3240"), ("400B1F", "20242E"),
)

MAGE_ROBE_M4 = m(
    ("797580", "5E4B96"), ("585561", "463878"),
    ("A2A0A4", "7B69B0"), ("373340", "332A55"),
)

MAGE_ROBE_F2 = m(("E5E6C7", "8A76B8"),)
MAGE_ROBE_F1 = m(("9FBBCB", "8A76B8"), ("C6EEFD", "A892D4"))
MAGE_ROBE_M3 = m(("BF9D5A", "5E4B96"), ("EDDC7E", "7B69B0"), ("F6F6C2", "9B87C6"))

VIOLET = dict(cloth=(0x5E, 0x4B, 0x96), cloth_light=(0x7B, 0x69, 0xB0), cloth_dark=(0x3A, 0x2E, 0x66))
BLUE = dict(cloth=(0x25, 0x63, 0xEB), cloth_light=(0x60, 0xA5, 0xFA), cloth_dark=(0x1E, 0x3A, 0x8A))
GREEN = dict(cloth=(0x2E, 0x6B, 0x4B), cloth_light=(0x4E, 0x8B, 0x66), cloth_dark=(0x1E, 0x4A, 0x34))


# --- Wizard hat ------------------------------------------------------------

def draw_wizard_hat(img, cloth=(0x5E, 0x4B, 0x96), cloth_light=(0x7B, 0x69, 0xB0),
                    cloth_dark=(0x3A, 0x2E, 0x66), cx=31, brim_y=18, brim_half=12,
                    height=23, lean=10):
    out = img.copy()
    d = ImageDraw.Draw(out)
    C, L, D = cloth + (255,), cloth_light + (255,), cloth_dark + (255,)
    B, K = hexc("FDE047"), (20, 16, 28, 255)

    rows = []
    for i in range(height):
        y = brim_y - height + i
        t = i / max(1, height - 1)
        half = max(1, int(round(1 + (brim_half - 1) * (t ** 1.7))))
        drift = int(round(lean * ((1.0 - t) ** 1.7)))  # lean grows toward the TIP
        rows.append((y, cx - half + drift, cx + half + drift))

    for y, x0, x1 in rows:                      # silhouette outline
        for x in range(x0 - 1, x1 + 2):
            d.point((x, y), fill=K)
    for x in range(cx - brim_half - 2, cx + brim_half + 3):
        d.point((x, brim_y), fill=K)
        d.point((x, brim_y + 1), fill=K)
    for y, x0, x1 in rows:                      # cloth
        for x in range(x0, x1 + 1):
            c = D if x >= x1 - 1 else (L if x <= x0 + 2 else C)
            d.point((x, y), fill=c)
    ty, tx = rows[0][0], rows[0][2]             # tip flop
    d.point((tx + 1, ty - 1), fill=C)
    d.point((tx + 2, ty - 1), fill=K)
    d.point((tx, ty - 1), fill=K)
    d.point((tx + 1, ty - 2), fill=K)
    yb, x0b, x1b = rows[-1]                     # gold band
    for x in range(x0b, x1b + 1):
        d.point((x, yb), fill=B)
    for x in range(cx - brim_half - 1, cx + brim_half + 2):  # brim
        d.point((x, brim_y), fill=D if abs(x - cx) > brim_half - 3 else C)
        d.point((x, brim_y + 1), fill=hexc("241C3A"))
    return out


# --- Preset recipes --------------------------------------------------------

def soldier(n): return load(f"soldier_{n}.png")


PRESETS = {
    "knightV1": lambda: soldier("helm"),
    "knightV2": lambda: soldier("helm_cape"),
    "knightV3": lambda: soldier("no_helm"),
    "knightV4": lambda: load("male1.png"),
    "guardianV1": lambda: recolor(soldier("no_helm"), ARMOR_DARK),
    "guardianV2": lambda: recolor(soldier("helm"), ARMOR_DARK),
    "guardianV3": lambda: recolor(soldier("helm_cape"), ARMOR_DARK),
    "guardianV4": lambda: load("male2.png"),
    "healerV1": lambda: load("female1.png"),
    "healerV2": lambda: load("female3.png"),
    "healerV3": lambda: load("female2.png"),
    "healerV4": lambda: load("male3.png"),
    "mageV1": lambda: draw_wizard_hat(recolor(load("male4.png"), MAGE_ROBE_M4), **VIOLET),
    "mageV2": lambda: draw_wizard_hat(recolor(load("female2.png"), MAGE_ROBE_F2), **VIOLET),
    "mageV3": lambda: draw_wizard_hat(recolor(load("female1.png"), MAGE_ROBE_F1), **VIOLET),
    "mageV4": lambda: draw_wizard_hat(recolor(load("male3.png"), MAGE_ROBE_M3), **GREEN),
    "rogueV1": lambda: load("male2.png"),
    "rogueV2": lambda: recolor(load("male1.png"), MALE1_ROGUE),
    "rogueV3": lambda: recolor(load("female2.png"), ROGUE_DARK),
    "rogueV4": lambda: recolor(load("female3.png"), FEMALE3_ROGUE),
}


def encode(img):
    """RGBA -> (rows, {char: 0xRRGGBB}) losslessly."""
    px = img.load()
    colors = {}
    for y in range(64):
        for x in range(64):
            p = px[x, y]
            if p[3] == 0:
                continue
            key = p[:3]
            if key not in colors:
                if len(colors) >= len(CHARS):
                    raise ValueError("too many colors")
                colors[key] = CHARS[len(colors)]
    rows = []
    for y in range(64):
        rows.append("".join(colors.get(px[x, y][:3], ".") if px[x, y][3] else "." for x in range(64)))
    return rows, {c: (r << 16) | (g << 8) | b for (r, g, b), c in colors.items()}


def main():
    blocks = []
    for preset, recipe in PRESETS.items():
        rows, palette = encode(recipe())
        assert all(len(r) == 64 for r in rows) and len(rows) == 64
        pal_lines = '            ".": HeroAvatarSprites.cClear,\n' + ",\n".join(
            f'            "{c}": HeroAvatarSprites.color(hex: 0x{v:06X})'
            for c, v in sorted(palette.items())
        )
        grid_lines = ",\n".join(f'        "{r}"' for r in rows)
        cap = preset[0].upper() + preset[1:]
        blocks.append(f"""    // MARK: - {cap}

    static let {cap}Grid: [String] = [
{grid_lines}
    ]

    static let {cap}Palette: [Character: Color] = [
{pal_lines}
    ]""")

    body = f"""//
//  HeroAvatarSprites+PixelBases.swift
//  LootList
//
//  GENERATED by tools/generate_pixel_bases.py — edit that script, not this file.
//  Lossless 64x64 char-grid encodings of assets/blanks/*.png with per-preset
//  recolors (guardian dark iron, rogue leathers, mage robes) and drawn hats.
//

import SwiftUI

enum HeroAvatarPixelBases:
{chr(10)}"""
    # fix enum header (join blocks)
    body = body.replace("enum HeroAvatarPixelBases:\n", "enum HeroAvatarPixelBases {\n")
    body += "\n\n".join(blocks)

    cases_grid = "\n".join(f"        case .{p}: return {p[0].upper() + p[1:]}Grid" for p in PRESETS)
    cases_pal = "\n".join(f"        case .{p}: return {p[0].upper() + p[1:]}Palette" for p in PRESETS)
    body += f"""

    // MARK: - Preset Dispatch

    static func grid(for preset: AvatarPreset) -> [String] {{
        switch preset {{
{cases_grid}
        }}
    }}

    static func palette(for preset: AvatarPreset) -> [Character: Color] {{
        switch preset {{
{cases_pal}
        }}
    }}
}}
"""
    with open(TARGET, "w") as f:
        f.write(body)
    print(f"wrote {TARGET}: {len(body.splitlines())} lines, {len(PRESETS)} presets")


if __name__ == "__main__":
    main()

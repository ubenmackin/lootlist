#!/usr/bin/env python3
"""
Trace reference avatar images into LootList sprite matrices.

The reference art is anti-aliased/smoothed (not crisp pixel art), so we:
  1. Crop to the sprite bounding box
  2. Downsample to a 24x30 grid with box averaging
  3. Quantize each cell to the nearest anchor color -> structural char
  4. Clean up noise (isolated pixels)

Output: Project/Resources/SpriteData/HeroAvatarSprites+TracedGrids.swift
        plus an ASCII preview printed to stdout.
"""

from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image

GRID_W, GRID_H = 24, 30

# Anchor palette: char -> (r, g, b)
# NOTE: 'k' is never matched directly -- outlines are synthesized by
# add_outline() so dark art regions stay colors instead of collapsing.
ANCHORS = {
    ".": None,
    # skin family (warm, light)
    "x": (255, 231, 211),
    "s": (252, 208, 177),
    "S": (232, 165, 136),
    "T": (140, 85, 36),     # deep skin / dark leather / boot
    "t": (133, 77, 14),     # leather brown
    # hair (browns/oranges)
    "H": (196, 124, 62),
    "j": (240, 180, 110),
    "h": (120, 70, 35),
    # metal
    "A": (226, 232, 240),
    "g": (203, 213, 225),
    "G": (148, 163, 184),
    "u": (71, 85, 105),     # dark neutral (iron/dark fabric)
    # gold
    "Y": (253, 224, 71),
    "y": (202, 138, 4),
    # accents
    "q": (220, 38, 38),     # red
    "R": (127, 29, 29),     # dark red
    "e": (5, 150, 105),     # emerald
    "E": (6, 78, 59),       # dark green
    "f": (21, 128, 61),     # forest green
    "b": (37, 99, 235),     # royal blue
    "B": (30, 58, 138),     # navy
    "p": (124, 58, 237),    # arcane purple
    "P": (76, 29, 149),     # deep purple
    "m": (236, 72, 153),    # pink
    "w": (248, 250, 252),   # off-white
}


def load_cells(path: Path):
    """Downsample the entire image (background included). Background blocks
    average out to near-black; the classifier turns them transparent."""
    img = Image.open(path).convert("RGBA")
    small = img.resize((GRID_W, GRID_H), Image.BOX)
    return small.load()


def add_outline(grid):
    """Synthesize a clean outline: background cells touching art become 'k'."""
    additions = []
    for y in range(GRID_H):
        for x in range(GRID_W):
            if grid[y][x] != ".":
                continue
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                nx, ny = x + dx, y + dy
                if 0 <= nx < GRID_W and 0 <= ny < GRID_H and grid[ny][nx] != ".":
                    additions.append((x, y))
                    break
    # Only ring the outside; don't fill gaps between separate parts
    for x, y in additions:
        grid[y][x] = "k"


def classify(r, g, b, a):
    if a < 140:
        return "."
    lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
    # Background blocks average to near-pure black; art never does.
    if lum < 18:
        return "."
    best, best_d = "u", 1e9
    for ch, rgb in ANCHORS.items():
        if ch == "." or rgb is None or ch == "u":
            continue
        ar, ag, ab = rgb
        d = (r - ar) ** 2 + (g - ag) ** 2 + (b - ab) ** 2
        if d < best_d:
            best, best_d = ch, d
    # Dark desaturated cells fall back to the dark neutral
    mx, mn = max(r, g, b), min(r, g, b)
    sat = 0 if mx == 0 else (mx - mn) / mx
    if lum < 60 and sat < 0.25:
        return "u"
    return best


def remove_small_components(grid, min_size=6):
    """Delete connected components smaller than min_size cells (dither noise)."""
    seen = [[False] * GRID_W for _ in range(GRID_H)]
    for y0 in range(GRID_H):
        for x0 in range(GRID_W):
            if grid[y0][x0] == "." or seen[y0][x0]:
                continue
            ch = grid[y0][x0]
            stack = [(x0, y0)]
            cells = []
            while stack:
                x, y = stack.pop()
                if not (0 <= x < GRID_W and 0 <= y < GRID_H) or seen[y][x]:
                    continue
                if grid[y][x] == ".":
                    continue
                seen[y][x] = True
                cells.append((x, y))
                stack.extend(((x+1, y), (x-1, y), (x, y+1), (x, y-1)))
            if len(cells) < min_size:
                for x, y in cells:
                    grid[y][x] = "."


def clean_noise(grid):
    """Snap isolated cells to their dominant non-outline neighbor."""
    changed = True
    passes = 0
    while changed and passes < 4:
        changed = False
        passes += 1
        for y in range(GRID_H):
            for x in range(GRID_W):
                ch = grid[y][x]
                if ch == ".":
                    continue
                neighbors = []
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < GRID_W and 0 <= ny < GRID_H:
                        neighbors.append(grid[ny][nx])
                same = sum(1 for n in neighbors if n == ch)
                solid = sum(1 for n in neighbors if n not in (".",))
                if solid > 0 and same == 0:
                    # fully orphaned: adopt most common neighbor
                    counts = {}
                    for n in neighbors:
                        counts[n] = counts.get(n, 0) + 1
                    top = max(counts.items(), key=lambda kv: kv[1])[0]
                    if top != ".":
                        grid[y][x] = top
                        changed = True


def trim_and_center(rows):
    """Trim empty columns/rows, re-center horizontally on a 24-wide grid."""
    xs = [x for y, row in enumerate(rows) for x, ch in enumerate(row) if ch != "."]
    ys = [y for y, row in enumerate(rows) if any(c != "." for c in row)]
    if not xs:
        return rows
    x0, x1 = min(xs), max(xs)
    y0, y1 = min(ys), max(ys)
    cropped = [row[x0 : x1 + 1] for row in rows[y0 : y1 + 1]]
    w = x1 - x0 + 1
    h = y1 - y0 + 1
    out_w = GRID_W
    ox = (out_w - w) // 2
    oy = GRID_H - h  # feet at bottom row
    canvas = [["."] * out_w for _ in range(GRID_H)]
    for j, row in enumerate(cropped):
        for i, ch in enumerate(row):
            yy, xx = oy + j, ox + i
            if 0 <= yy < GRID_H and 0 <= xx < out_w:
                canvas[yy][xx] = ch
    return ["".join(r) for r in canvas]


def trace(path: Path):
    img = Image.open(path).convert("RGB")
    from PIL import ImageFilter
    filtered = img.filter(ImageFilter.MedianFilter(9))
    small = filtered.resize((GRID_W, GRID_H), Image.BOX)
    px = small.load()
    grid = []
    color_sums = {}
    for y in range(GRID_H):
        row = []
        for x in range(GRID_W):
            r, g, b = px[x, y]
            ch = classify(r, g, b, 255)
            row.append(ch)
            if ch not in (".", "k") and ch in ANCHORS:
                s = color_sums.setdefault(ch, [0, 0, 0, 0])
                s[0] += r; s[1] += g; s[2] += b; s[3] += 1
        grid.append(row)
    remove_small_components(grid)
    clean_noise(grid)
    add_outline(grid)
    rows = trim_and_center(["".join(row) for row in grid])
    # Recompute averages only over surviving cells
    survivors = {ch for row in rows for ch in row}
    palette = {}
    for ch, (r, g, b, n) in color_sums.items():
        if ch in survivors and n > 0:
            palette[ch] = (r // n) << 16 | (g // n) << 8 | b
    return rows, palette


def ascii_preview(rows):
    # Terminal-friendly glyphs
    glyph = {".": "·", "k": "@"}
    return "\n".join("".join(glyph.get(ch, ch) for ch in row) for row in rows)


def swift_file(traced: dict[str, tuple[list[str], dict[str, int]]]) -> str:
    header = """//
//  HeroAvatarSprites+TracedGrids.swift
//  LootList
//
//  GENERATED by tools/trace_sprite.py from assets/reference/*.png — do not edit.
//  Each preset has a grid traced from the reference image plus a palette
//  captured from the image's own colors.
//

import SwiftUI

enum HeroAvatarTracedGrids {
"""
    body = []
    for name, (rows, palette) in traced.items():
        literal = ",\n".join(f'        "{row}"' for row in rows)
        body.append(f"    static let {name}: [String] = [\n{literal}\n    ]\n")
        entries = ",\n".join(
            f'        "{ch}": HeroAvatarSprites.color(hex: 0x{hexval:06X})'
            for ch, hexval in sorted(palette.items())
        )
        body.append(
            f"    static let {name}Palette: [Character: Color] = [\n"
            f'        ".": HeroAvatarSprites.cClear,\n'
            f'        "k": HeroAvatarSprites.cCharcoal,\n{entries}\n    ]\n'
        )
    return header + "\n".join(body) + "}\n"


# Reference files map onto app presets.
PRESET_MAP = {
    "avatar-Warrior-One.png": "knightV1",
    "avatar-Warrior-Two.png": "knightV2",
    "avatar-Warrior-Three.png": "knightV3",
    "avatar-Warrior-Four.png": "knightV4",
    "avatar-Mage-One.png": "mageV1",
    "avatar-Mage-Two.png": "mageV2",
    "avatar-Mage-Three.png": "mageV3",
    "avatar-Mage-Four.png": "mageV4",
    "avatar-Druid-One.png": "healerV1",
    "avatar-Druid-Two.png": "healerV2",
    "avatar-Druid-Three.png": "healerV3",
    "avatar-Druid-Four.png": "healerV4",
}


def main():
    ref_dir = Path("assets/reference")
    out_path = Path("Project/Resources/SpriteData/HeroAvatarSprites+TracedGrids.swift")
    traced = {}
    for path in sorted(ref_dir.glob("*.png")):
        preset = PRESET_MAP.get(path.name)
        if preset is None:
            print(f"skipping {path.name} (no preset mapping)")
            continue
        rows, palette = trace(path)
        traced[preset] = (rows, palette)
        print(f"\n=== {path.name} -> {preset} ===")
        print(ascii_preview(rows))
    out_path.write_text(swift_file(traced))
    print(f"\nwrote {out_path}")


if __name__ == "__main__":
    sys.exit(main())

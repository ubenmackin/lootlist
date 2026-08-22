#!/usr/bin/env python3
"""
Generate high-fidelity hero bases from the blank reference characters.

Pipeline:
  1. Median-filter (kill AI noise), downsample to 24x30
  2. K-means color extraction (~30 true colors — fixes anchor quantization muddiness)
  3. Map cells -> nearest cluster -> char (0-9a-zA-Z)
  4. Denoise, synthesize outline
  5. Emit base grids + TRUE-color palettes + 20 preset palettes with
     hue-shifted clothing per class/variant.

Output: Project/Resources/SpriteData/HeroAvatarSprites+TracedGrids.swift
"""

from __future__ import annotations

import colorsys
import random
from pathlib import Path

from PIL import Image, ImageFilter

GRID_W, GRID_H = 24, 30
CHARSET = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
K = 40


def load_grid(path: Path):
    img = Image.open(path).convert("RGB")
    filtered = img.filter(ImageFilter.MedianFilter(7))
    small = filtered.resize((GRID_W, GRID_H), Image.BOX)

    # Percentile contrast stretch (2%..98%) per channel: restores
    # separation in dark regions without blowing out highlights.
    px = small.load()
    vals = [px[x, y] for y in range(GRID_H) for x in range(GRID_W)]
    stretched = []
    for ch in range(3):
        col = sorted(v[ch] for v in vals)
        lo = col[int(len(col)*0.02)]
        hi = col[max(0, int(len(col)*0.98)-1)]
        span = max(1, hi - lo)
        stretched.append((lo, span))
    def stretch(v):
        return tuple(min(255, max(0, (v[i]-stretched[i][0]) * 255 // stretched[i][1])) for i in range(3))
    for y in range(GRID_H):
        for x in range(GRID_W):
            px[x, y] = stretch(px[x, y])
    return px


def is_background(r, g, b):
    return (0.2126 * r + 0.7152 * g + 0.0722 * b) < 18


def kmeans(pixels, k, iters=12, seed=7):
    rng = random.Random(seed)
    centers = rng.sample(pixels, min(k, len(pixels)))
    for _ in range(iters):
        buckets = [[] for _ in centers]
        for p in pixels:
            best, bd = 0, 1e18
            for i, c in enumerate(centers):
                d = (p[0]-c[0])**2 + (p[1]-c[1])**2 + (p[2]-c[2])**2
                if d < bd:
                    best, bd = i, d
            buckets[best].append(p)
        new_centers = []
        for bkt in buckets:
            if bkt:
                n = len(bkt)
                new_centers.append(tuple(sum(c[i] for c in bkt)//n for i in range(3)))
            else:
                new_centers.append(rng.choice(pixels))
        if new_centers == centers:
            break
        centers = new_centers
    # sort by luminance descending so chars are stable across runs
    centers.sort(key=lambda c: -(0.2126*c[0] + 0.7152*c[1] + 0.0722*c[2]))
    return centers


def semantic_group(rgb):
    """Classify a cluster so we can hue-shift clothing later."""
    r, g, b = rgb
    h, l, s = colorsys.rgb_to_hls(r/255, g/255, b/255)
    hue = h * 360
    if l > 0.55 and s < 0.60 and r >= g >= b and r > 150:
        return "skin"
    if 15 <= hue <= 50 and l < 0.55:
        return "hair"      # browns/oranges (hair, belt, boots)
    if 190 <= hue <= 260:
        return "clothes"   # blues (tunic + pants)
    if l < 0.12:
        return "dark"      # near-black details
    return "other"


def shift_hue(rgb, target_hue_deg, sat_scale=1.0):
    """Recolor a clothing pixel to target hue, preserving its lightness."""
    r, g, b = rgb
    h, l, s = colorsys.rgb_to_hls(r/255, g/255, b/255)
    s = min(1.0, s * sat_scale)
    nr, ng, nb = colorsys.hls_to_rgb(target_hue_deg/360, l, s)
    return round(nr*255), round(ng*255), round(nb*255)


def trace_base(path: Path):
    px = load_grid(path)
    # Collect art pixels for clustering
    samples = []
    for y in range(GRID_H):
        for x in range(GRID_W):
            r, g, b = px[x, y]
            if not is_background(r, g, b):
                samples.append((r, g, b))
    centers = kmeans(samples, K)

    def nearest_char(rgb):
        best, bd = 0, 1e18
        for i, c in enumerate(centers):
            d = sum((rgb[j]-c[j])**2 for j in range(3))
            if d < bd:
                best, bd = i, d
        return best

    grid = [["."] * GRID_W for _ in range(GRID_H)]
    counts = [0] * len(centers)
    for y in range(GRID_H):
        for x in range(GRID_W):
            r, g, b = px[x, y]
            if is_background(r, g, b):
                continue
            ci = nearest_char((r, g, b))
            grid[y][x] = CHARSET[ci]
            counts[ci] += 1

    mode_filter(grid)
    remove_small_components(grid)
    clean_noise(grid)
    add_outline(grid)
    rows = trim_and_center(["".join(r) for r in grid])

    # Palette from surviving cells only
    survivors = {ch for row in rows for ch in row}
    palette = {}
    groups = {}
    for i, c in enumerate(centers):
        ch = CHARSET[i]
        if ch in survivors and counts[i] > 0:
            palette[ch] = c
            groups[ch] = semantic_group(c)
    return rows, palette, groups


def mode_filter(grid, passes=3):
    """Each cell adopts the most common char in its 3x3 block (keeps
    majority regions solid, dissolves dither speckle)."""
    for _ in range(passes):
        original = [row[:] for row in grid]
        changed = False
        for y in range(GRID_H):
            for x in range(GRID_W):
                counts = {}
                center_ch = original[y][x]
                for dy in (-1, 0, 1):
                    for dx in (-1, 0, 1):
                        ny, nx = y+dy, x+dx
                        if 0 <= ny < GRID_H and 0 <= nx < GRID_W:
                            ch = original[ny][nx]
                            if ch != ".":
                                counts[ch] = counts.get(ch, 0) + 1
                        elif dx == 0 and dy == 0:
                            pass
                if not counts:
                    continue
                top, n = max(counts.items(), key=lambda kv: kv[1])
                # Only switch when clearly outvoted (>=2 more votes)
                if top != center_ch and n >= (counts.get(center_ch, 0) + 2):
                    grid[y][x] = top
                    changed = True
        if not changed:
            break


def remove_small_components(grid, min_size=6):
    seen = [[False] * GRID_W for _ in range(GRID_H)]
    for y0 in range(GRID_H):
        for x0 in range(GRID_W):
            if grid[y0][x0] == "." or seen[y0][x0]:
                continue
            stack, cells = [(x0, y0)], []
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
    for _ in range(3):
        changed = False
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
                solid = [n for n in neighbors if n != "."]
                if solid and ch not in solid:
                    counts = {}
                    for n in solid:
                        counts[n] = counts.get(n, 0) + 1
                    top = max(counts.items(), key=lambda kv: kv[1])[0]
                    grid[y][x] = top
                    changed = True
        if not changed:
            break


def add_outline(grid):
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
    for x, y in additions:
        grid[y][x] = "k"


def trim_and_center(rows):
    xs = [x for row in rows for x, ch in enumerate(row) if ch != "."]
    ys = [y for y, row in enumerate(rows) if any(c != "." for c in row)]
    if not xs:
        return rows
    x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
    cropped = [row[x0:x1+1] for row in rows[y0:y1+1]]
    w, h = x1-x0+1, y1-y0+1
    ox, oy = (GRID_W - w)//2, GRID_H - h
    canvas = [["."] * GRID_W for _ in range(GRID_H)]
    for j, row in enumerate(cropped):
        for i, ch in enumerate(row):
            yy, xx = oy+j, ox+i
            if 0 <= yy < GRID_H and 0 <= xx < GRID_W:
                canvas[yy][xx] = ch
    return ["".join(r) for r in canvas]


def ascii_preview(rows):
    glyph = {".": "·", "k": "@"}
    return "\n".join("".join(glyph.get(ch, ch) for ch in row) for row in rows)


# --- Preset cloth colors ----------------------------------------------------
# (hue, saturation scale) applied to every "clothes"-group cluster.

CLASS_HUES = {
    "knight": [(220, 1.0), (350, 0.9), (140, 0.8), (280, 0.9)],   # blue, crimson, green, purple
    "mage": [(265, 1.0), (200, 0.9), (320, 0.8), (25, 0.85)],     # violet, cyan, magenta, ember
    "rogue": [(150, 0.7), (215, 0.6), (275, 0.7), (0, 0.65)],     # forest, slate, nightshade, blood
    "guardian": [(210, 0.35), (240, 0.25), (330, 0.4), (35, 0.6)],  # steel, navy-iron, rose-steel, bronze
    "healer": [(50, 0.25), (120, 0.30), (340, 0.35), (95, 0.35)],  # cream-gold, sage, rose, moss
}

FEMALE_VARIANTS = {3, 4}  # v3/v4 use the female base


# --- Accessory colors -------------------------------------------------------
# Accessory overlays (helmets, weapons, staves) use ONLY uppercase characters,
# which never collide with k-means cluster chars (digits + lowercase).
# These are merged into every preset palette so overlays always render.

ACCESSORY_COLORS = {
    "M": (203, 213, 225),   # steel light
    "N": (148, 163, 184),   # steel dark
    "E": (226, 232, 240),   # steel shine
    "U": (71, 85, 105),     # iron black
    "G": (253, 224, 71),    # gold trim
    "H": (202, 138, 4),     # deep gold
    "J": (220, 38, 38),     # red accent
    "R": (127, 29, 29),     # dark red
    "K": (133, 77, 14),     # leather brown
    "T": (69, 26, 3),       # dark wood
    "V": (255, 255, 255),   # white
    "W": (248, 250, 252),   # off-white
    "F": (34, 211, 238),    # bright cyan (orb core)
    "Q": (6, 182, 212),     # cyan glow (orb rim)
    "O": (249, 115, 22),    # flame orange
    "P": (147, 51, 234),    # arcane purple (wizard hat)
    "X": (91, 33, 182),     # deep purple (hat shading)
    "Z": (35, 35, 45),      # charcoal fabric (rogue hood)
}

# Hard guarantee: accessory chars never overlap cluster chars.
assert not (set(ACCESSORY_COLORS) & set(CHARSET[:K])), (
    sorted(set(ACCESSORY_COLORS) & set(CHARSET[:K])))


def build_preset_palettes(base_palette, groups, cls, variant):
    hue, sat = CLASS_HUES[cls][(variant - 1) % 4]
    out = {}
    for ch, rgb in base_palette.items():
        grp = groups.get(ch)
        if grp == "clothes":
            out[ch] = shift_hue(rgb, hue, sat)
        else:
            out[ch] = rgb
    # Merge fixed accessory colors (chars guaranteed disjoint from clusters)
    out.update(ACCESSORY_COLORS)
    return out


def hexval(rgb):
    return rgb[0] << 16 | rgb[1] << 8 | rgb[2]


def main():
    ref = Path("assets/reference")
    out_path = Path("Project/Resources/SpriteData/HeroAvatarSprites+TracedGrids.swift")

    bases = {}
    for name, path_name in (("male", "MaleBlank.png"), ("female", "FemaleBlank.png")):
        rows, palette, groups = trace_base(ref / path_name)
        bases[name] = (rows, palette, groups)
        print(f"\n=== {path_name} -> {name}Base ===")
        print(ascii_preview(rows))
        print("groups:", {ch: g for ch, g in sorted(groups.items())})

    parts = ['''//
//  HeroAvatarSprites+TracedGrids.swift
//  LootList
//
//  GENERATED by tools/generate_hero_bases.py — do not edit by hand.
//  Bases traced from assets/reference/*Blank.png with k-means palettes;
//  per-preset palettes recolor the clothing clusters per class/variant.
//

import SwiftUI

enum HeroAvatarTracedGrids {
''']

    for name in ("male", "female"):
        rows, palette, _ = bases[name]
        literal = ",\n".join(f'        "{row}"' for row in rows)
        parts.append(f"    static let {name}Base: [String] = [\n{literal}\n    ]\n")
        entries = ",\n".join(
            f'        "{ch}": HeroAvatarSprites.color(hex: 0x{hexval(rgb):06X})'
            for ch, rgb in sorted(palette.items())
            if ch != "k"
        )
        parts.append(
            f"    static let {name}BasePalette: [Character: Color] = [\n"
            f'        ".": HeroAvatarSprites.cClear,\n'
            f'        "k": HeroAvatarSprites.cCharcoal,\n{entries}\n    ]\n'
        )

    # 20 preset palettes
    for cls in ("knight", "mage", "rogue", "guardian", "healer"):
        for v in (1, 2, 3, 4):
            base = "female" if v in FEMALE_VARIANTS else "male"
            _, palette, groups = bases[base]
            preset_pal = build_preset_palettes(palette, groups, cls, v)
            entries = ",\n".join(
                f'        "{ch}": HeroAvatarSprites.color(hex: 0x{hexval(rgb):06X})'
                for ch, rgb in sorted(preset_pal.items())
                if ch != "k"
            )
            parts.append(
                f"    static let {cls}V{v}Palette: [Character: Color] = [\n"
                f'        ".": HeroAvatarSprites.cClear,\n'
                f'        "k": HeroAvatarSprites.cCharcoal,\n{entries}\n    ]\n'
            )

    parts.append("}\n")
    out_path.write_text("\n".join(parts))
    print(f"\nwrote {out_path}")


if __name__ == "__main__":
    main()

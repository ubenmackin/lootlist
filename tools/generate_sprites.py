#!/usr/bin/env python3
"""
LootList hero avatar sprite generator.

Draws chibi JRPG-overworld sprites programmatically (no ASCII counting),
then emits finished native-resolution grids (24x30) into a Swift file.
The Swift side upscales them 2x onto the 64x64 canvas.

Pipeline per preset:
  1. Fill shapes (head, hair, torso, limbs, class headgear/gear)
  2. Auto-outline: any empty pixel touching a fill becomes 'k'
  3. Interior details (eyes, buckles, visor slits)
  4. Global shade pass: light from top-left (highlight left/top edges,
     shadow right/bottom edges of every region)

Character contract:
  . clear   k outline
  H hair    h hair shadow   j hair highlight
  s skin    S skin shadow   x skin light
  e eye     w eye glint
  b outfit  d outfit dark   c outfit light
  a arm     t belt          T boot
  g metal   G metal dark    A metal shine
  y gold    Y gold bright   q accent
"""

from __future__ import annotations

W, H = 24, 30
CLEAR, OUTLINE = ".", "k"


class Grid:
    def __init__(self, w=W, h=H):
        self.w, self.h = w, h
        self.px = [[CLEAR] * w for _ in range(h)]

    def put(self, x, y, ch):
        if 0 <= x < self.w and 0 <= y < self.h:
            self.px[y][x] = ch

    def get(self, x, y):
        if 0 <= x < self.w and 0 <= y < self.h:
            return self.px[y][x]
        return CLEAR

    def ellipse(self, cx, cy, rx, ry, ch):
        for y in range(self.h):
            for x in range(self.w):
                dx, dy = (x - cx) / rx, (y - cy) / ry
                if dx * dx + dy * dy <= 1.0:
                    self.put(x, y, ch)

    def rect(self, x0, y0, x1, y1, ch):
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                self.put(x, y, ch)

    def blob(self, cells, ch):
        for (x, y) in cells:
            self.put(x, y, ch)

    def filled(self, x, y):
        return self.get(x, y) != CLEAR

    # --- passes -----------------------------------------------------------

    def auto_outline(self):
        """Any clear pixel 4-adjacent to a filled pixel becomes outline."""
        additions = []
        for y in range(self.h):
            for x in range(self.w):
                if self.px[y][x] != CLEAR:
                    continue
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    if self.filled(x + dx, y + dy):
                        additions.append((x, y))
                        break
        for (x, y) in additions:
            self.put(x, y, OUTLINE)

    SHADE_GROUPS = {
        "H": ("j", "h"),   # hair -> highlight / shadow
        "s": ("x", "S"),   # skin
        "b": ("c", "d"),   # outfit
        "g": ("A", "G"),   # metal
        "y": ("Y", "y"),   # gold
        "q": ("q", "q"),
    }

    def shade(self, groups=None):
        """Light from top-left: recolor left/top edge pixels lighter,
        right/bottom edge pixels darker within each contiguous region."""
        groups = groups or self.SHADE_GROUPS
        base_chars = {ch for ch in groups}
        original = [row[:] for row in self.px]
        for y in range(self.h):
            for x in range(self.w):
                ch = original[y][x]
                if ch not in base_chars:
                    continue
                left_filled = self._same_group(original, x - 1, y, ch, base_chars)
                right_filled = self._same_group(original, x + 1, y, ch, base_chars)
                up_filled = self._same_group(original, x, y - 1, ch, base_chars)
                down_filled = self._same_group(original, x, y + 1, ch, base_chars)
                light, shadow = groups[ch]
                if not left_filled and right_filled:
                    self.put(x, y, light)
                elif not right_filled and left_filled:
                    self.put(x, y, shadow)
                elif not up_filled and down_filled and light:
                    self.put(x, y, light)

    @staticmethod
    def _same_group(px, x, y, ch, base_chars):
        if not (0 <= x < W and 0 <= y < H):
            return False
        return px[y][x] == ch or (px[y][x] in base_chars)

    def rows(self):
        return ["".join(row) for row in self.px]


# --- shared chibi geometry -------------------------------------------------
# Proportions tuned against the reference art: big head (~53% of height),
# narrow torso, thin legs, slight rightward stance.

HEAD_CX, HEAD_CY, HEAD_RX, HEAD_RY = 11.5, 8.0, 9.5, 8.0
FACE_CX, FACE_CY, FACE_RX, FACE_RY = 11.0, 10.0, 7.5, 4.8
SHOULDER_ROW, HIP_ROW = 15, 22
LEG_Y0, LEG_Y1 = 23, 27
BOOT_Y0, BOOT_Y1 = 26, 29


def torso_half_width(y):
    """Shoulders taper toward hips."""
    t = min(1.0, max(0.0, (y - SHOULDER_ROW) / (HIP_ROW - SHOULDER_ROW)))
    return round(8 - 2 * t)


def draw_chibi_base(g: Grid, *, female=False, hair="H"):
    # Back hair (long locks) behind everything for female variants
    if female:
        g.rect(2, 8, 4, 21, hair)
        g.rect(19, 8, 21, 21, hair)

    # Head
    g.ellipse(HEAD_CX, HEAD_CY, HEAD_RX, HEAD_RY, hair)

    # Fringe: hair dips lower on the right (suggests slight turn)
    for x in range(int(HEAD_CX - HEAD_RX), int(HEAD_CX + HEAD_RX) + 1):
        dip = 1 if x >= HEAD_CX else 0
        wave = 1 if (x % 4) < 2 else 0
        fringe_bottom = 6 + dip + wave
        for y in range(int(HEAD_CY - HEAD_RY), fringe_bottom + 1):
            if abs((x - HEAD_CX) / HEAD_RX) ** 2 + ((y - HEAD_CY) / HEAD_RY) ** 2 <= 1.0:
                g.put(x, y, hair)

    # Face (carve skin out of the hair, leaving sideburns)
    g.ellipse(FACE_CX, FACE_CY, FACE_RX, FACE_RY, "s")

    # Torso
    for y in range(SHOULDER_ROW, HIP_ROW + 1):
        hw = torso_half_width(y)
        g.rect(int(HEAD_CX) - hw, y, int(HEAD_CX) + hw, y, "b")

    # Arms merged into torso sides; hands peek out near the hips
    for y in range(SHOULDER_ROW + 1, HIP_ROW):
        hw = torso_half_width(y)
        g.put(int(HEAD_CX) - hw + 1, y, "a")
        g.put(int(HEAD_CX) + hw - 1, y, "a")
    g.put(int(HEAD_CX) - torso_half_width(HIP_ROW - 1) + 1, HIP_ROW, "s")
    g.put(int(HEAD_CX) + torso_half_width(HIP_ROW - 1) - 1, HIP_ROW, "s")

    # Belt
    belt_row = HIP_ROW - 2
    hw = torso_half_width(belt_row)
    g.rect(int(HEAD_CX) - hw + 1, belt_row, int(HEAD_CX) + hw - 1, belt_row, "t")
    g.put(int(HEAD_CX) - 1, belt_row, "y")

    # Pants + thin legs + boots
    g.rect(int(HEAD_CX) - 4, HIP_ROW + 1, int(HEAD_CX) + 4, LEG_Y1, "d")
    for lx in (int(HEAD_CX) - 3, int(HEAD_CX) + 1):
        g.rect(lx, LEG_Y0, lx + 2, LEG_Y1, "d")
        g.rect(lx - 1, BOOT_Y0, lx + 3, BOOT_Y1 - 1, "T")
    g.rect(int(HEAD_CX) - 4, BOOT_Y1, int(HEAD_CX) + 4, BOOT_Y1, "d")


def draw_eyes(g: Grid, *, y=None):
    """Two-pixel pupils with a glint; offset one pixel left of center
    to suggest a slight angle."""
    if y is None:
        return
    for ex in (7, 12):  # left-shifted pair
        g.put(ex, y, "e")
        g.put(ex + 1, y, "e")
        g.put(ex, y + 1, "e")
        g.put(ex + 1, y + 1, "w")


# --- class features --------------------------------------------------------

def feature_knight(g: Grid):
    # Helm dome over the top of the head, face opening below
    for y in range(0, 9):
        hw = head_half_at(y)
        if hw <= 0:
            continue
        g.rect(int(HEAD_CX) - hw, y, int(HEAD_CX) + hw, y, "g")
    # Brim
    g.rect(3, 9, 20, 9, "G")
    # Plume arcs back-right
    for (x, y) in [(13, 0), (14, 0), (15, 1), (15, 2), (16, 2), (12, 1)]:
        g.put(x, y, "q")
    # Chin strap hints
    g.put(4, 10, "G")
    g.put(19, 10, "G")


def head_half_at(y):
    dy = (y - HEAD_CY) / HEAD_RY
    if abs(dy) > 1:
        return 0
    return round(HEAD_RX * (1 - dy * dy) ** 0.5)


def feature_sword_and_shield(g: Grid):
    # Sword held on the left, blade tip up
    for y in range(10, 24):
        g.put(1, y, "A")
        g.put(2, y, "g")
    g.put(1, 9, "A")
    g.rect(0, 24, 3, 24, "y")       # guard
    g.put(1, 25, "t"); g.put(1, 26, "t")
    g.put(1, 27, "y")               # pommel
    # Heater shield on the right arm
    shield = [
        "kkkkkk",
        "gAAAAg",
        "gAAAAg",
        "gyAAyg",
        "ggGGgg",
        ".kgGgk",
        "..kk..",
    ]
    stamp(g, shield, 18, 14)


def feature_mage_hat(g: Grid):
    # Floppy cone tilting right, wide brim
    for i, (x0, x1) in enumerate([(11, 12), (10, 13), (10, 14), (9, 15),
                                  (9, 16), (8, 17), (7, 18)]):
        g.rect(x0, 1 + i - 2, x1, 1 + i - 2, "v")
    g.rect(3, 6, 20, 6, "q")        # gold band
    g.rect(2, 7, 21, 7, "v")        # brim top
    g.rect(1, 8, 22, 8, "V")        # brim underside


def feature_staff(g: Grid, orb=("C", "c")):
    big, small = orb
    g.put(1, 4, big); g.put(2, 4, big)
    g.put(0, 5, small); g.put(1, 5, big); g.put(2, 5, big); g.put(3, 5, small)
    g.put(1, 6, big); g.put(2, 6, big)
    g.put(1, 7, small); g.put(2, 7, small)
    for y in range(8, 28):
        g.put(1, y, "t"); g.put(2, y, "t")


def feature_hood(g: Grid, fabric="b", trim=None):
    # Pointed hood, peak leaning left
    peak = [(9, 0), (10, 0), (8, 1), (9, 1), (10, 1)]
    g.blob(peak, fabric)
    for y in range(2, 9):
        hw = head_half_at(y)
        if hw > 0:
            g.rect(int(HEAD_CX) - hw, y, int(HEAD_CX) + hw, y, fabric)
    # Face opening
    g.ellipse(FACE_CX, FACE_CY + 0.5, FACE_RX, FACE_RY, "s")
    if trim:
        g.rect(4, 12, 19, 12, trim)
    # Hood rim down the cheeks
    for (x, y) in [(4, 9), (4, 10), (4, 11), (19, 9), (19, 10), (19, 11)]:
        g.put(x, y, fabric)


def feature_dagger(g: Grid):
    for y in range(13, 19):
        g.put(22, y, "A")
    g.rect(21, 19, 23, 19, "y")
    g.put(22, 20, "t")


def feature_great_helm(g: Grid):
    for y in range(0, 12):
        hw = head_half_at(y)
        if hw <= 0:
            continue
        g.rect(int(HEAD_CX) - hw, y, int(HEAD_CX) + hw, y, "g")
    g.rect(2, 11, 21, 11, "G")
    # Visor slit
    g.rect(5, 8, 18, 8, OUTLINE)
    g.put(6, 8, "A")  # glint


def feature_pauldrons(g: Grid):
    y = SHOULDER_ROW
    hw = torso_half_width(y)
    g.rect(int(HEAD_CX) - hw - 2, y, int(HEAD_CX) - hw + 1, y + 1, "g")
    g.rect(int(HEAD_CX) + hw - 1, y, int(HEAD_CX) + hw + 2, y + 1, "g")
    g.put(int(HEAD_CX) - hw - 2, y, "A")
    g.put(int(HEAD_CX) + hw + 2, y, "G")


def feature_tower_shield(g: Grid):
    shield = [
        "kkkkkkk",
        "gAAAAAg",
        "gAAyAAg",
        "gAyYyAg",
        "gAAyAAg",
        "gAAAAAg",
        "gGGGGGg",
        ".kgGgk.",
        "..kkk..",
    ]
    stamp(g, shield, 17, 12)


def stamp(g: Grid, art, ox, oy, skip="."):
    for j, row in enumerate(art):
        for i, ch in enumerate(row):
            if ch != skip:
                g.put(ox + i, oy + j, ch)


# --- presets ----------------------------------------------------------------

def compose(female, back, features, eye_y=8):
    g = Grid()
    if back:
        back(g)
    draw_chibi_base(g, female=female)
    for fn in features:
        fn(g)
    g.auto_outline()
    draw_eyes(g, y=eye_y)
    g.shade()
    return g.rows()


PRESETS = {
    "knightV1": dict(female=False, back=None,
                     features=[feature_knight, feature_sword_and_shield]),
    "knightV2": dict(female=False, back=None,
                     features=[feature_knight, feature_sword_and_shield]),
    "knightV3": dict(female=True, back=None,
                     features=[feature_knight, feature_sword_and_shield],
                     eye_y=10),
    "knightV4": dict(female=True, back=None,
                     features=[feature_knight, feature_sword_and_shield],
                     eye_y=10),
    "mageV1": dict(female=False, back=None,
                   features=[feature_mage_hat, lambda g: feature_staff(g)],
                   eye_y=9),
    "mageV2": dict(female=False, back=None,
                   features=[feature_mage_hat, lambda g: feature_staff(g)],
                   eye_y=9),
    "mageV3": dict(female=True, back=None,
                   features=[feature_mage_hat, lambda g: feature_staff(g)],
                   eye_y=9),
    "mageV4": dict(female=True, back=None,
                   features=[feature_mage_hat, lambda g: feature_staff(g)],
                   eye_y=9),
    "rogueV1": dict(female=False, back=None,
                    features=[lambda g: feature_hood(g), feature_dagger]),
    "rogueV2": dict(female=False, back=None,
                    features=[lambda g: feature_hood(g), feature_dagger]),
    "rogueV3": dict(female=True, back=None,
                    features=[lambda g: feature_hood(g), feature_dagger]),
    "rogueV4": dict(female=True, back=None,
                    features=[lambda g: feature_hood(g), feature_dagger]),
    "guardianV1": dict(female=False, back=None,
                       features=[feature_great_helm, feature_pauldrons, feature_tower_shield],
                       eye_y=None),
    "guardianV2": dict(female=False, back=None,
                       features=[feature_great_helm, feature_pauldrons, feature_tower_shield],
                       eye_y=None),
    "guardianV3": dict(female=True, back=None,
                       features=[feature_great_helm, feature_pauldrons, feature_tower_shield],
                       eye_y=None),
    "guardianV4": dict(female=True, back=None,
                       features=[feature_great_helm, feature_pauldrons, feature_tower_shield],
                       eye_y=None),
    "healerV1": dict(female=False, back=None,
                     features=[lambda g: feature_hood(g, trim="y"), lambda g: feature_staff(g, orb=("Y", "y"))]),
    "healerV2": dict(female=False, back=None,
                     features=[lambda g: feature_hood(g, trim="y"), lambda g: feature_staff(g, orb=("Y", "y"))]),
    "healerV3": dict(female=True, back=None,
                     features=[lambda g: feature_hood(g, trim="y"), lambda g: feature_staff(g, orb=("Y", "y"))]),
    "healerV4": dict(female=True, back=None,
                     features=[lambda g: feature_hood(g, trim="y"), lambda g: feature_staff(g, orb=("Y", "y"))]),
}


SWIFT_HEADER = """//
//  HeroAvatarSprites+GeneratedGrids.swift
//  LootList
//
//  GENERATED by tools/generate_sprites.py — do not edit by hand.
//  Native-resolution grids (24x30); Swift upscales 2x onto the 64x64 canvas.
//

import SwiftUI

enum HeroAvatarGeneratedGrids {
"""


def swift_literal(rows):
    lines = ",\n".join(f'            "{row}"' for row in rows)
    return f"[\n{lines}\n        ]"


def main():
    out_dir = "Project/Resources/SpriteData"
    parts = [SWIFT_HEADER]
    for name, cfg in PRESETS.items():
        rows = compose(
            female=cfg["female"],
            back=cfg["back"],
            features=cfg["features"],
            eye_y=cfg.get("eye_y", 8),
        )
        parts.append(f"    static let {name}: [String] = {swift_literal(rows)}\n")
    parts.append("}\n")
    path = f"{out_dir}/HeroAvatarSprites+GeneratedGrids.swift"
    with open(path, "w") as f:
        f.write("\n".join(parts))
    print(f"wrote {path} ({len(PRESETS)} presets)")


if __name__ == "__main__":
    main()

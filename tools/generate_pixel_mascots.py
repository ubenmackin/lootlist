#!/usr/bin/env python3
"""Mascot sprite generator: real pixel art for the 5 companions.

Draws owl, dragon, fairy, fox, cat as 64x64 char grids using the SAME
palette characters as MascotSprites.swift (so its palettes keep working).
Emits MascotSpriteGrids.swift with all 50 grids (5 companions x 5 states x
2 frames). Frame 1 is a subtle animation variant (bounce/blink/tail sway).
State overlays: sweat (inProgress), "!" (encouraging), confetti
(celebrating), gem (bonusClaimed).

Preview: writes /tmp/mascots_preview.png contact sheet.
"""

N = 64

# Per-companion accent chars for overlays (must exist in the Swift palette)
ACCENT = {"owl": "O", "dragon": "O", "fairy": "G", "fox": "G", "cat": "P"}


class Grid:
    def __init__(self):
        self.g = [["." for _ in range(N)] for _ in range(N)]

    def set(self, x, y, c):
        if 0 <= x < N and 0 <= y < N:
            self.g[y][x] = c

    def rect(self, x0, y0, x1, y1, c):
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                self.set(x, y, c)

    def ellipse(self, cx, cy, rx, ry, fill, outline=None):
        for y in range(cy - ry, cy + ry + 1):
            for x in range(cx - rx, cx + rx + 1):
                d2 = ((x - cx) / rx) ** 2 + ((y - cy) / ry) ** 2
                if d2 <= 1.0:
                    self.set(x, y, fill)
        if outline:
            for y in range(cy - ry, cy + ry + 1):
                for x in range(cx - rx, cx + rx + 1):
                    d2 = ((x - cx) / rx) ** 2 + ((y - cy) / ry) ** 2
                    if 0.55 <= d2 <= 1.0:
                        self.set(x, y, outline)

    def vline(self, x, y0, y1, c):
        for y in range(y0, y1 + 1):
            self.set(x, y, c)

    def hline(self, y, x0, x1, c):
        for x in range(x0, x1 + 1):
            self.set(x, y, c)


# ---------------------------------------------------------------- owl
def owl(frame):
    g = Grid()
    dy = 1 if frame == 1 else 0  # bounce
    # ear tufts
    for dx in (-6, 6):
        g.set(31 + dx, 22 + dy, "D")
        g.set(31 + dx, 23 + dy, "D")
        g.set(31 + dx + (1 if dx > 0 else -1), 23 + dy, "D")
    # body
    g.ellipse(31, 38 + dy, 12, 14, "B", "D")
    # facial disc
    g.ellipse(31, 31 + dy, 9, 7, "H")
    # brow
    g.hline(26 + dy, 23, 39, "D")
    # eyes: yellow rings + pupils + glints
    for ex in (26, 36):
        g.ellipse(ex, 30 + dy, 3, 3, "Y", "D")
        g.set(ex, 30 + dy, "P")
        g.set(ex - 1, 29 + dy, "W")
    if frame == 1:  # blink
        g.hline(30 + dy, 24, 28, "D")
        g.hline(30 + dy, 34, 38, "D")
        g.set(26, 30 + dy, "Y"); g.set(36, 30 + dy, "Y")
    # beak
    g.set(31, 32 + dy, "Y"); g.set(31, 33 + dy, "Y"); g.set(31, 34 + dy, "D")
    # belly with chevrons
    g.ellipse(31, 43 + dy, 8, 8, "C")
    for i, y in enumerate((41, 44, 47)):
        g.hline(y + dy, 26 + i, 36 - i, "B")
    # wings
    for wx in (19, 43):
        for y in range(32 + dy, 46 + dy):
            g.set(wx + (1 if wx > 31 else 0), y, "S")
        g.set(wx, 32 + dy, "D")
    # feet
    g.hline(53 + dy, 26, 29, "Y")
    g.hline(53 + dy, 33, 36, "Y")
    return g


# ---------------------------------------------------------------- dragon
def dragon(frame):
    g = Grid()
    dy = 1 if frame == 1 else 0
    # tail: curls right and up; frame 1 raises the tip
    tail = [(42, 44), (46, 46), (50, 47), (53, 46), (55, 44), (56, 41)]
    if frame == 1:
        tail = [(42, 44), (46, 46), (50, 47), (53, 45), (54, 42), (54, 39)]
    for i, (x, y) in enumerate(tail):
        g.set(x, y + dy, "R")
        g.set(x, y + 1 + dy, "S")
    tx, ty = tail[-1]
    g.set(tx, ty - 1 + dy, "Y")  # arrow tip
    g.set(tx + (-1), ty - 1 + dy, "Y")
    # body
    g.ellipse(34, 40 + dy, 10, 9, "R", "D")
    # belly plates
    for y in range(35, 48, 2):
        g.hline(y + dy, 28, 38, "Y")
    # head (facing left)
    g.ellipse(23, 28 + dy, 8, 6, "R", "D")
    # snout
    g.rect(14, 29 + dy, 18, 32 + dy, "R")
    g.hline(32 + dy, 14, 18, "D")
    g.set(14, 30 + dy, "D")  # nostril
    # horns
    g.set(20, 22 + dy, "Y"); g.set(20, 21 + dy, "Y")
    g.set(26, 22 + dy, "Y"); g.set(26, 21 + dy, "Y")
    # eye
    g.set(21, 27 + dy, "W"); g.set(21, 27 + dy, "P"); g.set(20, 26 + dy, "W")
    # wing (on the back)
    wing_dy = -2 if frame == 1 else 0
    for i, (x, y) in enumerate([(36, 30), (39, 27), (42, 25), (44, 24)]):
        g.set(x, y + dy + wing_dy, "R")
        g.set(x, y + 1 + dy + wing_dy, "S")
        g.set(x - 1, y + dy + wing_dy, "D")
    # legs
    for lx in (28, 38):
        g.rect(lx, 47 + dy, lx + 3, 52 + dy, "R")
        g.hline(53 + dy, lx, lx + 3, "D")
    return g


# ---------------------------------------------------------------- fairy
def fairy(frame):
    g = Grid()
    dy = 0 if frame == 1 else -1  # hover
    # wings (behind): two lobes each side
    wing_lift = -2 if frame == 1 else 0
    for mirror in (False, True):
        mx = lambda x: (62 - x) if mirror else x
        for x, y in [(24, 28), (21, 26), (19, 29), (22, 32), (25, 32)]:
            g.set(mx(x), y + dy + wing_lift, "B")
            g.set(mx(x), y + 1 + dy + wing_lift, "K")
    # hair bob
    g.ellipse(31, 25 + dy, 6, 5, "H", "D")
    # face
    g.ellipse(31, 27 + dy, 4, 3, "F")
    g.set(29, 27 + dy, "P"); g.set(33, 27 + dy, "P")
    g.set(31, 28 + dy, "D")  # tiny mouth
    # dress: triangle
    for i in range(12):
        half = 2 + i // 2
        for x in range(31 - half, 31 + half + 1):
            c = "P" if x <= 31 else "S"
            g.set(x, 30 + i + dy, c)
    # arms
    g.set(25, 31 + dy, "F"); g.set(37, 31 + dy, "F")
    # wand (right hand up) + star
    g.vline(39, 24 + dy, 30 + dy, "Y")
    star = [(39, 20), (38, 21), (40, 21), (39, 22), (37, 20), (41, 20)]
    for x, y in star:
        g.set(x, y + dy, "G")
    # legs dangling
    g.vline(29, 42 + dy, 46 + dy, "F")
    g.vline(33, 42 + dy, 46 + dy, "F")
    g.set(29, 47 + dy, "Y"); g.set(33, 47 + dy, "Y")
    return g


# ---------------------------------------------------------------- fox
def fox(frame):
    g = Grid()
    dy = 1 if frame == 1 else 0
    tail_up = -3 if frame == 1 else 0
    # tail: bushy sweep along the ground, white tip; frame 1 lifts tip
    tail = [(22, 50), (20, 48), (19, 46), (20, 44), (23, 43)]
    for i, (x, y) in enumerate(tail):
        g.set(x, y + dy, "O")
        g.set(x + 1, y + dy, "o")
    tip_y = 41 + dy + tail_up
    g.set(24, tip_y, "W"); g.set(25, tip_y, "W"); g.set(24, tip_y + 1, "W")
    # ears
    for ex in (25, 37):
        g.set(ex, 22 + dy, "O"); g.set(ex, 23 + dy, "O")
        g.set(ex + (1 if ex > 31 else -1), 23 + dy, "D")
        g.set(ex + (2 if ex > 31 else -2), 24 + dy, "O")
    # head
    g.ellipse(31, 29 + dy, 8, 6, "O", "D")
    # muzzle + nose
    g.ellipse(31, 33 + dy, 4, 2, "W")
    g.set(31, 32 + dy, "D"); g.set(31, 33 + dy, "D")
    # eyes: green
    g.set(26, 29 + dy, "G"); g.set(36, 29 + dy, "G")
    g.set(26, 28 + dy, "W") if frame == 0 else g.hline(29 + dy, 25, 27, "D")
    g.set(36, 28 + dy, "W") if frame == 0 else g.hline(29 + dy, 35, 37, "D")
    # chest fluff
    g.ellipse(31, 40 + dy, 4, 5, "C")
    # body
    g.ellipse(31, 43 + dy, 8, 7, "O", "D")
    for y in range(40, 50):
        g.set(24, y + dy, "o"); g.set(38, y + dy, "o")
    # front legs
    g.rect(26, 48 + dy, 28, 54 + dy, "O")
    g.rect(34, 48 + dy, 36, 54 + dy, "O")
    g.hline(54 + dy, 26, 28, "D")
    g.hline(54 + dy, 34, 36, "D")
    return g


# ---------------------------------------------------------------- cat
def cat(frame):
    g = Grid()
    dy = 1 if frame == 1 else 0
    # ears
    for ex in (26, 36):
        g.set(ex, 23 + dy, "G")
        g.set(ex + (1 if ex > 31 else -1), 24 + dy, "G")
        g.set(ex, 24 + dy, "P")
    # head
    g.ellipse(31, 30 + dy, 8, 6, "G", "D")
    # tabby stripes on top
    for dx in (-4, 0, 4):
        g.set(31 + dx, 25 + dy, "S")
        g.set(31 + dx, 26 + dy, "S")
    # eyes
    if frame == 0:
        g.set(27, 30 + dy, "W"); g.set(27, 30 + dy, "P")
        g.set(35, 30 + dy, "W"); g.set(35, 30 + dy, "P")
        g.set(26, 29 + dy, "W"); g.set(34, 29 + dy, "W")
    else:  # blink
        g.hline(30 + dy, 26, 28, "D")
        g.hline(30 + dy, 34, 36, "D")
    # muzzle + nose
    g.ellipse(31, 34 + dy, 3, 2, "C")
    g.set(31, 33 + dy, "P")
    # whiskers
    for dx in (-6, 6):
        g.set(31 + dx, 33 + dy, "W"); g.set(31 + dx + (1 if dx > 0 else -1), 34 + dy, "W")
    # body
    g.ellipse(31, 44 + dy, 8, 8, "G", "D")
    # chest patch
    g.ellipse(31, 46 + dy, 4, 5, "C")
    # stripes on body
    for dx in (-5, 5):
        for y in (42, 45, 48):
            g.set(31 + dx, y + dy, "S")
    # front paws
    g.rect(27, 51 + dy, 29, 54 + dy, "H")
    g.rect(33, 51 + dy, 35, 54 + dy, "H")
    # tail wrapped around the front
    tail = [(39, 52 + dy), (38, 53 + dy), (34, 54 + dy), (29, 54 + dy), (25, 53 + dy)]
    for x, y in tail:
        g.set(x, y, "S")
    if frame == 1:
        g.set(24, 52 + dy, "S")  # tail flick tip
    return g


BASE = {"owl": owl, "dragon": dragon, "fairy": fairy, "fox": fox, "cat": cat}

# state decorations drawn over the base
def decorate(g, companion, state):
    if state == "idle":
        return
    a = ACCENT[companion]
    if state == "inProgress":
        # sweat drop + motion dashes ("B" not in every palette)
        sweat = {"dragon": "W", "fox": "g"}.get(companion, "B")
        for x, y in [(42, 22), (42, 23), (41, 24)]:
            g.set(x, y, sweat)
        g.hline(24, 56, 58, "W"); g.hline(28, 57, 59, "W")
    elif state == "encouraging":
        # "!" above the head
        g.rect(30, 10, 32, 15, a)
        g.rect(30, 17, 32, 18, a)
    elif state == "celebrating":
        # confetti
        pts = [(16, 14), (22, 10), (40, 9), (46, 13), (12, 26), (50, 24), (18, 34), (46, 34)]
        for i, (x, y) in enumerate(pts):
            g.set(x, y, "W" if i % 2 == 0 else a)
            g.set(x + 1, y, a if i % 2 == 0 else "W")
        # star overhead
        g.set(31, 8, a); g.set(30, 9, "W"); g.set(32, 9, "W"); g.set(31, 10, "W")
    elif state == "bonusClaimed":
        # gem + sparkles
        gem = [(40, 12), (39, 13), (40, 13), (41, 13), (38, 14), (42, 14),
               (39, 15), (40, 15), (41, 15), (40, 16)]
        for x, y in gem:
            g.set(x, y, a if (x + y) % 2 == 0 else "W")
        for x, y in [(20, 12), (24, 16), (46, 20)]:
            g.set(x, y, "W")


STATES = ["idle", "inProgress", "encouraging", "celebrating", "bonusClaimed"]
COMPANIONS = ["owl", "dragon", "fairy", "fox", "cat"]


def preview():
    from PIL import Image, ImageDraw
    # map palette chars to colors for preview (approximate from MascotSprites.swift)
    PALS = {
        "owl": {"D": (59,36,18), "B": (138,90,51), "S": (95,61,32), "H": (185,138,95), "C": (242,227,198), "Y": (247,201,72), "P": (33,26,21), "W": (255,255,255), "O": (232,134,46)},
        "dragon": {"D": (58,13,13), "R": (198,40,40), "S": (142,27,27), "H": (239,83,80), "O": (232,115,42), "Y": (249,212,35), "W": (255,255,255), "P": (26,26,26)},
        "fairy": {"D": (45,27,61), "P": (236,111,168), "S": (155,77,158), "H": (249,168,212), "F": (251,216,196), "Y": (245,215,110), "B": (59,130,246), "W": (255,255,255), "K": (30,58,138), "G": (253,224,71)},
        "fox": {"D": (0,0,0), "W": (248,250,252), "O": (232,115,42), "o": (194,65,12), "H": (254,215,170), "G": (34,197,94), "g": (22,101,52), "B": (0,0,0), "F": (124,45,18), "P": (26,26,26), "C": (245,230,200)},
        "cat": {"D": (42,42,46), "G": (154,160,166), "S": (107,114,128), "H": (209,213,219), "C": (245,230,200), "W": (255,255,255), "P": (240,140,158), "B": (0,0,0)},
    }
    scale = 2
    w = h = 64 * scale
    cols = 5  # states
    rows = len(COMPANIONS)
    sheet = Image.new("RGBA", (cols * w, rows * (h + 12)), (40, 40, 40, 255))
    d = ImageDraw.Draw(sheet)
    for r, comp in enumerate(COMPANIONS):
        for c, state in enumerate(STATES):
            grid = compose(comp, state, 0)
            img = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
            px = img.load()
            pal = PALS[comp]
            for y in range(64):
                for x in range(64):
                    ch = grid.g[y][x]
                    if ch != "." and ch in pal:
                        px[x, y] = pal[ch] + (255,)
            big = img.resize((w, h), Image.NEAREST)
            x0, y0 = c * w, r * (h + 12)
            sheet.paste(big, (x0, y0), big)
            if r == 0:
                d.text((x0 + 4, y0 + 2), state, fill=(255, 255, 0, 255))
        d.text((4, r * (h + 12) + 2), comp, fill=(0, 255, 255, 255))
    sheet.save("/tmp/mascots_preview.png")
    print("/tmp/mascots_preview.png")


def compose(companion, state, frame):
    g = BASE[companion](frame)
    decorate(g, companion, state)
    return g


def emit():
    header = (
        "//\n"
        "//  MascotSpriteGrids.swift\n"
        "//  LootList\n"
        "//\n"
        "//  GENERATED by tools/generate_pixel_mascots.py — edit that script, not this file.\n"
        "//  Real pixel art for the 5 companions; keys are \"companion_state_frame\".\n"
        "//  Palettes live in MascotSprites.swift and are unchanged.\n"
        "//\n"
        "\n"
        "import SwiftUI\n"
        "\n"
        "enum MascotSpriteGrids {\n"
        "    static let frames: [String: [String]] = [\n"
    )
    entries = []
    for comp in COMPANIONS:
        for state in STATES:
            for frame in (0, 1):
                g = compose(comp, state, frame)
                rows = ["".join(r) for r in g.g]
                rows_str = ",\n".join(f'        "{r}"' for r in rows)
                entries.append(f'        "{comp}_{state}_{frame}": [\n{rows_str}\n        ]')
    body = header + ",\n".join(entries) + "\n    ]\n}\n"
    with open("Project/Resources/SpriteData/MascotSpriteGrids.swift", "w") as f:
        f.write(body)
    print("wrote MascotSpriteGrids.swift")


if __name__ == "__main__":
    import sys
    if "--emit" in sys.argv:
        emit()
    else:
        preview()

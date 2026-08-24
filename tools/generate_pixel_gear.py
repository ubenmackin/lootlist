#!/usr/bin/env python3
"""Pixel gear generator: 1px-density equipment overlays drawn on 64x64.

Each gear piece is drawn programmatically, positioned relative to the base
sprite geometry (head top y~13, center x~31, feet y~61). Preview composites
each piece over the knight base for visual review; --emit writes Swift.
"""

from PIL import Image, ImageDraw
import sys

SRC = "assets/blanks"
K = (26, 20, 30, 255)  # outline


def hexc(s):
    s = s.lstrip("#")
    return (int(s[0:2], 16), int(s[2:4], 16), int(s[4:6], 16), 255)


def canvas():
    img = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
    return img, ImageDraw.Draw(img)


# --- crown: sits on the helm (helm top ~y13, center x31) -------------------
def crown():
    img, d = canvas()
    G, GL, GD, R = hexc("FDE047"), hexc("FEF9C3"), hexc("D4A017"), hexc("DC2626")
    y0 = 13   # band hugs the helm dome (helm top y13); points rise above
    # points (3 peaks)
    for i, (cx, hgt) in enumerate([(26, 5), (33, 7), (40, 5)]):
        for j in range(hgt):
            half = 1 if j < hgt - 2 else (2 if j < hgt - 1 else 3)
            for x in range(cx - half, cx + half + 1):
                d.point((x, y0 + j), fill=G)
        d.point((cx, y0), fill=GL)
    # band
    for x in range(23, 44):
        d.point((x, y0 + 5), fill=G)
        d.point((x, y0 + 6), fill=GD)
    # gems on band
    for x, c in [(27, R), (33, hexc("22D3EE")), (39, R)]:
        d.point((x, y0 + 5), fill=c)
    # outline pass
    px = img.load()
    for x in range(22, 45):
        for y in range(y0, y0 + 7):
            if px[x, y][3] == 0:
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < 64 and 0 <= ny < 64 and px[nx, ny][3] > 0:
                        d.point((x, y), fill=K)
                        break
    return img


# --- flaming sword: held at right side -------------------------------------
def flaming_sword():
    img, d = canvas()
    Y, O, R = hexc("FDE047"), hexc("F97316"), hexc("B91C1C")
    S, SD, H = hexc("E2E8F0"), hexc("94A3B8"), hexc("854D0E")
    # blade: 3px wide, flame sheath on both edges
    for y in range(19, 47):
        d.point((49, y), fill=Y)
        d.point((50, y), fill=S)
        d.point((51, y), fill=S)
        d.point((52, y), fill=SD)
        if y % 3 == 0:
            d.point((53, y), fill=O)
            d.point((54, y - 1), fill=R)
        elif y % 3 == 1:
            d.point((53, y), fill=Y)
        else:
            d.point((53, y), fill=O)
        if y % 4 == 2:
            d.point((48, y), fill=O)
    # flame tip
    d.point((50, 17), fill=Y); d.point((51, 16), fill=Y)
    d.point((52, 15), fill=O); d.point((53, 14), fill=O); d.point((54, 13), fill=R)
    # guard
    for x in range(47, 56):
        d.point((x, 47), fill=hexc("92400E"))
    d.point((48, 47), fill=H); d.point((55, 47), fill=H)
    # grip + pommel
    for y in range(48, 54):
        d.point((50, y), fill=H)
        d.point((51, y), fill=hexc("5C2E06"))
    d.point((50, 54), fill=hexc("FDE047")); d.point((51, 54), fill=hexc("D4A017"))
    return img


# --- crystal staff: left side, tall ----------------------------------------
def crystal_staff():
    img, d = canvas()
    W, WD = hexc("6B4423"), hexc("4A2E17")
    C, CL, CG = hexc("22D3EE"), hexc("A5F3FC"), hexc("06B6D4")
    cx = 13
    # diamond crystal: (y, width) rows
    for y, wdt in [(10, 1), (11, 3), (12, 5), (13, 5), (14, 3), (15, 1)]:
        for dx in range(-(wdt // 2), wdt // 2 + 1):
            c = CL if dx < 0 else (CG if dx > 0 else C)
            d.point((cx + dx, y), fill=c)
    # shaft
    for y in range(16, 60):
        d.point((cx, y), fill=W)
        d.point((cx + 1, y), fill=WD)
    # gold wraps
    for y in (30, 31, 44, 45):
        d.point((cx, y), fill=hexc("D4A017"))
        d.point((cx + 1, y), fill=hexc("92400E"))
    # glow sparks
    for x, y in [(8, 9), (18, 8), (19, 15), (7, 17)]:
        d.point((x, y), fill=CL)
    return img


# --- golden wings: behind shoulders ----------------------------------------
def golden_wings():
    img, d = canvas()
    GL, G, GD = hexc("FEF9C3"), hexc("FDE047"), hexc("D4A017")
    left = [(27, 26), (13, 15), (4, 17), (10, 27), (5, 34), (14, 39), (26, 38)]
    for mirror in (False, True):
        pts = [((62 - x) if mirror else x, y) for x, y in left]
        d.polygon(pts, fill=G)
        # feather separations (dark lines from anchor outward)
        for tip in [(8, 20), (6, 30), (12, 36)]:
            tx = (62 - tip[0]) if mirror else tip[0]
            for s in range(9):
                x = 27 + (tx - 27) * s // 8
                y = 28 + (tip[1] - 28) * s // 8
                d.point((x, y), fill=GD)
        # top highlight edge
        for s in range(15):
            x = 27 + (13 - 27) * s // 14
            y = 26 + (15 - 26) * s // 14
            d.point(((62 - x) if mirror else x, y), fill=GL)
    return img


# --- lightning: small bolts -------------------------------------------------
def lightning():
    img, d = canvas()
    C, W = hexc("38BDF8"), hexc("E0F2FE")
    for bx, by, flip in [(9, 14, 1), (49, 10, -1), (52, 40, -1), (8, 42, 1)]:
        x, y = bx, by
        for seg in range(4):
            dx = flip if seg % 2 == 0 else -flip
            for i in range(3):
                d.point((x, y), fill=C)
                d.point((x, y - 1), fill=W)
                x += dx
            y += 2
        d.point((x - dx, y), fill=W)
    return img


# --- phoenix wings: fiery red-orange wings ----------------------------------
def phoenix_wings():
    img, d = canvas()
    GL, G, GD = hexc("FED7AA"), hexc("F97316"), hexc("C2410C")
    left = [(27, 26), (13, 15), (4, 17), (10, 27), (5, 34), (14, 39), (26, 38)]
    for mirror in (False, True):
        pts = [((62 - x) if mirror else x, y) for x, y in left]
        d.polygon(pts, fill=G)
        for tip in [(8, 20), (6, 30), (12, 36)]:
            tx = (62 - tip[0]) if mirror else tip[0]
            for s3 in range(9):
                x = 27 + (tx - 27) * s3 // 8
                y = 28 + (tip[1] - 28) * s3 // 8
                d.point((x, y), fill=GD)
        for s3 in range(15):
            x = 27 + (13 - 27) * s3 // 14
            y = 26 + (15 - 26) * s3 // 14
            d.point(((62 - x) if mirror else x, y), fill=GL)
    for x, y in [(16, 12), (20, 10), (44, 12), (48, 10), (12, 14), (52, 14)]:
        d.point((x, y), fill=G)
        d.point((x, y - 1), fill=GL)
    return img


# --- shadow cloak: flowing cape behind (sweeps left, wavy hem) -------------
def shadow_cloak():
    img, d = canvas()
    C, CD, RIM = hexc("2A1B3D"), hexc("191026"), hexc("4A3266")
    # cape: anchored at the shoulders, flares down with a leftward sweep
    for y in range(23, 58):
        t = (y - 23) / 34.0
        cx = 31 - int(6 * t)
        half = 13 + int(3 * t)
        for x in range(cx - half, cx + half + 1):
            c = CD if x > cx else C
            d.point((x, y), fill=c)
        d.point((cx - half, y), fill=RIM)
    # shoulder mantle
    for x in range(17, 46):
        d.point((x, 23), fill=RIM)
        d.point((x, 24), fill=C)
    # wavy hem (alternating swags)
    for x in range(12, 48):
        swag = (x // 6) % 2
        hem = 57 + swag + (1 if x % 6 == 0 else 0)
        for y in range(58, hem + 1):
            d.point((x, y), fill=C if swag == 0 else CD)
    return img


# --- sparkles: 4-point stars -----------------------------------------------
def sparkles():
    img, d = canvas()
    W, G = hexc("FFFFFF"), hexc("FDE047")
    pts = [(12, 16), (50, 12), (54, 34), (10, 40), (46, 52), (16, 54), (40, 8), (24, 10)]
    for i, (x, y) in enumerate(pts):
        c = W if i % 2 == 0 else G
        d.point((x, y), fill=c)
        d.point((x - 1, y), fill=c); d.point((x + 1, y), fill=c)
        d.point((x, y - 1), fill=c); d.point((x, y + 1), fill=c)
    return img


# --- cosmic aura: nebula clouds + stars behind ------------------------------
def star_aura():
    img, d = canvas()
    import random
    random.seed(11)
    V, I, CY, M = hexc("6D28D9"), hexc("312E81"), hexc("0E7490"), hexc("A21CAF")
    blobs = [(20, 26, 13, V), (44, 30, 12, I), (30, 44, 11, CY), (40, 18, 8, M), (18, 42, 8, V)]
    for bx, by, r, col in blobs:
        for y in range(by - r, by + r + 1):
            for x in range(bx - r, bx + r + 1):
                dist2 = (x - bx) ** 2 + (y - by) ** 2
                if dist2 > r * r:
                    continue
                frac = (dist2 / (r * r)) ** 0.5
                if frac < 0.55 or random.randint(0, 255) < int(255 * (1 - frac)):
                    d.point((x, y), fill=col)
    for _ in range(26):
        x, y = random.randint(2, 61), random.randint(2, 61)
        c = random.choice((hexc("FFFFFF"), hexc("C4B5FD"), hexc("A5F3FC")))
        d.point((x, y), fill=c)
        if random.random() < 0.4:
            d.point((x - 1, y), fill=c)
            d.point((x, y + 1), fill=c)
    return img


# --- bandana: red band + trailing tails -------------------------------------
def bandana():
    img, d = canvas()
    R, RD, RL = hexc("B91C1C"), hexc("7F1D1D"), hexc("EF4444")
    # band across the forehead
    for y in (16, 17, 18):
        for x in range(21, 42):
            c = RL if y == 16 else (RD if y == 18 else R)
            d.point((x, y), fill=c)
    # knot on the right
    for x in (42, 43):
        for y in (16, 17, 18):
            d.point((x, y), fill=RD)
    # tails flowing down-right
    tail = [(44, 19), (45, 20), (46, 21), (47, 22), (48, 23), (49, 24),
            (50, 25), (51, 26), (51, 27), (52, 28), (53, 29)]
    for i, (x, y) in enumerate(tail):
        d.point((x, y), fill=R if i % 2 == 0 else RD)
        d.point((x - 1, y), fill=R if i % 2 else RD)
    return img


# --- viking helm: steel dome + horns ----------------------------------------
def viking_helm():
    img, d = canvas()
    S, SD, SL = hexc("6B7280"), hexc("4B5563"), hexc("9CA3AF")
    B, BS, BD = hexc("E7E5E4"), hexc("D6D3D1"), hexc("A8A29E")
    # dome: rounded cap hugging the head (head top y13, center x31)
    dome = [(9, 5), (10, 8), (11, 10), (12, 12), (13, 13), (14, 14),
            (15, 14), (16, 15), (17, 15), (18, 15)]
    for y, half in dome:
        for x in range(31 - half, 31 + half + 1):
            c = SL if x <= 31 - half + 2 else (SD if x >= 31 + half - 1 else S)
            d.point((x, y), fill=c)
    # rivet band along the bottom
    for x in range(20, 43, 3):
        d.point((x, 17), fill=SL)
    # horns: thick curved bone horns rising outward
    for mirror in (False, True):
        horn = [(21, 12), (19, 10), (17, 8), (15, 6), (13, 5), (12, 4), (11, 3)]
        for i, (x, y) in enumerate(horn):
            xx = (62 - x) if mirror else x
            d.point((xx, y), fill=B)
            d.point((xx + (1 if mirror else -1), y), fill=BS)
            d.point((xx, y + 1), fill=BS)
            if i >= len(horn) - 3:  # dark tips
                d.point((xx, y - 1), fill=BD)
    return img


# --- knight visor: steel band across the face --------------------------------
def knight_visor():
    img, d = canvas()
    S, SD, SL = hexc("94A3B8"), hexc("475569"), hexc("E2E8F0")
    # visor plate across the eyes
    for y in range(20, 27):
        for x in range(20, 43):
            c = SL if y == 20 else (SD if y == 26 or x < 22 or x > 40 else S)
            d.point((x, y), fill=c)
    # eye slits
    for x in range(24, 30):
        d.point((x, 22), fill=K)
        d.point((x, 23), fill=K)
    for x in range(33, 39):
        d.point((x, 22), fill=K)
        d.point((x, 23), fill=K)
    # rivets
    for x in (21, 41):
        for y in (21, 25):
            d.point((x, y), fill=SL)
    # side wings
    for x in (18, 19, 44, 45):
        d.point((x, 22), fill=SD)
        d.point((x, 23), fill=S)
    return img


# --- shadow daggers: twin violet daggers at the hips -------------------------
def shadow_daggers():
    img, d = canvas()
    B, BG, G = hexc("4C1D95"), hexc("A78BFA"), hexc("312E81")
    for bx in (12, 50):
        flip = 1 if bx < 31 else -1
        # blade pointing down-inward
        for i in range(12):
            x = bx + flip * i // 4
            y = 30 + i
            d.point((x, y), fill=B)
            d.point((x + flip, y), fill=G)
            if i % 3 == 0:
                d.point((x, y + 1), fill=BG)
        d.point((bx + flip * 3, 43), fill=BG)
        # guard + grip
        for dx in (-2, -1, 0, 1, 2):
            d.point((bx + dx + flip, 29), fill=hexc("854D0E"))
        for i in range(4):
            d.point((bx - flip * i // 2, 27 - i), fill=hexc("5C2E06"))
        d.point((bx - flip * 2, 23), fill=hexc("A78BFA"))
    return img


# --- holy mace: golden mace, right side --------------------------------------
def holy_mace():
    img, d = canvas()
    G, GL, GD = hexc("FDE047"), hexc("FEF9C3"), hexc("B45309")
    W = hexc("FFFFFF")
    # shaft
    for y in range(30, 54):
        d.point((50, y), fill=GD)
        d.point((51, y), fill=hexc("92400E"))
    d.point((50, 30), fill=GL)
    # head: spiked orb
    cx, cy = 50, 24
    for dx in range(-3, 4):
        for dy in range(-3, 4):
            if dx * dx + dy * dy <= 9:
                c = GL if dx < 0 else (GD if dx > 1 else hexc("FDE047"))
                d.point((cx + dx, cy + dy), fill=c)
    # spikes
    for dx, dy in [(-4, 0), (4, 0), (0, -4), (0, 4), (-3, -3), (3, 3), (-3, 3), (3, -3)]:
        d.point((cx + dx, cy + dy), fill=GL)
    # halo glint + cross sparkle
    d.point((cx - 2, cy - 2), fill=W)
    for dx, dy in [(0, -8), (-1, -8), (1, -8), (0, -7), (0, -9)]:
        d.point((cx + dx, cy + dy), fill=W)
    return img


# --- dragon bow: curved bow, left side ---------------------------------------
def dragon_bow():
    img, d = canvas()
    W, WD = hexc("6B4423"), hexc("4A2E17")
    GR = hexc("15803D")
    STR = hexc("D6D3D1")
    # bow arc: from (18,14) bulging left to (16,52)
    import math
    arc = []
    for t in range(0, 101, 3):
        tt = t / 100.0
        ang = -math.pi / 2 + tt * math.pi
        x = int(14 + 8 * math.cos(ang))
        y = int(33 + 19 * math.sin(ang))
        arc.append((x, y))
    for x, y in arc:
        d.point((x, y), fill=W)
        d.point((x + 1, y), fill=W)
        d.point((x + 2, y), fill=WD)
    # green scale wraps at grip and tips
    for x, y in arc[14:19] + arc[:3] + arc[-3:]:
        d.point((x, y), fill=GR)
        d.point((x + 1, y), fill=GR)
    # string
    top, bot = arc[0], arc[-1]
    for s2 in range(40):
        x = top[0] + (bot[0] - top[0]) * s2 // 39
        y = top[1] + (bot[1] - top[1]) * s2 // 39
        d.point((x + 5, y), fill=STR)
    return img


# --- royal cape: crimson + gold trim, symmetric ------------------------------
def royal_cape():
    img, d = canvas()
    R, RD, G, W = hexc("9F1239"), hexc("6B0F2A"), hexc("FDE047"), hexc("F8FAFC")
    for y in range(23, 58):
        t = (y - 23) / 34.0
        half = 13 + int(3 * t)
        for x in range(31 - half, 31 + half + 1):
            c = R if x <= 31 else RD
            d.point((x, y), fill=c)
        # gold trim edges
        d.point((31 - half, y), fill=G)
        d.point((31 + half, y), fill=G)
    # ermine collar
    for x in range(18, 45):
        d.point((x, 23), fill=W)
        if x % 3 == 0:
            d.point((x, 23), fill=K)
    # gold hem swags
    for x in range(14, 49):
        swag = (x // 6) % 2
        hem = 57 + swag
        d.point((x, hem), fill=G)
    return img


# --- frostweave: icy cape with frost crystals --------------------------------
def frostweave():
    img, d = canvas()
    B, BD, RIM = hexc("93C5FD"), hexc("60A5FA"), hexc("DBEAFE")
    import random
    random.seed(5)
    for y in range(23, 58):
        t = (y - 23) / 34.0
        cx = 31 + int(4 * t)   # sweeps right for variety vs shadow cloak
        half = 13 + int(3 * t)
        for x in range(cx - half, cx + half + 1):
            c = BD if x > cx else B
            d.point((x, y), fill=c)
        d.point((cx - half, y), fill=RIM)
    # frost crystals along the edges
    for _ in range(30):
        x = random.randint(12, 50)
        y = random.randint(24, 57)
        if random.random() < 0.5:
            d.point((x, y), fill=RIM)
            d.point((x, y - 1), fill=RIM)
    # hem
    for x in range(14, 50):
        d.point((x, 57 + (x // 6) % 2), fill=RIM)
    return img


# --- mystic runes: floating glowing glyphs -----------------------------------
def mystic_runes():
    img, d = canvas()
    C, G = hexc("22D3EE"), hexc("FDE047")
    runes = [
        # each rune: list of (dx, dy) strokes, 4 tall
        [(0, 0), (0, 1), (0, 2), (1, 0), (2, 1), (0, 3)],          # Fehu-ish
        [(1, 0), (0, 1), (1, 2), (2, 1), (1, 3), (1, 1)],          # Ing-ish
        [(0, 0), (1, 1), (0, 2), (1, 3), (2, 0), (2, 2)],          # Thurisaz-ish
        [(0, 0), (0, 1), (0, 2), (0, 3), (1, 1), (2, 2)],          # Laguz-ish
        [(0, 0), (1, 0), (2, 0), (1, 1), (1, 2), (0, 3), (2, 3)],  # Odal-ish
        [(0, 0), (1, 1), (2, 2), (2, 3), (0, 2)],                  # zig
    ]
    spots = [(8, 16), (52, 20), (5, 38), (54, 42), (14, 6), (46, 6)]
    for i, ((rx, ry), glyph) in enumerate(zip(spots, runes)):
        c = C if i % 2 == 0 else G
        dim = hexc("155E75") if i % 2 == 0 else hexc("B45309")
        for dx, dy in glyph:
            d.point((rx + dx, ry + dy), fill=c)
            d.point((rx + dx + 1, ry + dy), fill=dim)  # glow trail
    return img


# --- companion: glow sprite wisp (upper left) --------------------------------
def glow_sprite():
    img, d = canvas()
    W, C, CY = hexc("FFFFFF"), hexc("67E8F9"), hexc("22D3EE")
    cx, cy = 12, 20
    for dx in range(-4, 5):
        for dy in range(-4, 5):
            dist2 = dx * dx + dy * dy
            if dist2 <= 4:
                d.point((cx + dx, cy + dy), fill=W if dist2 <= 1 else C)
            elif dist2 <= 12 and (dx + dy) % 2 == 0:
                d.point((cx + dx, cy + dy), fill=CY)
    # trailing sparks
    for x, y in [(17, 26), (19, 29), (8, 27), (6, 24)]:
        d.point((x, y), fill=CY)
    return img


# --- companion: familiar cat (lower right) -----------------------------------
def familiar_cat():
    img, d = canvas()
    B, BD = hexc("23232D"), hexc("16161F")
    W, G = hexc("FFFFFF"), hexc("FDE047")
    cx, cy = 46, 46
    # body (sitting)
    for y in range(cy, cy + 11):
        half = 2 if y < cy + 3 else (4 if y < cy + 8 else 3)
        for x in range(cx - half, cx + half + 1):
            c = B if x <= cx else BD
            d.point((x, y), fill=c)
    # head
    for y in range(cy - 5, cy):
        half = 4 if y > cy - 4 else 3
        for x in range(cx - half, cx + half + 1):
            d.point((x, y), fill=B)
    # ears
    for dx in (-3, 3):
        d.point((cx + dx, cy - 6), fill=B)
        d.point((cx + dx, cy - 5), fill=BD)
    # eyes
    d.point((cx - 2, cy - 3), fill=G)
    d.point((cx + 2, cy - 3), fill=G)
    # collar
    for x in range(cx - 3, cx + 4):
        d.point((x, cy), fill=hexc("DC2626"))
    # tail curling up the right
    tail = [(cx + 4, cy + 8), (cx + 5, cy + 6), (cx + 5, cy + 4), (cx + 4, cy + 2)]
    for x, y in tail:
        d.point((x, y), fill=BD)
    return img


# --- companion: baby griffin (upper left) ------------------------------------
def baby_griffin():
    img, d = canvas()
    T, TD = hexc("D9A066"), hexc("B0713A")
    W = hexc("F8FAFC")
    G = hexc("FDE047")
    cx, cy = 12, 16
    # body
    for y in range(cy, cy + 8):
        half = 5 if y < cy + 5 else 4
        for x in range(cx - half, cx + half + 1):
            d.point((x, y), fill=T if x <= cx else TD)
    # head (white, above-left)
    for y in range(cy - 5, cy - 1):
        for x in range(cx - 3, cx + 2):
            d.point((x, y), fill=W)
    # beak
    d.point((cx + 2, cy - 3), fill=G)
    d.point((cx + 3, cy - 3), fill=hexc("D4A017"))
    # eye
    d.point((cx, cy - 4), fill=K)
    # wing hint
    for x in range(cx - 3, cx + 1):
        d.point((x, cy + 1), fill=TD)
    # talons
    d.point((cx - 1, cy + 6), fill=G)
    d.point((cx + 1, cy + 6), fill=G)
    # ear tufts
    d.point((cx - 3, cy - 6), fill=W)
    d.point((cx + 1, cy - 6), fill=W)
    return img


# --- companion: dragon hatchling (right) -------------------------------------
def dragon_hatchling():
    img, d = canvas()
    R, RD = hexc("DC2626"), hexc("7F1D1D")
    B = hexc("FCA5A5")
    Y = hexc("FDE047")
    cx, cy = 47, 20
    # body
    for y in range(cy, cy + 7):
        half = 3 if y < cy + 5 else 2
        for x in range(cx - half, cx + half + 1):
            d.point((x, y), fill=R if x <= cx else RD)
    # belly
    for x in range(cx - 1, cx + 2):
        d.point((x, cy + 4), fill=B)
        d.point((x, cy + 5), fill=B)
    # head
    for y in range(cy - 4, cy):
        for x in range(cx - 3, cx + 2):
            d.point((x, y), fill=R)
    # snout
    d.point((cx + 2, cy - 2), fill=RD)
    # eye
    d.point((cx, cy - 2), fill=Y)
    # horn nubs
    d.point((cx - 2, cy - 5), fill=B)
    d.point((cx + 1, cy - 5), fill=B)
    # wings
    for i, dx in enumerate((-5, -4, -3)):
        d.point((cx + dx, cy + i), fill=RD)
    for i, dx in enumerate((4, 5, 6)):
        d.point((cx + dx, cy + i), fill=RD)
    # tail
    for i, (dx, dy) in enumerate([(-4, 6), (-5, 7), (-6, 7), (-7, 6)]):
        d.point((cx + dx, cy + dy - 4 + i), fill=RD)
    return img


# --- wizard hat (equipable gear version, matches mage style) ----------------
def wizard_hat():
    img = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
    # reuse the mage hat drawing anchored to a generic head (cx=31, brim y=18)
    import importlib.util
    spec = importlib.util.spec_from_file_location("gpb", "tools/generate_pixel_bases.py")
    gpb = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(gpb)
    blank = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
    return gpb.draw_wizard_hat(blank, **gpb.VIOLET)


GEAR = {
    "crown": crown,
    "bandana": bandana,
    "viking_helm": viking_helm,
    "knight_visor": knight_visor,
    "shadow_daggers": shadow_daggers,
    "holy_mace": holy_mace,
    "dragon_bow": dragon_bow,
    "royal_cape": royal_cape,
    "frostweave": frostweave,
    "mystic_runes": mystic_runes,
    "glow_sprite": glow_sprite,
    "familiar_cat": familiar_cat,
    "baby_griffin": baby_griffin,
    "dragon_hatchling": dragon_hatchling,
    "crystal_staff": crystal_staff,
    "flaming_sword": flaming_sword,
    "golden_wings": golden_wings,
    "phoenix_wings": phoenix_wings,
    "shadow_cloak": shadow_cloak,
    "sparkles": sparkles,
    "lightning": lightning,
    "star_aura": star_aura,
    "wizard_hat": wizard_hat,
}

BACKGROUND = {"golden_wings", "shadow_cloak", "star_aura", "cosmic", "royal_cape", "frostweave", "mystic_runes"}


def preview():
    base = Image.open(f"{SRC}/soldier_helm.png").convert("RGBA")
    items = sorted(GEAR)
    scale = 2
    w = h = 64 * scale
    cols = 3
    rows = (len(items) + cols - 1) // cols
    sheet = Image.new("RGBA", (cols * w, rows * (h + 14)), (40, 40, 40, 255))
    d = ImageDraw.Draw(sheet)
    for i, name in enumerate(items):
        gear = GEAR[name]()
        comp = Image.alpha_composite(gear, base) if name in BACKGROUND else Image.alpha_composite(base, gear)
        big = comp.resize((w, h), Image.NEAREST)
        x, y = (i % cols) * w, (i // cols) * (h + 14)
        sheet.paste(big, (x, y), big)
        d.text((x + 4, y + h + 1), name, fill=(255, 255, 0, 255))
    sheet.save("/tmp/gear_preview.png")
    print("/tmp/gear_preview.png")


def encode(img):
    CHARS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
    px = img.load()
    colors = {}
    for y in range(64):
        for x in range(64):
            p = px[x, y]
            if p[3] == 0:
                continue
            colors.setdefault(p[:3], None)
    keys = sorted(colors)
    if len(keys) > len(CHARS):
        raise ValueError("too many colors")
    mapping = {k: CHARS[i] for i, k in enumerate(keys)}
    rows = ["".join(mapping.get(px[x, y][:3], ".") if px[x, y][3] else "." for x in range(64))
            for y in range(64)]
    palette = {c: (r << 16) | (g << 8) | b for (r, g, b), c in mapping.items()}
    return rows, palette


def emit():
    out = ["""//
//  HeroAvatarSprites+PixelGear.swift
//  LootList
//
//  GENERATED by tools/generate_pixel_gear.py — edit that script, not this file.
//  1px-density equipment overlays drawn to match the pixel bases.
//

import SwiftUI

enum HeroAvatarPixelGear {
"""]
    for name, fn in GEAR.items():
        rows, palette = encode(fn())
        cap = ''.join(part.capitalize() for part in name.split('_'))
        grid = ",\n".join(f'        "{r}"' for r in rows)
        pal = '            ".": HeroAvatarSprites.cClear,\n' + ",\n".join(
            f'            "{c}": HeroAvatarSprites.color(hex: 0x{v:06X})'
            for c, v in sorted(palette.items()))
        out.append(f"""    static let {cap}Grid: [String] = [
{grid}
    ]

    static let {cap}Palette: [Character: Color] = [
{pal}
    ]
""")
    out.append("}\n")
    with open("Project/Resources/SpriteData/HeroAvatarSprites+PixelGear.swift", "w") as f:
        f.write("\n".join(out))
    print("wrote HeroAvatarSprites+PixelGear.swift")


if __name__ == "__main__":
    if "--emit" in sys.argv:
        emit()
    else:
        preview()

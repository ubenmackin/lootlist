#!/usr/bin/env python3
"""Prototype: recolors + mage hat for the new pixel bases.
Renders a preview contact sheet to /tmp/recolor_preview.png for visual review.
"""
from PIL import Image, ImageDraw

SRC = "assets/blanks"


def load(name):
    return Image.open(f"{SRC}/{name}").convert("RGBA")


def recolor(img, mapping):
    px = img.load()
    out = img.copy()
    po = out.load()
    w, h = img.size
    for y in range(h):
        for x in range(w):
            p = px[x, y]
            if p in mapping:
                po[x, y] = mapping[p]
    return out


def hexc(s):
    s = s.lstrip("#")
    return (int(s[0:2], 16), int(s[2:4], 16), int(s[4:6], 16), 255)


# --- Guardian: darker iron armor -----------------------------------------
ARMOR_MAP = {
    hexc("867E7F"): hexc("565B68"),  # armor light -> dark steel
    hexc("726B7E"): hexc("434754"),  # armor mid
    hexc("4D4A5D"): hexc("2E313B"),  # armor dark
    hexc("2E2533"): hexc("1F2129"),  # armor deepest
    hexc("FFFFFF"): hexc("B9C0CC"),  # shine dimmed
    hexc("C4B59F"): hexc("9A8C74"),  # trim darkened
}

# --- Rogue: female2 -> shadow-clothes palette -----------------------------
ROGUE_MAP = {
    # shirt off-white -> dark charcoal leather
    hexc("E5E6C7"): hexc("3A3F4E"),
    # blue pants family -> dark browns
    hexc("3C49AD"): hexc("4A3524"),
    hexc("466AC9"): hexc("5C4330"),
    hexc("322D6A"): hexc("33241A"),
    hexc("281E41"): hexc("221710"),
}

# --- Mage: male4 sweater -> violet robe -----------------------------------
MAGE_MAP = {
    hexc("797580"): hexc("5E4B96"),  # sweater main -> violet
    hexc("585561"): hexc("463878"),  # sweater shade
    hexc("A2A0A4"): hexc("7B69B0"),  # sweater light
    hexc("373340"): hexc("332A55"),  # sweater deepest
}


# --- Wizard hat: drawn programmatically, same 1px style -------------------
def draw_wizard_hat(img, band_hex="FDE047", cloth=(0x5E, 0x4B, 0x96),
                    cloth_light=(0x7B, 0x69, 0xB0), cloth_dark=(0x3A, 0x2E, 0x66),
                    cx=31, brim_y=18, brim_half=12, height=23, lean=10):
    """Floppy cone hat anchored over the head (heads are ~22px wide at x~31)."""
    out = img.copy()
    d = ImageDraw.Draw(out)
    C = cloth + (255,)
    L = cloth_light + (255,)
    D = cloth_dark + (255,)
    B = hexc(band_hex)
    K = (20, 16, 28, 255)

    def cone_rows():
        """Yield (y, x0, x1) from tip down to brim."""
        rows = []
        for i in range(height):          # i=0 at tip, height-1 at brim
            y = brim_y - height + i
            t = i / max(1, height - 1)
            half = max(1, int(round(1 + (brim_half - 1) * (t ** 1.7))))
            drift = int(round(lean * (t ** 1.7)))
            rows.append((y, cx - half + drift, cx + half + drift))
        return rows

    rows = cone_rows()
    # 1) black silhouette (1px larger) -> clean outline
    for y, x0, x1 in rows:
        for x in range(x0 - 1, x1 + 2):
            d.point((x, y), fill=K)
    d.point((rows[0][2] + 2, rows[0][0] - 1), fill=K)   # tip nub outline
    # 2) brim silhouette + brim
    for x in range(cx - brim_half - 2, cx + brim_half + 3):
        d.point((x, brim_y), fill=K)
        d.point((x, brim_y + 1), fill=K)
    # 3) colored cone
    for y, x0, x1 in rows:
        for x in range(x0, x1 + 1):
            if x >= x1 - 1:
                c = D
            elif x <= x0 + 2:
                c = L
            else:
                c = C
            d.point((x, y), fill=c)
    # 4) tip flop (little bend to the right)
    ty, tx = rows[0][0], rows[0][2]
    d.point((tx + 1, ty - 1), fill=C); d.point((tx + 2, ty - 1), fill=K)
    d.point((tx, ty - 1), fill=K);     d.point((tx + 1, ty - 2), fill=K)
    # 5) gold band (single row at cone base)
    yb, x0b, x1b = rows[-1]
    for x in range(x0b, x1b + 1):
        d.point((x, yb), fill=B)
    # 6) brim: top face light, underside dark
    for x in range(cx - brim_half - 1, cx + brim_half + 2):
        d.point((x, brim_y), fill=D if abs(x - cx) > brim_half - 3 else C)
        d.point((x, brim_y + 1), fill=hexc("241C3A"))
    return out


def sheet(images, labels, path):
    scale = 4
    w, h = 64 * scale, 64 * scale
    cols = len(images)
    s = Image.new("RGBA", (cols * w, h), (40, 40, 40, 255))
    for i, im in enumerate(images):
        big = im.resize((w, h), Image.NEAREST)
        s.paste(big, (i * w, 0), big)
    d = ImageDraw.Draw(s)
    for i, lab in enumerate(labels):
        d.text((i * w + 6, 4), lab, fill=(255, 255, 0, 255))
    s.save(path)
    print(path)


sh = load("soldier_helm.png")
shc = load("soldier_helm_cape.png")
snh = load("soldier_no_helm.png")
f2 = load("female2.png")
m4 = load("male4.png")
f1 = load("female1.png")
m3 = load("male3.png")

sheet(
    [sh, recolor(sh, ARMOR_MAP), shc, recolor(shc, ARMOR_MAP), snh, recolor(snh, ARMOR_MAP)],
    ["knight-helm", "guard-dark", "knight-cape", "guard-dark", "knight-nohelm", "guard-dark"],
    "/tmp/preview_guardian.png",
)

sheet(
    [f2, recolor(f2, ROGUE_MAP), m4, recolor(m4, MAGE_MAP),
     draw_wizard_hat(recolor(m4, MAGE_MAP)), draw_wizard_hat(f1), draw_wizard_hat(m3, cloth=(0x2E, 0x6B, 0x4B), cloth_light=(0x4E, 0x8B, 0x66), cloth_dark=(0x1E, 0x4A, 0x34))],
    ["female2", "rogue", "male4", "mage-robe", "mage+hat", "f1+hat", "m3+hat-green"],
    "/tmp/preview_mage_rogue.png",
)

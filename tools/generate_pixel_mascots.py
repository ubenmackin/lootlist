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
def trace_dragon():
    """Trace assets/mascot/dragon.jpg: 21px graph-paper grid on brown bg,
    keeping the source's own colors (black outline, charcoal body, gray
    shading, white, green iris) mapped to the dragon palette chars."""
    from PIL import Image
    img = Image.open("assets/mascot/dragon.jpg").convert("RGB")
    w, h = img.size
    px = img.load()
    P = 21

    def is_brown(c):
        r, g, b = c
        return r > 70 and r > b + 25 and abs(r - g) < 60 and g > 40

    from collections import deque
    bg = [[False] * w for _ in range(h)]
    q = deque()
    for x in range(w):
        for y in (0, h - 1):
            if is_brown(px[x, y]):
                bg[y][x] = True; q.append((x, y))
    for y in range(h):
        for x in (0, w - 1):
            if is_brown(px[x, y]):
                bg[y][x] = True; q.append((x, y))
    while q:
        x, y = q.popleft()
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            nx, ny = x + dx, y + dy
            if 0 <= nx < w and 0 <= ny < h and not bg[ny][nx] and is_brown(px[nx, ny]):
                bg[ny][nx] = True; q.append((nx, ny))
    xs = [x for x in range(w) for y in range(h) if not bg[y][x]]
    ys = [y for y in range(h) for x in range(w) if not bg[y][x]]
    x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)

    # snap grid origin to the paper lines
    best, best_off = None, None
    for off in range(P):
        centers = list(range(x0 + off, x1 + 1, P))
        if len(centers) < 8:
            continue
        score = sum(1 for cx in centers if is_brown(px[cx, max(0, y0 - 3)]))
        if best is None or score > best:
            best, best_off = score, off
    cols = list(range(x0 + (best_off or 0), x1 + 1, P))
    rows = list(range(y0 + ((best_off or 0) % P), y1 + 1, P))

    def g_ok(c):
        r, g, b = c
        return not is_brown(c) and g > r + 10 and g > 60 and g > b

    def classify(c):
        r, g, b = c
        if is_brown(c):
            return "."
        if g > r + 10 and g > 60 and g > b:  # green iris (66,97,37)
            return "Y"
        v = (r + g + b) / 3
        if v > 200:
            return "W"   # eye whites (242)
        if v > 60:
            return "S"   # gray shading (81)
        if v > 28:
            return "R"   # body charcoal (40)
        return "D"       # outline black (16)

    grid = []
    for cy in rows:
        row = []
        for cx in cols:
            # dense sample: every pixel in the cell
            cell_samples = []
            green_hits = 0
            for y in range(max(0, cy - P // 2), min(h, cy + P // 2 + 1)):
                for x in range(max(0, cx - P // 2), min(w, cx + P // 2 + 1)):
                    c = px[x, y]
                    if g_ok(c):
                        green_hits += 1
                    cell_samples.append(c)
            cell_samples.sort(key=lambda c: sum(c))
            cell = classify(cell_samples[len(cell_samples) // 2])
            # green exists only in the irises: a few hits claim the cell
            if green_hits >= 3:
                cell = "Y"
            row.append(cell)
        grid.append(row)

    def neighbors(x, y):
        return [grid[y + dy][x + dx]
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))
                if 0 <= x + dx < len(grid[0]) and 0 <= y + dy < len(grid)]

    # despeckle: drop cells with <=1 art neighbor (protect the green iris)
    for _ in range(3):
        removals = [(x, y)
                    for y in range(len(grid))
                    for x in range(len(grid[0]))
                    if grid[y][x] not in (".", "Y")
                    and sum(1 for n in neighbors(x, y) if n != ".") <= 1]
        for x, y in removals:
            grid[y][x] = "."
    # hole fill
    for y in range(len(grid)):
        for x in range(len(grid[0])):
            if grid[y][x] == ".":
                ns = neighbors(x, y)
                if len(ns) == 4 and all(n != "." for n in ns):
                    grid[y][x] = [n for n in ns if n != "."][0]
    # keep only the largest connected component (drops floating edge fragments)
    gh, gw = len(grid), len(grid[0])
    seen = [[False] * gw for _ in range(gh)]
    comps = []
    for sy in range(gh):
        for sx in range(gw):
            if grid[sy][sx] != "." and not seen[sy][sx]:
                comp = []
                dq = deque([(sx, sy)])
                seen[sy][sx] = True
                while dq:
                    x, y = dq.popleft()
                    comp.append((x, y))
                    for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (-1, -1), (1, -1), (-1, 1)):
                        nx, ny = x + dx, y + dy
                        if 0 <= nx < gw and 0 <= ny < gh and not seen[ny][nx] and grid[ny][nx] != ".":
                            seen[ny][nx] = True
                            dq.append((nx, ny))
                comps.append(comp)
    if comps:
        biggest = max(comps, key=len)
        keep = set(biggest)
        for comp in comps:
            if comp is not biggest:
                for x, y in comp:
                    if (x, y) not in keep:
                        grid[y][x] = "."
    # trim
    while grid and all(c == "." for c in grid[0]):
        grid.pop(0)
    while grid and all(c == "." for c in grid[-1]):
        grid.pop()
    if grid:
        while all(r[0] == "." for r in grid):
            [r.pop(0) for r in grid]
        while all(r[-1] == "." for r in grid):
            [r.pop() for r in grid]
    return grid


_DRAGON_ART = None


def dragon(frame):
    """Traced from assets/mascot/dragon.jpg in its own colors."""
    global _DRAGON_ART
    if _DRAGON_ART is None:
        _DRAGON_ART = trace_dragon()
    g = Grid()
    dy = 1 if frame == 1 else 0
    stamp(g, _DRAGON_ART, bottom=55 + dy)
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


# ---------------------------------------------------------------- tracer
def trace_image(path, classify, target_w=26, bg_pred=None):
    """Trace a chunky pixel-art JPG into palette chars.

    1) flood-fill background from the borders (bg_pred decides what spreads)
    2) crop to the art bounding box
    3) mode-sample each cell of a target_w-wide grid
    4) classify each cell color to a palette character
    """
    from PIL import Image
    from collections import Counter
    img = Image.open(path).convert("RGB")
    w, h = img.size
    px = img.load()
    if bg_pred is None:
        bg_pred = lambda c: all(v > 235 for v in c)
    # flood fill from borders
    from collections import deque
    bg = [[False] * w for _ in range(h)]
    q = deque()
    for x in range(w):
        for y in (0, h - 1):
            if not bg[y][x] and bg_pred(px[x, y]):
                bg[y][x] = True
                q.append((x, y))
    for y in range(h):
        for x in (0, w - 1):
            if not bg[y][x] and bg_pred(px[x, y]):
                bg[y][x] = True
                q.append((x, y))
    while q:
        x, y = q.popleft()
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            nx, ny = x + dx, y + dy
            if 0 <= nx < w and 0 <= ny < h and not bg[ny][nx] and bg_pred(px[nx, ny]):
                bg[ny][nx] = True
                q.append((nx, ny))
    # bbox of art
    xs = [x for x in range(w) for y in range(h) if not bg[y][x]]
    ys = [y for y in range(h) for x in range(w) if not bg[y][x]]
    x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
    bw, bh = x1 - x0 + 1, y1 - y0 + 1
    cell = bw / target_w
    target_h = max(1, round(bh / cell))
    rows = []
    for gy in range(target_h):
        row = []
        for gx in range(target_w):
            cx0 = x0 + int(gx * cell)
            cx1 = min(x0 + int((gx + 1) * cell) + 1, x1 + 1)
            cy0 = y0 + int(gy * cell)
            cy1 = min(y0 + int((gy + 1) * cell) + 1, y1 + 1)
            cnt = Counter()
            for y in range(cy0, cy1):
                for x in range(cx0, cx1):
                    if not bg[y][x]:
                        cnt[px[x, y]] += 1
            if not cnt:
                row.append(".")
            else:
                row.append(classify(cnt.most_common(1)[0][0]))
        rows.append(row)
    # trim empty rows top/bottom
    while rows and all(c == "." for c in rows[0]):
        rows.pop(0)
    while rows and all(c == "." for c in rows[-1]):
        rows.pop()
    return rows


def stamp(g, rows, bottom=55, cx=31):
    for gy, row in enumerate(rows):
        y = bottom - len(rows) + 1 + gy
        for gx, c in enumerate(row):
            if c != ".":
                g.set(cx - len(row) // 2 + gx, y, c)


FOX_MAP = None  # classifier defined below


def fox_classify(c):
    r, gr, b = c
    if max(r, gr, b) < 75:
        return "D"
    if r > 140 and r > gr + 30:  # orange family
        return "o" if (r + gr + b) < 330 else "O"
    if r > 200 and gr > 200 and b > 200:
        return "W"
    return "O"


def cat_classify(c):
    r, gr, b = c
    v = (r + gr + b) / 3
    if r > 200 and 140 < gr < 225 and 140 < b < 225 and r - gr > 40:
        return "P"   # blush / inner ear pink (254,200,200)
    if v < 35:
        return "D"   # black outline
    if v < 87:
        return "S"   # shadow gray (75)
    if v < 125:
        return "G"   # body gray (99)
    if v < 170:
        return "H"   # light gray (144-165)
    return "C"       # whites / cream


# ---------------------------------------------------------------- fox
def trace_fox1(frame_dy=0):
    """Trace fox1.jpg via its own graph paper: 24px pitch, lines at x~=5 (mod 24).
    Paper cells flood away as transparent; the fox's enclosed white stays."""
    from PIL import Image
    img = Image.open("assets/mascot/fox1.jpg").convert("RGB")
    w, h = img.size
    px = img.load()
    P = 24
    ox, oy = 17, 17  # cell centers (lines at 5 mod 24)
    cols = list(range(ox, w - P // 2, P))
    rows = list(range(oy, h - P // 2, P))

    def classify(c):
        r, g, b = c
        if max(r, g, b) < 80:
            return "D"
        if r > 140 and r > g + 40:
            return "o" if (r + g + b) < 400 else "O"
        return "W"  # paper or fox-white (resolved by flood below)

    grid = []
    for cy in rows:
        row = []
        for cx in cols:
            samples = []
            for ddy in (-4, 0, 4):
                for ddx in (-4, 0, 4):
                    x, y = cx + ddx, cy + ddy
                    if 0 <= x < w and 0 <= y < h:
                        samples.append(px[x, y])
            samples.sort(key=lambda c: sum(c))
            med = samples[len(samples) // 2]
            row.append(classify(med))
        grid.append(row)

    # flood from grid borders through W cells (paper + attached white) -> "."
    from collections import deque
    gh, gw = len(grid), len(grid[0])
    q = deque()
    for x in range(gw):
        for y in (0, gh - 1):
            if grid[y][x] == "W":
                grid[y][x] = "."
                q.append((x, y))
    for y in range(gh):
        for x in (0, gw - 1):
            if grid[y][x] == "W":
                grid[y][x] = "."
                q.append((x, y))
    while q:
        x, y = q.popleft()
        for dx, dy2 in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            nx, ny = x + dx, y + dy2
            if 0 <= nx < gw and 0 <= ny < gh and grid[ny][nx] == "W":
                grid[ny][nx] = "."
                q.append((nx, ny))
    # trim empty rows/cols
    while grid and all(c == "." for c in grid[0]):
        grid.pop(0)
    while grid and all(c == "." for c in grid[-1]):
        grid.pop()
    if any(grid):
        while all(r[0] == "." for r in grid):
            [r.pop(0) for r in grid]
        while all(r[-1] == "." for r in grid):
            [r.pop() for r in grid]
    return grid


def fox(frame):
    """Traced from assets/mascot/fox1.jpg via its graph-paper grid.
    Frame 1 wags the tail (right-side columns pivot 1px right/down)."""
    g = Grid()
    art = [row[:] for row in trace_fox1()]
    if frame == 1 and art:
        # hinge pivot: rotate the tail ~10 deg around a hinge point that is
        # 2px left and 2px down from the region corner (where tail meets body)
        import math
        cut = max(0, len(art[0]) - 10)
        hinge_x = cut
        hinge_y = int(len(art) * 0.72) + 2
        theta = math.radians(-10)
        cos_t, sin_t = math.cos(theta), math.sin(theta)
        tail_cells = {}
        for y in range(len(art)):
            for x in range(cut, len(art[0])):
                c = art[y][x]
                if c != "." and y < hinge_y:   # only cells above the hinge swing
                    tail_cells[(x, y)] = c
                    art[y][x] = "."
        for (x, y), c in tail_cells.items():
            dx, dyy = x - hinge_x, y - hinge_y
            nx = hinge_x + (dx * cos_t - dyy * sin_t)
            ny = hinge_y + (dx * sin_t + dyy * cos_t)
            g_x, g_y = int(round(nx)), int(round(ny))
            if 0 <= g_x < len(art[0]) and 0 <= g_y < len(art):
                art[g_y][g_x] = c
        # fill rotation-rounding holes: empty cells with 3+ tail neighbors
        for y in range(len(art)):
            for x in range(cut, len(art[0])):
                if art[y][x] == "." and y < hinge_y:
                    ns = [art[y + d2y][x + d2x]
                          for d2x, d2y in ((1, 0), (-1, 0), (0, 1), (0, -1))
                          if 0 <= x + d2x < len(art[0]) and 0 <= y + d2y < len(art)]
                    solid = [n for n in ns if n != "."]
                    if len(solid) >= 3:
                        art[y][x] = solid[0]
    stamp(g, art, bottom=55)
    return g


FOX_ART = None


# ---------------------------------------------------------------- cat
def detect_pitch(img, px, bg_pred, bbox=None):
    """Median ART-pixel size: run lengths of non-background runs only."""
    from itertools import groupby
    import statistics
    w, h = img.size
    x0, x1, y0, y1 = bbox or (0, w - 1, 0, h - 1)
    runs = []
    for y in range(y0, y1 + 1, 3):
        current = 0
        for x in range(x0, x1 + 1):
            if not bg_pred(px[x, y]):
                current += 1
            else:
                if 3 <= current <= 60:
                    runs.append(current)
                current = 0
        if 3 <= current <= 60:
            runs.append(current)
    if not runs:
        return max(4, (x1 - x0 + 1) // 12)
    return max(4, int(statistics.median(runs)))


def trace_cat1():
    """Per-cell average trace of assets/mascot/cat1.jpg at 26 cells wide."""
    from PIL import Image
    from collections import deque
    img = Image.open("assets/mascot/cat1.jpg").convert("RGB")
    w, h = img.size
    px = img.load()
    bg_pred = lambda c: all(v > 235 for v in c)
    bg = [[False] * w for _ in range(h)]
    q = deque()
    for x in range(w):
        for y in (0, h - 1):
            if bg_pred(px[x, y]):
                bg[y][x] = True; q.append((x, y))
    for y in range(h):
        for x in (0, w - 1):
            if bg_pred(px[x, y]):
                bg[y][x] = True; q.append((x, y))
    while q:
        x, y = q.popleft()
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            nx, ny = x + dx, y + dy
            if 0 <= nx < w and 0 <= ny < h and not bg[ny][nx] and bg_pred(px[nx, ny]):
                bg[ny][nx] = True; q.append((nx, ny))
    xs = [x for x in range(w) for y in range(h) if not bg[y][x]]
    ys = [y for y in range(h) for x in range(w) if not bg[y][x]]
    x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
    tw = 26
    cell = (x1 - x0 + 1) / tw
    th = max(1, round((y1 - y0 + 1) / cell))
    grid = []
    for gy in range(th):
        row = []
        for gx in range(tw):
            cx0, cx1 = x0 + int(gx * cell), min(x0 + int((gx + 1) * cell) + 1, x1 + 1)
            cy0, cy1 = y0 + int(gy * cell), min(y0 + int((gy + 1) * cell) + 1, y1 + 1)
            rs = gs = bs = n = 0
            for y in range(cy0, cy1):
                for x in range(cx0, cx1):
                    if not bg[y][x]:
                        rs += px[x, y][0]; gs += px[x, y][1]; bs += px[x, y][2]; n += 1
            if n == 0:
                row.append(".")
            else:
                row.append(cat_classify((rs // n, gs // n, bs // n)))
        grid.append(row)
    while grid and all(c == "." for c in grid[0]):
        grid.pop(0)
    while grid and all(c == "." for c in grid[-1]):
        grid.pop()
    if grid:
        while all(r[0] == "." for r in grid):
            [r.pop(0) for r in grid]
        while all(r[-1] == "." for r in grid):
            [r.pop() for r in grid]
    return grid


_CAT_ART = None


def cat(frame):
    """Pitch-snapped trace of assets/mascot/cat1.jpg."""
    global _CAT_ART
    if _CAT_ART is None:
        _CAT_ART = trace_cat1()
    g = Grid()
    stamp(g, _CAT_ART, bottom=55 + (1 if frame == 1 else 0))
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
        "dragon": {"D": (16,16,16), "R": (40,41,46), "S": (81,82,86), "H": (98,100,106), "O": (249,115,22), "Y": (94,140,46), "W": (242,242,242), "P": (16,16,16)},
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

"""Textures for Lattice's 5-second rule widget (Modules/FiveSecondWidget.lua), drawn from scratch.

    python -P tools/fivesecond_art.py

Writes Media/FiveSecond/*.tga (32-bit, uncompressed, top-left origin, power-of-two) and Media/fivesecond-preview.png
(idle, filling at 40%, burning, burning without lightning), composited the way the client blends them.

Everything tintable is white with the shape in the alpha channel: the widget colours it with SetVertexColor /
SetSwipeColor. The track (dark ring) is the only coloured one.
"""
import math
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Media", "FiveSecond")
PREVIEW = os.path.join(ROOT, "Media", "fivesecond-preview.png")

# Ring geometry in the 256 px ring textures (the widget shows them at its size, 64 px by default).
N = 256
RC = 92.0          # centre line radius
W = 16.0           # half thickness (outer 108, inner 76)
GAP = 36.0         # visible gap at the top, degrees
CAP = math.degrees(math.asin(W / RC))
END = GAP / 2 + CAP  # arc end points, degrees from the top (round caps reach GAP/2)

# Glow, arcs: shown at twice the widget size, so the ring sits at half these radii.
G = 256
GRC, GW = RC / 2, W / 2

RNG = np.random.default_rng(16001)


# ----------------------------------------------------------------------------------------------------------------
# helpers
# ----------------------------------------------------------------------------------------------------------------
def grid(n, m=None):
    m = m or n
    y, x = np.mgrid[0:m, 0:n].astype(np.float64)
    return x + 0.5, y + 0.5


def theta_of(dx, dy):
    """Degrees clockwise from the top (screen y grows downwards)."""
    return np.degrees(np.arctan2(dx, -dy)) % 360.0


def arc_sdf(n, rc, w, end):
    """Signed distance to a ring arc with round caps and a gap centred at the top."""
    x, y = grid(n)
    c = n / 2
    dx, dy = x - c, y - c
    r = np.hypot(dx, dy)
    th = theta_of(dx, dy)
    inside = (th >= end) & (th <= 360 - end)
    # outside the arc span: nearest cap centre
    dcap = np.minimum(*(np.hypot(x - (c + rc * math.sin(math.radians(a))), y - (c - rc * math.cos(math.radians(a))))
                        for a in (end, 360 - end)))
    d = np.where(inside, np.abs(r - rc), dcap)
    return d - w, (r - rc) / max(w, 1e-6), th


def cov(sdf):
    """Anti-aliased coverage from a signed distance in pixels."""
    return np.clip(0.5 - sdf, 0.0, 1.0)


def blur(a, sigma):
    from scipy.ndimage import gaussian_filter
    return gaussian_filter(a, sigma, mode="constant")


def white(alpha):
    a = np.clip(alpha, 0, 1)
    rgba = np.ones(a.shape + (4,))
    rgba[..., 3] = a
    return rgba


def save_tga(path, rgba):
    """32-bit uncompressed TGA, top-left origin (same layout as Media/Bar.tga)."""
    h, w = rgba.shape[:2]
    assert w & (w - 1) == 0 and h & (h - 1) == 0, "power of two"
    px = (np.clip(rgba, 0, 1) * 255 + 0.5).astype(np.uint8)
    bgra = px[..., [2, 1, 0, 3]]
    header = bytes([0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, w & 255, w >> 8, h & 255, h >> 8, 32, 0x28])
    with open(path, "wb") as f:
        f.write(header)
        f.write(bgra.tobytes())


# ----------------------------------------------------------------------------------------------------------------
# lightning
# ----------------------------------------------------------------------------------------------------------------
def jag(points, levels, amount):
    """Midpoint displacement: each pass splits every segment and pushes the middle sideways."""
    pts = [np.array(p, dtype=float) for p in points]
    for _ in range(levels):
        out = [pts[0]]
        for a, b in zip(pts, pts[1:]):
            m = (a + b) / 2
            d = b - a
            ln = np.hypot(*d) or 1.0
            nrm = np.array([-d[1], d[0]]) / ln
            out += [m + nrm * RNG.uniform(-1, 1) * amount * ln, b]
        pts = out
        amount *= 0.55
    return np.array(pts)


def seg_dist(x, y, pts):
    d = np.full(x.shape, np.inf)
    for a, b in zip(pts, pts[1:]):
        ab = b - a
        l2 = ab @ ab or 1e-9
        t = np.clip(((x - a[0]) * ab[0] + (y - a[1]) * ab[1]) / l2, 0, 1)
        d = np.minimum(d, np.hypot(x - (a[0] + t * ab[0]), y - (a[1] + t * ab[1])))
    return d


def bolt_layers(shape, strands, core_w, glow_s):
    """strands: list of (points, weight). Returns (glow alpha, core alpha)."""
    x, y = grid(shape[1], shape[0])
    glow = np.zeros(shape)
    core = np.zeros(shape)
    for pts, wt in strands:
        d = seg_dist(x, y, pts)
        core = np.maximum(core, np.clip(core_w * wt + 0.5 - d, 0, 1) * min(1.0, 0.55 + wt))
        glow = np.maximum(glow, wt * (0.85 * np.exp(-(d / glow_s) ** 2) + 0.35 * np.exp(-(d / (glow_s * 2.8)) ** 2)))
    return glow, core


def ring_arc_bolt(n, rc, start, span):
    """A crackle that follows the ring with branches poking out, in an n px cell centred on the ring."""
    c = n / 2
    k = 9
    pts = []
    for i in range(k + 1):
        a = math.radians(start + span * i / k + RNG.uniform(-3, 3))
        r = rc + RNG.uniform(-5, 7) * (0.4 if i in (0, k) else 1)
        pts.append((c + r * math.sin(a), c - r * math.cos(a)))
    main = jag(pts, 3, 0.22)
    strands = [(main, 1.0)]
    for _ in range(RNG.integers(2, 4)):
        p = main[RNG.integers(len(main) // 5, len(main) * 4 // 5)]
        out = np.array([p[0] - c, p[1] - c])
        out /= np.hypot(*out)
        ang = math.atan2(out[1], out[0]) + RNG.uniform(-0.7, 0.7)
        ln = RNG.uniform(10, 24)
        tip = p + np.array([math.cos(ang), math.sin(ang)]) * ln
        strands.append((jag([p, tip], 3, 0.25), 0.55))
    return strands


def wisp_bolt(cw, ch):
    """A short tongue of lightning rising from the bottom middle, flickering sideways, forking near the top."""
    x0 = cw / 2
    k = 6
    top = ch * RNG.uniform(0.38, 0.5)
    bottom = ch - 26
    pts = [(x0 + RNG.uniform(-3, 3), bottom)]
    for i in range(1, k + 1):
        t = i / k
        pts.append((x0 + RNG.uniform(-1, 1) * cw * 0.16 * (0.4 + t), bottom - t * (bottom - top)))
    main = jag(pts, 3, 0.2)
    cut = len(main) * 3 // 5
    strands = [(main[: cut + 1], 1.0), (main[cut:], 0.6)]
    for _ in range(RNG.integers(2, 4)):
        i = RNG.integers(len(main) // 3, len(main) - 2)
        p = main[i]
        side = RNG.choice([-1, 1])
        tip = p + np.array([side * RNG.uniform(8, 20), -RNG.uniform(10, 26)])
        strands.append((jag([p, tip], 2, 0.3), 0.45))
    return strands


# ----------------------------------------------------------------------------------------------------------------
# textures
# ----------------------------------------------------------------------------------------------------------------
def make_track():
    sdf, rel, _ = arc_sdf(N, RC, W, END)
    body = cov(sdf)
    rgba = np.zeros((N, N, 4))
    # slate body, a touch darker towards the inside, with a cool rim on both edges
    shade = 0.85 + 0.15 * (rel + 1) / 2
    base = np.array([13, 17, 25]) / 255
    rim = np.array([78, 102, 138]) / 255
    rim_a = np.exp(-((sdf + 1.6) / 1.1) ** 2) * body
    col = base[None, None, :] * shade[..., None]
    col = col * (1 - rim_a[..., None]) + rim[None, None, :] * rim_a[..., None]
    # soft dark shadow outside so it reads on light ground
    shadow = np.clip(1 - sdf / 6, 0, 1) * (sdf > 0) * 0.45
    a = np.maximum(body * 0.9, shadow)
    rgba[..., :3] = np.where(body[..., None] > 0, col, 0)
    rgba[..., 3] = a
    return rgba


def make_fill():
    sdf, rel, _ = arc_sdf(N, RC, W - 3.5, END)
    a = cov(sdf)
    t = np.clip(np.abs((sdf + (W - 3.5)) / (W - 3.5)), 0, 1)  # 0 centre line .. 1 edge
    v = 0.70 + 0.30 * (1 - t ** 2)
    rgba = np.ones((N, N, 4))
    rgba[..., :3] = v[..., None]
    rgba[..., 3] = a
    return rgba


def make_core():
    sdf, _, _ = arc_sdf(N, RC, 0.0, END)
    d = sdf  # distance to the centre line
    a = 0.95 * np.exp(-(d / 3.2) ** 2) + 0.35 * np.exp(-(d / 8.0) ** 2)
    return white(a)


def make_glow():
    sdf, _, _ = arc_sdf(G, GRC, GW, END)
    ring = cov(sdf)
    halo = 0.9 * blur(ring, 4.5) / max(blur(ring, 4.5).max(), 1e-6) + 0.45 * blur(ring, 15) / max(blur(ring, 15).max(), 1e-6)
    # a soft plume rising out of the gap, like a flame
    x, y = grid(G)
    c = G / 2
    py = c - GRC - 10
    plume = np.exp(-(((x - c) / 9.0) ** 2 + ((y - py) / 22.0) ** 2)) * np.clip((c - GRC + 6 - y) / 12, 0, 1)
    a = np.clip(halo * 0.75 + plume * 0.55, 0, 1)
    # fade out well before the edge (no square corners)
    r = np.hypot(x - c, y - c)
    a *= np.clip((G / 2 - 2 - r) / 18, 0, 1)
    return white(a)


def make_arcs():
    """2x2 sheet of 256 px cells; each a crackle on the ring at a different spot."""
    glow = np.zeros((512, 512))
    core = np.zeros((512, 512))
    starts = [(40, 95), (150, 80), (230, 100), (300, 70)]
    for i, (s, span) in enumerate(starts):
        g, k = bolt_layers((256, 256), ring_arc_bolt(256, GRC, s, span), 1.1, 3.2)
        cy, cx = divmod(i, 2)
        # keep a clear border so neighbours never bleed with filtering
        x, y = grid(256)
        fade = np.clip((128 - 4 - np.hypot(x - 128, y - 128)) / 10, 0, 1)
        glow[cy * 256:(cy + 1) * 256, cx * 256:(cx + 1) * 256] = g * fade
        core[cy * 256:(cy + 1) * 256, cx * 256:(cx + 1) * 256] = k * fade
    return white(glow), white(core)


def make_wisps():
    """4 cells of 128x256 side by side: strands rising from the gap."""
    glow = np.zeros((256, 512))
    core = np.zeros((256, 512))
    for i in range(4):
        g, k = bolt_layers((256, 128), wisp_bolt(128, 256), 2.2, 6.0)
        x, y = grid(128, 256)
        fade = np.clip((x - 3) / 14, 0, 1) * np.clip((125 - x) / 14, 0, 1) * np.clip((y - 3) / 24, 0, 1)
        # soft base (it starts inside the ring's glow), fades as it rises
        fade *= np.clip((252 - y) / 22, 0, 1) * (0.3 + 0.7 * (y / 256))
        glow[:, i * 128:(i + 1) * 128] = g * fade
        core[:, i * 128:(i + 1) * 128] = k * fade
    return white(glow), white(core)


# ----------------------------------------------------------------------------------------------------------------
# preview: blend like the client does (BLEND for track/fill, ADD for glow, core and lightning)
# ----------------------------------------------------------------------------------------------------------------
FILL = np.array([0x4f, 0xb4, 0xff]) / 255
BURN = np.array([0x4f, 0xb4, 0xff]) / 255


def resized(rgba, w, h):
    img = Image.fromarray((np.clip(rgba, 0, 1) * 255 + 0.5).astype(np.uint8), "RGBA")
    # premultiply for clean filtering
    arr = np.asarray(img).astype(np.float64) / 255
    pm = arr.copy()
    pm[..., :3] *= pm[..., 3:4]
    out = []
    for ch in range(4):
        im = Image.fromarray((pm[..., ch] * 255).astype(np.uint8), "L").resize((w, h), Image.LANCZOS)
        out.append(np.asarray(im).astype(np.float64) / 255)
    res = np.stack(out, -1)
    a = res[..., 3:4]
    res[..., :3] = np.where(a > 1e-4, res[..., :3] / np.maximum(a, 1e-4), 0)
    return np.clip(res, 0, 1)


def place(canvas, layer, cx, cy, tint=(1, 1, 1), alpha=1.0, mode="blend", rot=0.0):
    h, w = layer.shape[:2]
    if rot:
        img = Image.fromarray((layer * 255 + 0.5).astype(np.uint8), "RGBA").rotate(-rot, resample=Image.BICUBIC)
        layer = np.asarray(img).astype(np.float64) / 255
    x0, y0 = int(round(cx - w / 2)), int(round(cy - h / 2))
    H, Wd = canvas.shape[:2]
    sx0, sy0 = max(0, -x0), max(0, -y0)
    ex, ey = min(w, Wd - x0), min(h, H - y0)
    if ex <= sx0 or ey <= sy0:
        return
    src = layer[sy0:ey, sx0:ex]
    dst = canvas[y0 + sy0:y0 + ey, x0 + sx0:x0 + ex]
    col = src[..., :3] * np.array(tint)[None, None, :]
    a = src[..., 3:4] * alpha
    if mode == "add":
        dst[...] = np.clip(dst + col * a, 0, 1)
    else:
        dst[...] = dst * (1 - a) + col * a


def swipe(rgba, frac):
    """Keep the part of the fill a reverse (clockwise filling) cooldown shows at frac of the 5 s."""
    h, w = rgba.shape[:2]
    x, y = grid(w, h)
    th = theta_of(x - w / 2, y - h / 2)
    sweep = GAP / 2 + (360 - GAP) * frac
    out = rgba.copy()
    out[..., 3] *= (th <= sweep)
    return out


def cell(sheet, col, row, cw, ch):
    return sheet[row * ch:(row + 1) * ch, col * cw:(col + 1) * cw]


def preview(tex):
    S = 150
    PW, PH = 380, 440
    labels = ["Idle (full mana)", "Filling: 2 of 5 s", "Burning: mana coming back", "Burning, calm mode"]
    img = np.zeros((PH, PW * 4, 3))
    yy = np.linspace(0, 1, PH)[:, None, None]
    img[...] = (np.array([27, 33, 44]) / 255) * (1 - yy) + (np.array([10, 12, 17]) / 255) * yy
    img += RNG.normal(0, 0.006, img.shape)

    track = resized(tex["track"], S, S)
    fill = resized(tex["fill"], S, S)
    core = resized(tex["core"], S, S)
    glow = resized(tex["glow"], 2 * S, 2 * S)
    arcs_g = [resized(cell(tex["arcs_glow"], i % 2, i // 2, 256, 256), 2 * S, 2 * S) for i in range(4)]
    arcs_c = [resized(cell(tex["arcs_core"], i % 2, i // 2, 256, 256), 2 * S, 2 * S) for i in range(4)]
    wisp_g = [resized(cell(tex["wisps_glow"], i, 0, 128, 256), S // 2, S) for i in range(4)]
    wisp_c = [resized(cell(tex["wisps_core"], i, 0, 128, 256), S // 2, S) for i in range(4)]

    for p in range(4):
        cx, cy = PW * p + PW / 2, 250
        panel = img
        place(panel, track, cx, cy)
        if p == 0:
            place(panel, fill, cx, cy, FILL, 0.22)
        elif p == 1:
            place(panel, swipe(fill, 0.4), cx, cy, FILL, 1.0)
        else:
            place(panel, glow, cx, cy, BURN, 0.95, "add")
            place(panel, fill, cx, cy, BURN, 1.0)
            place(panel, core, cx, cy, (1, 1, 1), 0.75, "add")
            place(panel, core, cx, cy, BURN, 0.5, "add")
            if p == 2:
                for i, rot in ((0, 0), (2, 25)):
                    place(panel, arcs_g[i], cx, cy, BURN, 0.95, "add", rot)
                    place(panel, arcs_c[i], cx, cy, (0.85, 0.95, 1), 1.0, "add", rot)
                top = cy - S * (18 / 64)
                for i, rise, a, dx in ((0, 0.10, 1.0, 0), (1, 0.32, 0.65, -0.06), (3, 0.05, 0.5, 0.07)):
                    wy = top - S / 2 + 0.08 * S - rise * S
                    place(panel, wisp_g[i], cx + dx * S, wy, BURN, a, "add")
                    place(panel, wisp_c[i], cx + dx * S, wy, (0.85, 0.95, 1), a, "add")
    out = Image.fromarray((np.clip(img, 0, 1) * 255 + 0.5).astype(np.uint8), "RGB")
    d = ImageDraw.Draw(out)
    try:
        font = ImageFont.truetype("C:/Windows/Fonts/segoeui.ttf", 20)
        small = ImageFont.truetype("C:/Windows/Fonts/segoeui.ttf", 15)
    except OSError:
        font = small = ImageFont.load_default()
    for p, text in enumerate(labels):
        w = d.textlength(text, font=font)
        d.text((PW * p + (PW - w) / 2, PH - 52), text, fill=(220, 228, 240), font=font)
    sub = "Lattice: 5-second rule widget (shown at 150 px; default size in game is 64 px)"
    d.text((16, 12), sub, fill=(140, 152, 170), font=small)
    d.text((PW + PW / 2 - 7, 250 - 14), "3", fill=(235, 242, 255), font=font)
    out.save(PREVIEW)


def main():
    os.makedirs(OUT, exist_ok=True)
    tex = {
        "track": make_track(),
        "fill": make_fill(),
        "core": make_core(),
        "glow": make_glow(),
    }
    tex["arcs_glow"], tex["arcs_core"] = make_arcs()
    tex["wisps_glow"], tex["wisps_core"] = make_wisps()
    for name, rgba in tex.items():
        save_tga(os.path.join(OUT, name + ".tga"), rgba)
    preview(tex)
    print("wrote", OUT, "and", PREVIEW, "| arc ends at", round(END, 2), "deg from the top")


if __name__ == "__main__":
    main()

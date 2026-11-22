"""Textures for Lattice's 5-second rule widget (Modules/FiveSecondWidget.lua), drawn from scratch.

    python -P tools/fivesecond_art.py

Writes Media/FiveSecond/*.tga (32-bit, uncompressed, top-left origin, power-of-two) and Media/fivesecond-preview.png
(idle, filling at 40%, burning, burning without the flame; each at 150 px and 32 px), composited the way the client blends them.

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

# Glow: shown at twice the widget size, so the ring sits at half these radii.
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
# blue fire
# ----------------------------------------------------------------------------------------------------------------
def noise(shape, scale):
    """Smooth value noise in -1..1 (a blurred random field)."""
    from scipy.ndimage import gaussian_filter
    n = gaussian_filter(RNG.normal(0, 1, shape), scale, mode="wrap")
    return n / (np.abs(n).max() or 1)


def tongue(x, y, base, direction, length, width, wobble, bend):
    """One flame tongue: a soft teardrop from `base` along `direction`, swaying more towards the tip."""
    d = np.array(direction, dtype=float)
    d /= np.hypot(*d)
    nrm = np.array([-d[1], d[0]])
    px, py = x - base[0], y - base[1]
    u = px * d[0] + py * d[1]
    v = px * nrm[0] + py * nrm[1]
    t = np.clip(u / length, 0, 1)
    v = v + wobble * t ** 1.5 + bend * length * t ** 2
    hw = width * (1 - t) ** 0.8 * (0.6 + 0.4 * np.clip(t / 0.2, 0, 1)) + 0.3
    along = np.where(u < 0, np.exp(-(u / (width * 0.7)) ** 2), np.where(u > length, 0.0, 1.0))
    body = np.exp(-(v / hw) ** 2 * 1.5) * along * (1 - t ** 3)
    ct = np.clip(u / (length * 0.5), 0, 1)
    chw = width * 0.4 * (1 - ct) ** 0.9 + 0.2
    calong = np.where(u < 0, np.exp(-(u / (width * 0.45)) ** 2), np.where(u > length * 0.5, 0.0, 1.0))
    core = np.exp(-(v / chw) ** 2 * 2.0) * calong * (1 - ct ** 2)
    return body, core


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
    x, y = grid(G)
    c = G / 2
    a = np.clip(halo * 0.75, 0, 1)
    # fade out well before the edge (no square corners)
    r = np.hypot(x - c, y - c)
    a *= np.clip((G / 2 - 2 - r) / 18, 0, 1)
    return white(a)


# The flame: one soft, rounded flame rising from low in the ring up out of the gap. Shown 0.6 x 1.2 of the widget,
# its foot FLAME_FOOT below the centre. Two cells side by side (a slightly different lean and height): the widget
# crossfades them slowly, so the flame seems to breathe and sway without anything jumping.
FLAME_W, FLAME_H, FLAME_FOOT = 0.6, 1.2, 0.3


def flame_shape(cw, ch, lean, height, belly):
    x, y = grid(cw, ch)
    base_y = ch - (FLAME_FOOT - 0.16) / FLAME_H * ch      # foot of the flame, 0.16 below the ring's centre
    tip_y = ch - (FLAME_FOOT + 0.6 * height) / FLAME_H * ch
    h = base_y - tip_y
    t = np.clip((base_y - y) / h, 0, 1)
    sway = lean * cw * t ** 2
    wb = belly * cw
    width = wb * np.sqrt(np.clip(t * 3.0, 0, 1)) * (1 - t) ** 0.6 * (1 + 0.5 * (1 - t))
    below = np.exp(-np.clip(y - base_y, 0, None) ** 2 / (2 * (wb * 0.25) ** 2))
    body = np.exp(-((x - cw / 2 - sway) / np.maximum(width, 0.6)) ** 2 * 1.3) * below * (1 - t ** 3)
    body = blur(body, 3.2)
    ct = np.clip((base_y - 6 - y) / (h * 0.55), 0, 1)
    cwid = wb * 0.5 * np.sqrt(np.clip(ct * 3, 0, 1)) * (1 - ct) ** 0.6
    core = np.exp(-((x - cw / 2 - sway * 0.6) / np.maximum(cwid, 0.6)) ** 2 * 1.5) * (y <= base_y - 2) * (1 - ct ** 3)
    core = blur(core, 3.0) * 0.8
    glow = np.clip(body * 0.8 + 0.5 * blur(body, 9), 0, 1)
    fade = np.clip((x - 2) / 14, 0, 1) * np.clip((cw - 2 - x) / 14, 0, 1) * np.clip((y - 2) / 14, 0, 1) * np.clip((ch - 2 - y) / 10, 0, 1)
    return glow * fade, np.clip(core * 0.95, 0, 1) * fade


def make_flame():
    glow = np.zeros((256, 256))
    core = np.zeros((256, 256))
    for i, (lean, height, belly) in enumerate(((-0.025, 1.0, 0.3), (0.035, 0.94, 0.31))):
        g, k = flame_shape(128, 256, lean, height, belly)
        glow[:, i * 128:(i + 1) * 128] = g
        core[:, i * 128:(i + 1) * 128] = k
    return white(glow), white(core)


def save_png(img, path):
    """Save, retrying while an image viewer holds the file; else beside it as .new.png."""
    import time
    for _ in range(10):
        try:
            img.save(path)
            return path
        except OSError:
            time.sleep(0.5)
    alt = path[:-4] + ".new.png"
    img.save(alt)
    print("in use, saved as", alt)
    return alt


# ----------------------------------------------------------------------------------------------------------------
# preview: blend like the client does (BLEND for track/fill, ADD for glow, core and flames)
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
    """Each state at 150 px, and below it at the real default size (32 px)."""
    S, SMALL = 150, 32
    PW, PH = 380, 400
    labels = ["Idle (full mana)", "Filling: 2 of 5 s", "Burning: mana coming back", "Burning, no flame"]
    img = np.zeros((PH, PW * 4, 3))
    yy = np.linspace(0, 1, PH)[:, None, None]
    img[...] = (np.array([27, 33, 44]) / 255) * (1 - yy) + (np.array([10, 12, 17]) / 255) * yy

    track = resized(tex["track"], S, S)
    fill = resized(tex["fill"], S, S)
    core = resized(tex["core"], S, S)
    glow = resized(tex["glow"], 2 * S, 2 * S)
    fw, fh = int(S * FLAME_W), int(S * FLAME_H)
    fl_g = [resized(cell(tex["flame_glow"], i, 0, 128, 256), fw, fh) for i in range(2)]
    fl_c = [resized(cell(tex["flame_core"], i, 0, 128, 256), fw, fh) for i in range(2)]

    cy = 230
    for p in range(4):
        cx = PW * p + PW / 2
        place(img, track, cx, cy)
        if p == 0:
            place(img, fill, cx, cy, FILL, 0.22)
        elif p == 1:
            place(img, swipe(fill, 0.4), cx, cy, FILL, 1.0)
        else:
            place(img, glow, cx, cy, BURN, 0.95, "add")
            place(img, fill, cx, cy, BURN, 1.0)
            place(img, core, cx, cy, (1, 1, 1), 0.75, "add")
            place(img, core, cx, cy, BURN, 0.5, "add")
            if p == 2:
                fy = cy + FLAME_FOOT * S - fh / 2  # its foot below the centre
                # the widget shows the first shape and fades the second in and out over it
                for i, a in ((0, 1.0), (1, 0.4)):
                    place(img, fl_g[i], cx, fy, BURN, 0.85 * a, "add")
                    place(img, fl_c[i], cx, fy, (0.85, 0.95, 1), 0.8 * a, "add")
    big = Image.fromarray((np.clip(img, 0, 1) * 255 + 0.5).astype(np.uint8), "RGB")
    # the real size: the same panels scaled down, centred in a strip under each
    strip_h = 90
    out = Image.new("RGB", (PW * 4, PH + strip_h + 40), (10, 12, 17))
    out.paste(big, (0, 0))
    k = SMALL / S
    for p in range(4):
        tile = big.crop((PW * p, 0, PW * (p + 1), PH)).resize((int(PW * k), int(PH * k)), Image.LANCZOS)
        out.paste(tile, (int(PW * p + PW / 2 - PW * k / 2), int(PH + 40 + strip_h / 2 - cy * k)))
    d = ImageDraw.Draw(out)
    try:
        font = ImageFont.truetype("C:/Windows/Fonts/segoeui.ttf", 20)
        small = ImageFont.truetype("C:/Windows/Fonts/segoeui.ttf", 15)
    except OSError:
        font = small = ImageFont.load_default()
    for p, text in enumerate(labels):
        w = d.textlength(text, font=font)
        d.text((PW * p + (PW - w) / 2, PH - 48), text, fill=(220, 228, 240), font=font)
    d.text((16, 12), "Lattice: 5-second rule ring at 150 px; below, the real default size (32 px)", fill=(140, 152, 170), font=small)
    d.text((16, PH + 8), "32 px", fill=(120, 130, 148), font=small)
    save_png(out, PREVIEW)


def main():
    os.makedirs(OUT, exist_ok=True)
    tex = {
        "track": make_track(),
        "fill": make_fill(),
        "core": make_core(),
        "glow": make_glow(),
    }
    tex["flame_glow"], tex["flame_core"] = make_flame()
    for name, rgba in tex.items():
        save_tga(os.path.join(OUT, name + ".tga"), rgba)
    preview(tex)
    print("wrote", OUT, "and", PREVIEW, "| arc ends at", round(END, 2), "deg from the top")


if __name__ == "__main__":
    main()

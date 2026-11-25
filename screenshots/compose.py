# Builds the CurseForge/site screenshots (1920x1080) from UISandbox renders in raw/ (render.py Lattice <scenario> --zoom 2;
# the frame previews with --bg transparent).
from PIL import Image, ImageDraw
import math
W, H = 1920, 1080
BG = Image.new("RGB", (W, H)); px = BG.load()
for y in range(H):
    for x in range(W):
        d = min(1, math.hypot((x - W / 2) / W, (y - H * 0.38) / H) * 1.6)
        px[x, y] = tuple(int(a + (b - a) * d) for a, b in zip((0x13, 0x22, 0x3F), (0x07, 0x0D, 0x1A)))

def raw(name, crop=None, key=True):
    im = Image.open(f"raw/{name}.png").convert("RGBA")
    if crop: im = im.crop(crop)
    elif not key:  # trim the sandbox's grey backdrop: keep the window (its body is near black)
        m = im.convert("L").point(lambda v: 255 if v < 30 else 0)
        b = m.getbbox()
        if b: im = im.crop((max(0, b[0] - 2), max(0, b[1] - 2), min(im.width, b[2] + 2), min(im.height, b[3] + 2)))
    if key:  # the render's empty screen is pure black: make it see-through, then trim
        d = im.get_flattened_data() if hasattr(im, 'get_flattened_data') else im.getdata()
        im.putdata([(0, 0, 0, 0) if p[0] < 3 and p[1] < 3 and p[2] < 3 else p for p in d])
        im = im.crop(im.getbbox())
    return im

def shadow(c, box, r=14):
    sh = Image.new("RGBA", c.size, (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle((box[0] + 10, box[1] + 14, box[2] + 10, box[3] + 14), r, fill=(0, 0, 0, 120))
    return Image.alpha_composite(c, sh)

def place(ims, out, gap=70, maxw=1760, maxh=980, shadows=True, up=1.0):
    tw = sum(i.width for i in ims) + gap * (len(ims) - 1); th = max(i.height for i in ims)
    s = min(up, maxw / tw, maxh / th)
    ims = [i.resize((int(i.width * s), int(i.height * s)), Image.LANCZOS) for i in ims]
    g = int(gap * s); tw = sum(i.width for i in ims) + g * (len(ims) - 1)
    c = BG.convert("RGBA"); x = (W - tw) // 2
    for i in ims:
        y = (H - i.height) // 2
        if shadows: c = shadow(c, (x, y, x + i.width, y + i.height))
        c.paste(i, (x, y), i); x += i.width + g
    c.convert("RGB").save(out)

# 1: the frames: a 20-player raid preview, and the party with the 5-second rule and the 5Sr bar
place([raw("preview-raid"), raw("fivesecond")], "1-raid-and-party.png", gap=90, up=1.3, shadows=False)
place([raw("options", key=False)], "2-settings.png")
place([raw("page-aurafilters", key=False)], "3-aura-filters.png")
place([raw("page-clickcast", key=False)], "4-click-casting.png")
place([raw("hovercast", key=False)], "5-hover-casting.png")
place([raw("unlock", key=False)], "6-unlock-and-drag.png")
place([raw("page-profiles", key=False)], "7-profiles.png")
place([raw("search", key=False)], "8-settings-search.png")
place([raw("ai-help", key=False)], "9-ai-help.png")

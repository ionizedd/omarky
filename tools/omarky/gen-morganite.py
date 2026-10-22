#!/usr/bin/env python3
"""Generate the Morganite theme (themes/morganite/): colors.toml, wallpapers, the boot-unlock logo and previews.
Everything is drawn here from the palette below, so there is no third-party art to license. Re-run after editing PALETTE; commit the outputs."""
import math, os, random, sys
from PIL import Image, ImageDraw, ImageFilter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import importlib
gb = importlib.import_module('gen-branding')   # reuse the wordmark pixels and the cell MARK

R = gb.R
T = f'{R}/themes/morganite'

# Matte black dress, a morganite-pink streak, white lace, a green glint.
PALETTE = {
  'accent': '#f08fbd', 'selection': '#3d2535', 'muted': '#4d3f49',
  'background': '#0f0c10', 'dark_background': '#0b090c', 'darker_background': '#070608', 'lighter_background': '#1c171e',
  'foreground': '#ede5eb', 'dark_foreground': '#76666f', 'light_foreground': '#bcacb6', 'bright_foreground': '#fdf8fb',
  'red': '#ec6f8e', 'yellow': '#f3c79a', 'orange': '#f2a689', 'green': '#78d6a0',
  'cyan': '#9ad8d2', 'blue': '#f08fbd', 'magenta': '#d68ee8', 'brown': '#6e3c52',
  'bright_red': '#ff8fab', 'bright_yellow': '#ffdcb5', 'bright_green': '#9eebbd',
  'bright_cyan': '#bdeee9', 'bright_blue': '#ffb3d6', 'bright_magenta': '#eab0f6',
}
ORDER = ['accent', 'selection', 'muted', None, 'background', 'dark_background', 'darker_background', 'lighter_background', None,
         'foreground', 'dark_foreground', 'light_foreground', 'bright_foreground', None,
         'red', 'yellow', 'orange', 'green', 'cyan', 'blue', 'magenta', 'brown', None,
         'bright_red', 'bright_yellow', 'bright_green', 'bright_cyan', 'bright_blue', 'bright_magenta']

def rgb(h, a=255): h = h.lstrip('#'); return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16), a)
BG, PINK, LACE, GLINT = rgb(PALETTE['background']), rgb(PALETTE['accent']), rgb(PALETTE['foreground']), rgb(PALETTE['green'])
W, H = 3840, 2160

def colors_toml():
    out = ['mode = "dark"', '']
    for k in ORDER:
        out.append('' if k is None else f'{k} = "{PALETTE[k]}"')
    open(f'{T}/colors.toml', 'w').write('\n'.join(out) + '\n')

def vignette(im, strength=0.55):
    """Darken the edges so the centre breathes: a smooth falloff computed per pixel (no gradient-image banding)."""
    w, h = W // 8, H // 8
    m = Image.new('L', (w, h)); px = m.load()
    for y in range(h):
        for x in range(w):
            d = math.hypot((x - w / 2) / (w / 2), (y - h / 2) / (h / 2)) / math.sqrt(2)   # 0 centre, 1 corner
            px[x, y] = int(255 * strength * d ** 2.4)
    mask = m.resize(im.size, Image.BICUBIC)
    return Image.composite(Image.new('RGBA', im.size, rgb('#000000')), im, mask)

def glow(layer, radii=(70, 22, 6), gain=(3.0, 2.2, 1.6)):
    """Neon: the sharp line over blurred copies of itself whose alpha is boosted back up (blur alone fades to nothing)."""
    out = Image.new('RGBA', layer.size, (0, 0, 0, 0))
    for r, k in zip(radii, gain):
        b = layer.filter(ImageFilter.GaussianBlur(r)); rr, gg, bb, a = b.split()
        out = Image.alpha_composite(out, Image.merge('RGBA', (rr, gg, bb, a.point(lambda v, k=k: min(255, int(v * k))))))
    return Image.alpha_composite(out, layer)

def traces():
    """Rose neon circuit traces running in from the edges and turning at 45 degrees, ending in pads."""
    rnd = random.Random(7)
    im = Image.new('RGBA', (W, H), BG)
    layer = Image.new('RGBA', (W, H), (0, 0, 0, 0)); d = ImageDraw.Draw(layer)
    for i in range(18):
        side = i % 4
        x, y = [(0, rnd.randrange(H)), (W, rnd.randrange(H)), (rnd.randrange(W), 0), (rnd.randrange(W), H)][side]
        dx, dy = [(1, 0), (-1, 0), (0, 1), (0, -1)][side]
        pts = [(x, y)]
        for _ in range(rnd.randint(2, 4)):
            n = rnd.randint(160, 640)
            x, y = x + dx * n, y + dy * n; pts.append((x, y))
            if rnd.random() < 0.7:   # 45-degree jog, like a PCB trace
                ndx, ndy = (dx or rnd.choice((-1, 1))), (dy or rnd.choice((-1, 1)))
                n = rnd.randint(60, 220); x, y = x + ndx * n, y + ndy * n; pts.append((x, y))
        a = rnd.randint(150, 255)
        d.line(pts, fill=PINK[:3] + (a,), width=rnd.choice((4, 6, 8)), joint='curve')
        r = rnd.choice((12, 16, 22)); d.ellipse((x - r, y - r, x + r, y + r), outline=PINK[:3] + (a,), width=6)
    im = Image.alpha_composite(im, glow(layer))
    return vignette(im, 0.6)

def lace():
    """A band of white lace along the bottom: scallops, eyelets and a dotted seam, like an apron hem."""
    im = Image.new('RGBA', (W, H), BG)
    layer = Image.new('RGBA', (W, H), (0, 0, 0, 0)); d = ImageDraw.Draw(layer)
    a = 120
    base = int(H * 0.74); r = 120
    for x in range(-r, W + r, 2 * r):
        d.arc((x - r, base - r, x + r, base + r), 0, 180, fill=LACE[:3] + (a + 40,), width=8)      # scallop
        d.ellipse((x - 26, base - 4, x + 26, base + 44), outline=LACE[:3] + (a,), width=6)         # eyelet
        for k in range(3):
            cx = x + (k - 1) * 60; cy = base + r + 60
            d.ellipse((cx - 9, cy - 9, cx + 9, cy + 9), fill=LACE[:3] + (a,))
    for x in range(0, W, 40):                                                                       # seam
        d.ellipse((x - 6, base - 86, x + 6, base - 74), fill=LACE[:3] + (a - 20,))
    for row, yy in enumerate(range(base + r + 130, H, 90)):                                         # net
        for x in range((row % 2) * 45, W, 90):
            d.ellipse((x - 5, yy - 5, x + 5, yy + 5), fill=LACE[:3] + (55,))
    im = Image.alpha_composite(im, layer.filter(ImageFilter.GaussianBlur(1.2)))
    seam = Image.new('RGBA', (W, H), (0, 0, 0, 0))                                                 # one pink ribbon
    ImageDraw.Draw(seam).line([(0, base - 150), (W, base - 150)], fill=PINK[:3] + (230,), width=7)
    im = Image.alpha_composite(im, glow(seam, (40, 10)))
    return vignette(im, 0.5)

def glint():
    """Near-black with a pink haze low on the left and one small green glint, like an eye catching light."""
    im = Image.new('RGBA', (W, H), BG)
    haze = Image.new('RGBA', (W, H), (0, 0, 0, 0)); d = ImageDraw.Draw(haze)
    d.ellipse((-900, H * 0.45, W * 0.55, H + 900), fill=PINK[:3] + (80,))
    im = Image.alpha_composite(im, haze.filter(ImageFilter.GaussianBlur(320)))
    g = Image.new('RGBA', (W, H), (0, 0, 0, 0)); d = ImageDraw.Draw(g)
    cx, cy = int(W * 0.68), int(H * 0.36)
    for ang, ln in ((0, 190), (90, 190), (45, 70), (135, 70)):   # four-point sparkle
        dx, dy = math.cos(math.radians(ang)) * ln, math.sin(math.radians(ang)) * ln
        d.line([(cx - dx, cy - dy), (cx + dx, cy + dy)], fill=GLINT[:3] + (255,), width=7)
    d.ellipse((cx - 13, cy - 13, cx + 13, cy + 13), fill=(255, 255, 255, 250))
    im = Image.alpha_composite(im, glow(g, (50, 14)))
    return vignette(im, 0.45)

def logo_wall():
    """Matches the other themes' plain logo wallpaper: background colour plus the mark, centred."""
    im = Image.new('RGBA', (W, H), BG); s = 22
    ox, oy = (W - 15 * s) // 2, (H - 15 * s) // 2; d = ImageDraw.Draw(im)
    for y, row in enumerate(gb.MARK):
        for x, v in enumerate(row):
            if v == '1': d.rectangle((ox + x * s, oy + y * s, ox + x * s + s - 1, oy + y * s + s - 1), fill=PINK)
    return im

def unlock_png(path):
    """Boot/disk-unlock logo: the Omarky wordmark in the accent colour (same canvas as every theme's unlock.png)."""
    old = gb.GREEN; gb.GREEN = PINK
    try: gb.wordmark_png(path)
    finally: gb.GREEN = old

def preview_unlock(path):
    im = Image.new('RGBA', (1920, 1080), BG)
    logo = Image.open(f'{T}/unlock.png').convert('RGBA')
    im.alpha_composite(logo, ((1920 - logo.width) // 2, 440))
    d = ImageDraw.Draw(im)
    bx, by = 818, 674
    d.rectangle((bx, by, bx + 284, by + 46), fill=rgb(PALETTE['lighter_background']), outline=rgb(PALETTE['light_foreground']), width=3)
    for i in range(4): d.ellipse((bx + 18 + i * 12, by + 19, bx + 26 + i * 12, by + 27), fill=LACE)
    lx, ly = 768, 680                                                     # padlock
    d.arc((lx + 4, ly, lx + 30, ly + 30), 180, 360, fill=rgb(PALETTE['light_foreground']), width=5)
    d.rounded_rectangle((lx, ly + 14, lx + 34, ly + 38), 4, fill=rgb(PALETTE['light_foreground']))
    im.convert('RGB').save(path)

def preview(path, wall):
    """Theme-picker preview: the first wallpaper with a sketch of the bar and two windows in theme colours.
    A drawing, not a screenshot; replace it with a real one from a VM when convenient."""
    im = wall.resize((2560, 1440), Image.LANCZOS)
    d = ImageDraw.Draw(im)
    d.rectangle((0, 0, 2560, 52), fill=rgb(PALETTE['darker_background'], 235))
    for i in range(5):
        c = PINK if i == 0 else rgb(PALETTE['dark_foreground'])
        d.ellipse((40 + i * 44, 16, 60 + i * 44, 36), fill=c)
    for (x0, y0, x1, y1), active in (((60, 100, 1260, 1380), True), ((1300, 100, 2500, 1380), False)):
        d.rectangle((x0, y0, x1, y1), fill=rgb(PALETTE['background'], 238), outline=PINK if active else rgb(PALETTE['muted']), width=4)
        for k, col in enumerate(('accent', 'foreground', 'green', 'light_foreground', 'magenta', 'foreground', 'yellow')):
            y = y0 + 60 + k * 54; w = [520, 760, 400, 880, 300, 640, 480][k]
            d.rounded_rectangle((x0 + 60, y, x0 + 60 + w, y + 22), 8, fill=rgb(PALETTE[col], 210))
    im.convert('RGB').save(path, optimize=True)

if __name__ == '__main__':
    os.makedirs(f'{T}/backgrounds', exist_ok=True)
    colors_toml()
    open(f'{T}/icons.theme', 'w').write('Yaru-magenta\n')
    walls = [('01-neon-traces', traces()), ('02-lace', lace()), ('03-glint', glint()), ('04-omarky', logo_wall())]
    for name, im in walls:
        im.convert('RGB').save(f'{T}/backgrounds/{name}.webp', quality=92, method=6)
    unlock_png(f'{T}/unlock.png')
    preview_unlock(f'{T}/preview-unlock.png')
    preview(f'{T}/preview.png', walls[0][1])
    print('wrote', T)

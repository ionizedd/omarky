#!/usr/bin/env python3
"""Generate Omarky's visual assets from one canonical 15x15 cell mark and the omarchy-ascii wordmark.
Writes into the runtime repo this file lives in: plymouth+sddm logo.png, logo.svg, icon.png, icon.txt, and the U+E900 glyph of omarchy.ttf.
Run again after editing MARK; commit the outputs."""
import subprocess, os, sys
from PIL import Image
from fontTools.ttLib import TTFont
from fontTools.pens.ttGlyphPen import TTGlyphPen

R = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))  # runtime repo root
GREEN = (168, 205, 118, 255)   # matches the existing logo colour
ICON_GREEN = (158, 206, 106, 255)

# The Omarky mark: a cell. Membrane ring, off-centre nucleus, one organelle. (1 = filled)
MARK = [
 "000001111100000",
 "000111111111000",
 "001111000111100",
 "011100000001110",
 "011011100000110",
 "111011100000111",
 "110011100000011",
 "110000000000011",
 "110000000000011",
 "111000000010111",
 "011000000000110",
 "011100000001110",
 "001111000111100",
 "000111111111000",
 "000001111100000",
]

def wordmark_pixels(text='omarky'):
    out = subprocess.run([f'{R}/bin/omarchy-ascii', text], capture_output=True, text=True, check=True,
                         env={**os.environ, 'OMARCHY_PATH': R}).stdout.rstrip('\n').split('\n')
    w = max(len(l) for l in out); rows = []
    for l in out:
        l = l.ljust(w); top = []; bot = []
        for ch in l:
            top.append(ch in '▀█'); bot.append(ch in '▄█')
        rows += [top, bot]
    return rows  # list of pixel rows, True = filled

def wordmark_png(path, cw=800, ch=188):
    px = wordmark_pixels(); h, w = len(px), len(px[0])
    s = min(cw // w, ch // h)
    im = Image.new('RGBA', (cw, ch), (0, 0, 0, 0)); ox, oy = (cw - w * s) // 2, (ch - h * s) // 2
    d = im.load()
    for y, row in enumerate(px):
        for x, v in enumerate(row):
            if v:
                for yy in range(s):
                    for xx in range(s): d[ox + x * s + xx, oy + y * s + yy] = GREEN
    im.save(path); return w, h, s

def wordmark_svg(path):
    px = wordmark_pixels(); h, w = len(px), len(px[0]); s = 15
    d = []
    for y, row in enumerate(px):
        x = 0
        while x < w:
            if row[x]:
                x0 = x
                while x < w and row[x]: x += 1
                d.append(f'M{x0*s} {y*s}h{(x-x0)*s}v{s}h-{(x-x0)*s}z')
            else: x += 1
    open(path, 'w').write(f'<svg fill="none" height="{h*s}" viewBox="0 0 {w*s} {h*s}" width="{w*s}" xmlns="http://www.w3.org/2000/svg"><path d="{"".join(d)}" fill="#000"/></svg>\n')

def icon_png(path, size=300):
    s = size // 15; im = Image.new('RGBA', (size, size), (0, 0, 0, 0)); d = im.load()
    for y, row in enumerate(MARK):
        for x, c in enumerate(row):
            if c == '1':
                for yy in range(s):
                    for xx in range(s): d[x * s + xx, y * s + yy] = ICON_GREEN
    im.save(path)

def icon_txt(path, cw=4, chh=2):
    lines = []
    for row in MARK:
        line = ''.join(('█' * cw if c == '1' else ' ' * cw) for c in row)
        lines += [line] * chh
    open(path, 'w').write('\n'.join(lines) + '\n')

def font_glyph(path):
    f = TTFont(path); name = f.getBestCmap()[0xE900]; glyf = f['glyf']; old = glyf[name]
    old.recalcBounds(glyf)
    x0, y0, x1, y1 = old.xMin, old.yMin, old.xMax, old.yMax
    size = max(x1 - x0, y1 - y0); cell = size / 15
    ox, oy = x0 + ((x1 - x0) - size) / 2, y0 + ((y1 - y0) - size) / 2
    pen = TTGlyphPen(f.getGlyphSet())
    for y, row in enumerate(MARK):
        x = 0
        while x < 15:
            if row[x] == '1':
                xs = x
                while x < 15 and row[x] == '1': x += 1
                L, Rr = round(ox + xs * cell), round(ox + x * cell)
                T, B = round(oy + (15 - y) * cell), round(oy + (14 - y) * cell)
                pen.moveTo((L, B)); pen.lineTo((L, T)); pen.lineTo((Rr, T)); pen.lineTo((Rr, B)); pen.closePath()  # clockwise = filled in TrueType
            else: x += 1
    glyf[name] = pen.glyph(); f.save(path); return name, (x0, y0, x1, y1)

if __name__ == '__main__':
    only = sys.argv[1:] or ['png', 'svg', 'icon', 'txt', 'font']
    if 'png' in only:
        print('wordmark grid (w,h,scale):', wordmark_png(f'{R}/default/plymouth/logo.png'))
        wordmark_png(f'{R}/default/sddm/omarchy/logo.png')
    if 'svg' in only: wordmark_svg(f'{R}/logo.svg')
    if 'icon' in only: icon_png(f'{R}/icon.png')
    if 'txt' in only: icon_txt(f'{R}/icon.txt')
    if 'font' in only: print('glyph', font_glyph(f'{R}/default/fonts/omarchy/omarchy.ttf'))

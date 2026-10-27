#!/usr/bin/env python3
"""Exports icons from gen_icons.py as custom SF Symbols for the iPhone's system surfaces: the Thoughts icon ('Thought',
the Live Activity and Dynamic Island, the Control Center control, and the Lock Screen widgets, DESIGN.md §14), Mark
and Marked ('Mark', 'Marked': the recording's Live Activity and Dynamic Island, mockup "Library features", section 3),
and the Control Center controls' glyphs (DESIGN.md §3): Dictations ('dictate'), Captions ('captions'), BrandArt's
capture ('record', redrawn here on the 24 grid), and the bars mark ('bars', filled, from BrandArt.markBars).

A custom symbol is an SVG template whose shapes are filled outlines, so the icon's 1.5 strokes (round caps and joins)
are outlined here and joined into one shape. Only the Regular-M variant is drawn (a static template): the system
scales it for other sizes and weights, keeping the brand's fine line.

    pip install skia-pathops      (once; fontTools is needed too)
    python3 mac/tools/gen_symbol.py --write

writes thought, mark, marked, dictate, captions, record, and bars symbol sets into VerbatimPhone/Assets.xcassets and
VerbatimWidgets/Assets.xcassets. Without --write it prints the Thoughts symbol's SVG.
"""
import json
import os
import re
import sys

import pathops
from fontTools.pens.basePen import BasePen
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gen_icons  # noqa: E402

# Each exported icon: its name in gen_icons.py, the symbol's name, and what the SVG's comment calls it.
SYMBOLS = [('Thought', 'thought', 'the Thoughts icon'), ('Mark', 'mark', 'the Mark icon'), ('Marked', 'marked', 'the Marked icon'),
           ('Dictations', 'dictate', 'the Dictations icon'), ('Captions', 'captions', 'the Captions icon'),
           ('Capture', 'record', "BrandArt's capture icon"), ('Bars', 'bars', 'the bars mark')]


def _bars(x, y):
    """BrandArt.markBars (a 76 x 80 box on the 120 grid) at 17 grid units tall, about the other icons' height."""
    k = 17 / 80
    return '%s %s' % (('%.3f' % ((x - 22) * k)).rstrip('0').rstrip('.'), ('%.3f' % ((y - 18) * k)).rstrip('0').rstrip('.'))


# Shapes that aren't in gen_icons.I, on the 24 grid: ('s', path) is stroked like the icons, ('f', path) is filled.
EXTRA = {
    # BrandArt.capture (the 112 box at 8, 8, stroke 4.5) moved to the 24 grid: the mic capsule, its cradle, and stand.
    'Capture': [('s', 'M9 5.79C9 1.79 15 1.79 15 5.79V10.71C15 14.71 9 14.71 9 10.71Z'),
                ('s', 'M6.43 10.93C6.43 15.43 8.79 18 12 18S17.57 15.43 17.57 10.93'),
                ('s', 'M12 18V21.43'), ('s', 'M8.36 21.43H15.64')],
    'Bars': [('f', 'M%sL%sL%sL%sZ' % (_bars(22, 18), _bars(98, 18), _bars(98, 32), _bars(22, 32))),
             ('f', 'M%sL%sL%sL%sZ' % (_bars(22, 43), _bars(80, 43), _bars(80, 57), _bars(22, 57))),
             ('f', 'M%sL%sL%sL%sL%sZ' % (_bars(22, 68), _bars(98, 68), _bars(98, 82), _bars(44, 82), _bars(22, 98)))],
}
# The 24-unit grid at 100 points: 4.3 units per grid unit puts the bulb a little above the cap height and the base
# a little below the baseline, as SF Symbols' own lightbulb sits.
SCALE = 4.3
STROKE = 1.5
BASELINE_M, CAPLINE_M = 1126.0, 1055.54
LEFT_M = 1391.0


def tokens(d):
    for m in re.finditer(r'[MLHVCSZmlhvcsz]|-?\d*\.?\d+(?:e-?\d+)?', d):
        yield m.group(0)


def path_from(d):
    """An absolute M/L/H/V/C/S/Z path (gen_icons.de_arc output) as a pathops Path."""
    p = pathops.Path()
    toks = list(tokens(d))
    i, cmd = 0, None
    x = y = 0.0
    last_c2 = None
    start = (0.0, 0.0)

    def num():
        nonlocal i
        v = float(toks[i])
        i += 1
        return v

    while i < len(toks):
        if re.match(r'[A-Za-z]', toks[i]):
            cmd = toks[i]
            i += 1
            if cmd in 'Zz':
                p.close()
                x, y = start
                last_c2 = None
                continue
        if cmd == 'M':
            x, y = num(), num()
            p.moveTo(x, y)
            start = (x, y)
            cmd = 'L'
            last_c2 = None
        elif cmd == 'L':
            x, y = num(), num()
            p.lineTo(x, y)
            last_c2 = None
        elif cmd == 'H':
            x = num()
            p.lineTo(x, y)
            last_c2 = None
        elif cmd == 'V':
            y = num()
            p.lineTo(x, y)
            last_c2 = None
        elif cmd == 'C':
            c1 = (num(), num())
            c2 = (num(), num())
            x, y = num(), num()
            p.cubicTo(c1[0], c1[1], c2[0], c2[1], x, y)
            last_c2 = c2
        elif cmd == 'S':
            c1 = (2 * x - last_c2[0], 2 * y - last_c2[1]) if last_c2 else (x, y)
            c2 = (num(), num())
            x, y = num(), num()
            p.cubicTo(c1[0], c1[1], c2[0], c2[1], x, y)
            last_c2 = c2
        else:
            raise ValueError('unsupported command ' + str(cmd))
    return p


class CubicPen(BasePen):
    """Passes a path on with its quadratic curves raised to cubics (the template takes cubics)."""

    def __init__(self, out):
        super().__init__(None)
        self.out = out

    def _moveTo(self, pt):
        self.out.moveTo(pt)

    def _lineTo(self, pt):
        self.out.lineTo(pt)

    def _curveToOne(self, p1, p2, p3):
        self.out.curveTo(p1, p2, p3)

    def _qCurveToOne(self, p1, p2):
        p0 = self._getCurrentPoint()
        c1 = (p0[0] + 2 / 3 * (p1[0] - p0[0]), p0[1] + 2 / 3 * (p1[1] - p0[1]))
        c2 = (p2[0] + 2 / 3 * (p1[0] - p2[0]), p2[1] + 2 / 3 * (p1[1] - p2[1]))
        self.out.curveTo(c1, c2, p2)

    def _closePath(self):
        self.out.closePath()


def outline(icon='Thought'):
    """The icon's strokes, outlined and joined (and its fills, for the bars), on the 24 grid."""
    if icon in EXTRA:
        parts = EXTRA[icon]
    else:
        parts = []
        for kind, el, _ in gen_icons.I[icon]:
            k, data = el
            assert kind == 's' and k == 'path', 'an exported icon is strokes only'
            parts.append(('s', data))
    shapes = []
    for kind, data in parts:
        shape = path_from(gen_icons.de_arc(data))
        if kind == 's':
            shape.stroke(STROKE, pathops.LineCap.ROUND_CAP, pathops.LineJoin.ROUND_JOIN, 4)
            shape.convertConicsToQuads()
        shapes.append(shape)
    joined = pathops.Path()
    pathops.union(shapes, joined.getPen(), fix_winding=True)
    return joined


def symbol_svg(icon='Thought', name='thought', called='the Thoughts icon'):
    shape = outline(icon)
    xmin, ymin, xmax, ymax = shape.bounds
    width = (xmax - xmin) * SCALE
    mid = (ymin + ymax) / 2
    cap_mid = -(BASELINE_M - CAPLINE_M) / 2
    # Grid → the Regular-M frame: x from the left margin, y from the baseline (up is negative).
    tx, ty = -xmin * SCALE, cap_mid - mid * SCALE
    pen = SVGPathPen(None, ntos=lambda v: ('%.2f' % v).rstrip('0').rstrip('.'))
    shape.draw(CubicPen(TransformPen(pen, (SCALE, 0, 0, SCALE, tx, ty))))
    d = pen.getCommands()
    right = LEFT_M + width
    guide = 'fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;'
    margin = 'fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;'
    text = 'stroke:none;fill:black;font-family:sans-serif;font-size:13;'
    return f'''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
<!--Generated by mac/tools/gen_symbol.py from {called} (gen_icons.py). Edit the icon there, not this file.-->
<svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="3300" height="2200">
 <g id="Notes">
  <rect height="2200" id="artboard" style="fill:white;opacity:1" width="3300" x="0" y="0"/>
  <line style="fill:none;stroke:black;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="292" y2="292"/>
  <text style="{text}font-weight:bold;" transform="matrix(1 0 0 1 263 322)">Weight/Scale Variations</text>
  <text style="{text}text-anchor:middle;" transform="matrix(1 0 0 1 1443.65 322)">Regular</text>
  <text style="{text}" transform="matrix(1 0 0 1 263 1251)">Medium</text>
  <text id="template-version" style="{text}text-anchor:end;" transform="matrix(1 0 0 1 3036 1933)">Template v.2.0</text>
  <text style="{text}text-anchor:end;" transform="matrix(1 0 0 1 3036 1951)">Requires Xcode 12 or greater</text>
  <text id="descriptive-name" style="{text}text-anchor:end;" transform="matrix(1 0 0 1 3036 1969)">Generated from {name}</text>
  <text style="{text}text-anchor:end;" transform="matrix(1 0 0 1 3036 1987)">Typeset at 100 points</text>
 </g>
 <g id="Guides">
  <line id="Baseline-S" style="{guide}" x1="263" x2="3036" y1="696" y2="696"/>
  <line id="Capline-S" style="{guide}" x1="263" x2="3036" y1="625.541" y2="625.541"/>
  <line id="Baseline-M" style="{guide}" x1="263" x2="3036" y1="{BASELINE_M:g}" y2="{BASELINE_M:g}"/>
  <line id="Capline-M" style="{guide}" x1="263" x2="3036" y1="{CAPLINE_M:g}" y2="{CAPLINE_M:g}"/>
  <line id="Baseline-L" style="{guide}" x1="263" x2="3036" y1="1556" y2="1556"/>
  <line id="Capline-L" style="{guide}" x1="263" x2="3036" y1="1485.54" y2="1485.54"/>
  <line id="left-margin-Regular-M" style="{margin}" x1="{LEFT_M:g}" x2="{LEFT_M:g}" y1="1030.79" y2="1150.12"/>
  <line id="right-margin-Regular-M" style="{margin}" x1="{right:.2f}" x2="{right:.2f}" y1="1030.79" y2="1150.12"/>
 </g>
 <g id="Symbols">
  <g id="Regular-M" transform="matrix(1 0 0 1 {LEFT_M:g} {BASELINE_M:g})">
   <path d="{d}"/>
  </g>
 </g>
</svg>
'''


def contents(name):
    return {
        'info': {'author': 'xcode', 'version': 1},
        'symbols': [{'filename': name + '.svg', 'idiom': 'universal'}],
    }


def write(catalog, icon='Thought', name='thought', called='the Thoughts icon'):
    folder = os.path.join(catalog, name + '.symbolset')
    os.makedirs(folder, exist_ok=True)
    with open(os.path.join(folder, name + '.svg'), 'w') as fh:
        fh.write(symbol_svg(icon, name, called))
    with open(os.path.join(folder, 'Contents.json'), 'w') as fh:
        json.dump(contents(name), fh, indent=2)
        fh.write('\n')
    top = os.path.join(catalog, 'Contents.json')
    if not os.path.exists(top):
        with open(top, 'w') as fh:
            json.dump({'info': {'author': 'xcode', 'version': 1}}, fh, indent=2)
            fh.write('\n')
    print('wrote', folder)


if __name__ == '__main__':
    if '--write' in sys.argv:
        mac = os.path.dirname(HERE)
        for c in ('VerbatimPhone/Assets.xcassets', 'VerbatimWidgets/Assets.xcassets'):
            for icon, name, called in SYMBOLS:
                write(os.path.join(mac, c), icon, name, called)
    else:
        sys.stdout.write(symbol_svg())

#!/usr/bin/env python3
"""Generates the fine-line icon set (BrandArt.icon*) for Verbatim from the approved canvas drawings.

The source of truth is the "Verbatim icon set" design canvas (fine-line style, October 18, 2026): 37 icons on a
24-unit grid, stroke 1.5, round caps and joins. SVGPathData has no arc command, so every arc becomes cubic Béziers
here.

    python3 mac/tools/gen_icons.py            prints the Swift
    python3 mac/tools/gen_icons.py --write    replaces the BEGIN/END ICONS block in Verbatim/Views/Brand.swift
    python3 mac/tools/gen_icons.py --svg out.svg   writes a contact sheet for checking the drawings
"""
import math
import os
import re
import sys


def f(v):
    s = ('%.2f' % v).rstrip('0').rstrip('.')
    return '0' if s in ('-0', '') else s


def arc_cubics(x1, y1, r, fa, fs, x2, y2):
    """SVG endpoint arc (circular, no rotation) as cubic segments [((c1x, c1y), (c2x, c2y), (x, y)), ...]."""
    if abs(x1 - x2) < 1e-9 and abs(y1 - y2) < 1e-9:
        return []
    dx, dy = (x1 - x2) / 2, (y1 - y2) / 2
    lam = (dx * dx + dy * dy) / (r * r)
    if lam > 1:
        r *= math.sqrt(lam)
    sign = -1 if fa == fs else 1
    num = r * r * r * r - r * r * dy * dy - r * r * dx * dx
    den = r * r * dy * dy + r * r * dx * dx
    coef = sign * math.sqrt(max(0.0, num / den))
    cx, cy = coef * dy + (x1 + x2) / 2, -coef * dx + (y1 + y2) / 2
    t1 = math.atan2(y1 - cy, x1 - cx)
    t2 = math.atan2(y2 - cy, x2 - cx)
    dt = t2 - t1
    if fs and dt < 0:
        dt += 2 * math.pi
    elif not fs and dt > 0:
        dt -= 2 * math.pi
    n = max(1, int(math.ceil(abs(dt) / (math.pi / 2) - 1e-9)))
    step = dt / n
    out = []
    for i in range(n):
        a0 = t1 + i * step
        a1 = a0 + step
        k = 4 / 3 * math.tan((a1 - a0) / 4)
        p0 = (cx + r * math.cos(a0), cy + r * math.sin(a0))
        p3 = (cx + r * math.cos(a1), cy + r * math.sin(a1))
        c1 = (p0[0] - k * r * math.sin(a0), p0[1] + k * r * math.cos(a0))
        c2 = (p3[0] + k * r * math.sin(a1), p3[1] - k * r * math.cos(a1))
        out.append((c1, c2, p3))
    return out


def de_arc(d):
    """Rewrites absolute A commands as C commands; other commands pass through unchanged."""
    if 'A' not in d:
        return d
    toks = re.findall(r'[A-Za-z]|-?\d*\.?\d+(?:e-?\d+)?', d)
    out, i, cmd = [], 0, None
    cur, start = (0.0, 0.0), (0.0, 0.0)

    def num():
        nonlocal i
        v = float(toks[i])
        i += 1
        return v

    while i < len(toks):
        if toks[i].isalpha():
            cmd = toks[i]
            i += 1
            if cmd in 'Zz':
                out.append('Z')
                cur = start
                continue
        if not cmd.isupper():
            raise ValueError('only absolute commands are supported: ' + d)
        if cmd == 'M':
            cur = (num(), num())
            start = cur
            out.append('M%s %s' % (f(cur[0]), f(cur[1])))
            cmd = 'L'
        elif cmd == 'L':
            cur = (num(), num())
            out.append('L%s %s' % (f(cur[0]), f(cur[1])))
        elif cmd == 'H':
            cur = (num(), cur[1])
            out.append('H%s' % f(cur[0]))
        elif cmd == 'V':
            cur = (cur[0], num())
            out.append('V%s' % f(cur[1]))
        elif cmd == 'C':
            v = [num() for _ in range(6)]
            cur = (v[4], v[5])
            out.append('C' + ' '.join(f(x) for x in v))
        elif cmd == 'S':
            v = [num() for _ in range(4)]
            cur = (v[2], v[3])
            out.append('S' + ' '.join(f(x) for x in v))
        elif cmd == 'A':
            r, _ry, _phi, fa, fs, x, y = [num() for _ in range(7)]
            for c1, c2, p in arc_cubics(cur[0], cur[1], r, int(fa), int(fs), x, y):
                out.append('C%s %s %s %s %s %s' % (f(c1[0]), f(c1[1]), f(c2[0]), f(c2[1]), f(p[0]), f(p[1])))
            cur = (x, y)
        else:
            raise ValueError('unsupported command ' + cmd)
    return ' '.join(out)


def A(cx, cy, r, a0, a1):
    """An arc on a circle: angles in degrees, 0 at twelve o'clock, clockwise (as in the canvas)."""
    def p(a):
        return (cx + r * math.sin(math.radians(a)), cy - r * math.cos(math.radians(a)))
    s0, e = p(a0), p(a1)
    return 'M%s %sA%s %s 0 %d 1 %s %s' % (f(s0[0]), f(s0[1]), r, r, 1 if a1 - a0 > 180 else 0, f(e[0]), f(e[1]))


def C(x, y, r):
    return ('circle', (x, y, r))


def s(el, dash=None):
    """A stroked element, optionally dashed (on, off)."""
    return ('s', ('path', el) if isinstance(el, str) else el, dash)


def fl(el):
    """A filled element."""
    return ('f', ('path', el) if isinstance(el, str) else el, None)


I = {
    # Navigation
    'Home': [s(C(12, 12, 7)), s(C(12, 15, 4)), s('M12 2.5V21.5'), s('M10 2.5H14'), s('M10 21.5H14')],
    'Library': [s('M3.5 20.5H20.5'), s('M5 20.5V6H8.5V20.5'), s('M10.5 20.5V9H14V20.5'), s('M15.6 20.5L18.2 8.8L21 9.4L18.6 20.5')],
    'Links': [s(C(6.5, 12, 3.5)), s(C(17.5, 12, 3.5)), s('M10 12H14'), fl(C(6.5, 12, 1)), fl(C(17.5, 12, 1))],
    'Moments': [s('M3 15H21'), s('M6 13.5V16.5'), s('M18 13.5V16.5'), s(C(12, 15, 4.5)), fl(C(12, 15, 1.6)), s('M12 4.5V10.5')],
    'Queue': [fl(C(5, 7, 1.6)), s(C(5, 12, 1.4)), s(C(5, 17, 1.4)), s('M9 7H20'), s('M9 12H18'), s('M9 17H15.5')],
    'Dictations': [s('M3 9C4.5 4.5 6 4.5 7.5 9S10.5 13.5 12 9 15 4.5 16.5 9 19.5 13.5 21 9'), s('M3 15.5H21'), s('M3 19.5H14')],
    'Activity': [fl(C(6, 6, 1.2)), fl(C(12, 6, 2.3)), fl(C(18, 6, 1.2)), fl(C(6, 12, 2.3)), fl(C(12, 12, 1.2)),
                 fl(C(18, 12, 2.3)), fl(C(6, 18, 1.2)), fl(C(12, 18, 2.3)), fl(C(18, 18, 2.3))],
    'Dictionary': [s('M12 6.5C9.5 4.8 6.5 4.5 3.5 5.2V18.7C6.5 18 9.5 18.3 12 20C14.5 18.3 17.5 18 20.5 18.7V5.2C17.5 4.5 14.5 4.8 12 6.5Z'), s('M12 6.5V20')],
    'Settings': [s(C(12, 12, 6.5)), s('M12 12V7.5'), fl(C(12, 12, 1.2)), s('M12 2.5V4'), s('M20.23 16.75L18.93 16'), s('M3.77 16.75L5.07 16')],
    'Deleted': [s('M6 3.5H14L18 7.5V20.5H6Z', (1.6, 1.9)), s('M14 3.5V7.5H18')],
    # Settings rows
    'Language': [s(C(12, 12, 8.5)), s('M3.5 12H20.5'), s('M12 3.5C9 6 9 18 12 20.5C15 18 15 6 12 3.5')],
    'Voice': [s(C(12, 12, 8)), s(C(15, 12, 5)), s(C(18, 12, 2))],
    'AboutMe': [s(C(12, 8.5, 3.5)), s('M5.5 19.5C5.5 15.5 8.4 13.5 12 13.5S18.5 15.5 18.5 19.5'), s('M3.5 19.5H20.5')],
    'Summaries': [s('M4 6H16'), s('M4 11H13'), s('M4 16H10'), s('M17 4H20V19H17')],
    'Appearance': [s(C(12, 12, 8.5)), fl('M12 3.5A8.5 8.5 0 0 1 12 20.5Z')],
    'LimitMotion': [s('M12 3V15.5'), s('M8.5 3H15.5'), fl(C(12, 18, 2.5)), s('M5.5 14.5A8 8 0 0 0 18.5 14.5', (1.2, 1.8))],
    'Quality': [s('M4 4H20V20H4Z'), s('M12 6L18 12L12 18L6 12Z'), s('M10 10H14V14H10Z')],
    'Speakers': [s(C(9, 12, 5.5)), s(C(15, 12, 5.5)), fl(C(9, 12, 1.1)), fl(C(15, 12, 1.1))],
    'ApplyDictionary': [s('M5 6H13C17.5 6 17.5 12 12 12C6.5 12 6.5 18 11 18H19'), fl(C(4, 6, 1.4)), fl(C(20, 18, 1.4))],
    'NameAndSort': [s('M12 3V21'), s('M3 12H21'), s('M10.5 7.5H13.5'), s('M10.5 16.5H13.5'), s('M7.5 10.5V13.5'), s('M16.5 10.5V13.5'),
                    s(C(6.2, 6.5, 1.6)), s(C(18, 8, 1.6)), s(C(7, 17.6, 1.6)), s(C(17.6, 17, 1.6))],
    'Filler': [s(C(12, 12, 8.5), (3, 2.6)), s(C(12, 12, 4.5), (2, 2.4)), fl(C(12, 12, 1.1))],
    'MainSpeaker': [s('M3.5 3.5H20.5V20.5H3.5Z'), s('M8 8H16V16H8Z'), s('M3.5 3.5L8 8'), s('M20.5 3.5L16 8'), s('M3.5 20.5L8 16'),
                    s('M20.5 20.5L16 16'), s(C(12, 12, 1.6))],
    'Sync': [s(C(5, 16.5, 2)), s(C(19, 16.5, 2)), s('M5 14.5C5 6.5 19 6.5 19 14.5'), fl(C(12, 8.5, 1.2))],
    'SyncOff': [s(C(5, 16.5, 2)), s(C(19, 16.5, 2)), s('M5 14.5C5 11 6.6 9 8.6 8.1'), s('M15.4 8.1C17.4 9 19 11 19 14.5')],
    'Export': [s('M4 13V20H20V13'), s('M12 3.5V15'), s('M8 11L12 15L16 11')],
    'DeleteAll': [s('M5 7H19'), s('M5 12H19'), s('M5 17H19'), s('M4.5 20.5L19.5 3.5')],
    'Support': [s('M12 3.5A8.5 8.5 0 0 1 20.5 12V20.5H12A8.5 8.5 0 0 1 12 3.5Z'), s('M8.5 12H15.5')],
    'Feedback': [s('M15.5 4.5L19.5 8.5L8.5 19.5H4.5V15.5Z'), s('M13 7L17 11')],
    'DiagnosticLog': [fl(C(5, 7, 1)), s('M8 7H14'), fl(C(5, 12, 1)), s('M8 12H17'), fl(C(5, 17, 1)), s('M8 17H11'),
                      s('M14.5 19.5L20 14'), s('M16.5 14H20V17.5')],
    'Privacy': [s(C(12, 12, 8.5)), s(C(12, 10.3, 2.2)), s('M12 12.5V16.5')],
    'Terms': [s('M6 3.5H18V20.5H6Z'), s('M9 8H15'), s('M9 12H15'), s('M9 16H12.5')],
    'Share': [s('M8 10H5V20.5H19V10H16'), s('M12 3V14'), s('M8.5 6.5L12 3L15.5 6.5')],
    'Tour': [s(C(12, 12, 8.5)), s('M10 8.5L15.5 12L10 15.5Z')],
    # Status
    'Transcribing': [s(A(12, 12, 8.5, 0, 250)), s(A(12, 12, 8.5, 250, 360), (1.2, 1.8)), fl(C(12, 12, 1.6))],
    'WaitingForMac': [s(C(4.5, 12, 2)), s('M15 8H21V14H15Z'), s('M14 16.5H22'), s('M7.5 12H13', (0.8, 1.8))],
    'Attention': [s(C(12, 12, 8.5)), s('M12 7V13'), fl(C(12, 16.3, 1.1))],
    'Recovered': [s(A(12, 12, 8.5, 6, 66)), s(A(12, 12, 8.5, 78, 138)), s(A(12, 12, 8.5, 150, 210)), s(A(12, 12, 8.5, 222, 282)),
                  s(A(12, 12, 8.5, 294, 354)), fl(C(12, 12, 1.6))],
}


def swift_el(el):
    kind, data = el
    if kind == 'circle':
        return '.circle(%s, %s, %s)' % tuple(f(x) for x in data)
    return '.path("%s")' % de_arc(data)


def emit():
    lines = ['    // BEGIN ICONS (generated by mac/tools/gen_icons.py; edit that file, not this block)',
             '    // Fine-line interface icons (icon set canvas, October 18, 2026): 24-unit grid, stroke 1.5, round ends.',
             '    static let iconGrid = CGRect(x: 0, y: 0, width: 24, height: 24)']
    for name, els in I.items():
        strokes = [swift_el(e[1]) for e in els if e[0] == 's' and not e[2]]
        fills = [swift_el(e[1]) for e in els if e[0] == 'f']
        dashes = {}
        for e in els:
            if e[0] == 's' and e[2]:
                dashes.setdefault(e[2], []).append(swift_el(e[1]))
        parts = ['box: iconGrid', 'strokes: [%s]' % ', '.join(strokes)]
        if fills:
            parts.append('fills: [%s]' % ', '.join(fills))
        parts.append('strokeWidth: 1.5')
        if dashes:
            groups = ['.init(elements: [%s], pattern: [%s, %s])' % (', '.join(v), f(k[0]), f(k[1])) for k, v in dashes.items()]
            parts.append('dashes: [%s]' % ', '.join(groups))
        lines.append('    static let icon%s = BrandArt(%s)' % (name, ', '.join(parts)))
    lines.append('    // END ICONS')
    return '\n'.join(lines)


def svg_sheet(path):
    """A contact sheet of every icon, drawn from the converted (arc-free) data, for checking."""
    names = list(I)
    cols = 10
    out = ['<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" style="background:#F5F0E6">' % (cols * 96, (len(names) + cols - 1) // cols * 110)]
    for i, name in enumerate(names):
        x, y = (i % cols) * 96 + 12, (i // cols) * 110 + 8
        out.append('<g transform="translate(%d %d) scale(3)" fill="none" stroke="#26352E" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">' % (x, y))
        for kind, el, dash in I[name]:
            k, data = el
            d = ('M%s %sa%s %s 0 1 0 %s 0a%s %s 0 1 0 %s 0' % (f(data[0] - data[2]), f(data[1]), f(data[2]), f(data[2]), f(2 * data[2]), f(data[2]), f(data[2]), f(-2 * data[2]))) if k == 'circle' else de_arc(data)
            if kind == 'f':
                out.append('<path d="%s" fill="#26352E" stroke="none"/>' % d)
            else:
                out.append('<path d="%s"%s/>' % (d, (' stroke-dasharray="%s %s"' % dash) if dash else ''))
        out.append('</g><text x="%d" y="%d" font-size="10" font-family="sans-serif" fill="#545E56">%s</text>' % (x - 4, y + 92, name))
    out.append('</svg>')
    open(path, 'w').write('\n'.join(out))


if __name__ == '__main__':
    if '--svg' in sys.argv:
        svg_sheet(sys.argv[sys.argv.index('--svg') + 1])
    out = emit()
    if '--write' in sys.argv:
        p = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'Verbatim', 'Views', 'Brand.swift')
        src = open(p).read()
        if '// BEGIN ICONS' in src:
            src = re.sub(r'    // BEGIN ICONS.*?// END ICONS', lambda m: out, src, flags=re.S)
        else:
            marker = '    static let understandHatch'
            idx = src.index(marker)
            end = src.index('\n', idx) + 1
            src = src[:end] + '\n' + out + '\n' + src[end:]
        open(p, 'w').write(src)
    elif '--svg' not in sys.argv:
        print(out)

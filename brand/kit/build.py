"""Builds the Verbatim brand kit: logo, colophon, lockups, color, type, icons, and diagrams."""
import json, math, os, shutil, subprocess, sys
import cairosvg
import uharfbuzz as hb
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer
from fontTools.pens.svgPathPen import SVGPathPen
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
SCRATCH = os.path.dirname(HERE)
OUT = os.path.join(HERE, "verbatim-brand")
FONTS = os.path.join(HERE, "fonts-src")
shutil.rmtree(OUT, ignore_errors=True)

PERSIMMON, INK, PAPER = "#FA6B47", "#26352E", "#F5F0E6"


def write(rel, text):
    p = os.path.join(OUT, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, "w").write(text)
    return p


def png(svg_path, sizes, square=True):
    base = svg_path[:-4]
    for s in sizes:
        out = f"{base}-{s}.png" if len(sizes) > 1 else f"{base}.png"
        if square:
            cairosvg.svg2png(url=svg_path, write_to=out, output_width=s, output_height=s)
        else:
            cairosvg.svg2png(url=svg_path, write_to=out, output_width=s)


# ---------- 01 Logo: app-icon mark (bars) ----------
BARS = ('<rect x="22" y="18" width="76" height="14"/><rect x="22" y="43" width="58" height="14"/>'
        '<path d="M22 68 L98 68 L98 82 L44 82 L22 98 Z"/>')


def mark_svg(color, bg=None, rounded=False):
    back = ""
    if bg:
        back = f'<rect width="120" height="120" rx="{27 if rounded else 0}" fill="{bg}"/>'
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 120">{back}'
            f'<g fill="{color}">{BARS}</g></svg>')


for name, color in [("persimmon", PERSIMMON), ("ink", INK), ("paper", PAPER)]:
    p = write(f"01-logo/mark/verbatim-mark-{name}.svg", mark_svg(color))
    png(p, [1024, 256, 64])

for name, bg, fg in [("persimmon", PERSIMMON, PAPER), ("ink-on-paper", PAPER, INK), ("reversed", INK, PAPER)]:
    # Full-bleed squares for Icon Composer and stores (the system applies its own corner shape).
    p = write(f"01-logo/app-icon/verbatim-app-icon-{name}.svg",
              f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024"><rect width="1024" height="1024" fill="{bg}"/>'
              f'<g transform="translate(232 232) scale(4.6667)" fill="{fg}">{BARS}</g></svg>')
    png(p, [1024, 512, 180, 120, 64, 32, 16])
    p = write(f"01-logo/app-icon/preview-rounded/verbatim-app-icon-{name}-rounded.svg", mark_svg(fg, bg, rounded=True))
    png(p, [512])

# ---------- 02 Colophon: tangent rings ----------
def rings_svg(color):
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 120">'
            f'<g fill="none" stroke="{color}" stroke-width="8"><circle cx="60" cy="60" r="42"/><circle cx="60" cy="72" r="30"/><circle cx="60" cy="84" r="18"/></g>'
            f'<g fill="{color}"><rect x="57" y="2" width="6" height="116"/><rect x="48" y="2" width="24" height="6"/><rect x="48" y="112" width="24" height="6"/></g></svg>')


for name, color in [("persimmon", PERSIMMON), ("ink", INK), ("paper", PAPER)]:
    p = write(f"02-colophon/verbatim-colophon-{name}.svg", rings_svg(color))
    png(p, [1024, 256, 64])

# ---------- 03 Lockups: mark + Newsreader wordmark, converted to outlines ----------
vf = TTFont(os.path.join(FONTS, "newsreader-Newsreader[opsz,wght].ttf"))
static = instancer.instantiateVariableFont(vf, {"opsz": 72, "wght": 400})
static_path = os.path.join(HERE, "Newsreader-Display-Regular.ttf")
static.save(static_path)
font = TTFont(static_path)
upem = font["head"].unitsPerEm
cap = font["OS/2"].sCapHeight
gs = font.getGlyphSet()
blob = hb.Blob.from_file_path(static_path)
hbfont = hb.Font(hb.Face(blob))


def outline(text):
    buf = hb.Buffer()
    buf.add_str(text)
    buf.guess_segment_properties()
    hb.shape(hbfont, buf, {"kern": True, "liga": True})
    names = font.getGlyphOrder()
    x, parts = 0, []
    for info, pos in zip(buf.glyph_infos, buf.glyph_positions):
        pen = SVGPathPen(gs)
        gs[names[info.codepoint]].draw(pen)
        d = pen.getCommands()
        if d:
            parts.append(f'<path transform="translate({x + pos.x_offset} 0)" d="{d}"/>')
        x += pos.x_advance
    return "".join(parts), x


WORD, WORD_W = outline("Verbatim")
TAG, TAG_W = outline("Verbatim")  # same word; the wordmark is the name alone


def wordmark_svg(color):
    pad = 40
    h = upem + 2 * pad
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {WORD_W + 2 * pad} {h}">'
            f'<g fill="{color}" transform="translate({pad} {pad + upem * 0.8}) scale(1 -1)">{WORD}</g></svg>')


def lockup_svg(mark_color, word_color, stacked=False):
    # The mark's bars (18 to 98 on its 120 grid) span 1.35 cap heights; its top aligns with the cap height.
    s = (cap * 1.35) / 80.0
    mark_w = 120 * s
    gap = cap * 0.55
    baseline = upem * 0.9
    if not stacked:
        mx, my = 0, baseline - cap - 18 * s
        wx = mark_w + gap - 22 * s
        W, H = wx + WORD_W + 20, upem * 1.15
        return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W:.0f} {H:.0f}">'
                f'<g fill="{mark_color}" transform="translate({mx:.1f} {my:.1f}) scale({s:.4f})">{BARS}</g>'
                f'<g fill="{word_color}" transform="translate({wx:.1f} {baseline:.1f}) scale(1 -1)">{WORD}</g></svg>')
    W = max(WORD_W, mark_w) + 40
    mx = (W - mark_w) / 2
    top = 20
    wy = top + 98 * s + cap * 0.6 + cap
    H = wy + upem * 0.3
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W:.0f} {H:.0f}">'
            f'<g fill="{mark_color}" transform="translate({mx:.1f} {top - 18 * s:.1f}) scale({s:.4f})">{BARS}</g>'
            f'<g fill="{word_color}" transform="translate({(W - WORD_W) / 2:.1f} {wy:.1f}) scale(1 -1)">{WORD}</g></svg>')


for name, mc, wc in [("persimmon-ink", PERSIMMON, INK), ("ink", INK, INK), ("paper", PAPER, PAPER), ("persimmon-paper", PERSIMMON, PAPER)]:
    p = write(f"03-lockups/horizontal/verbatim-lockup-horizontal-{name}.svg", lockup_svg(mc, wc))
    png(p, [2400], square=False)
    p = write(f"03-lockups/stacked/verbatim-lockup-stacked-{name}.svg", lockup_svg(mc, wc, stacked=True))
    png(p, [1600], square=False)
for name, c in [("ink", INK), ("paper", PAPER), ("persimmon", PERSIMMON)]:
    p = write(f"03-lockups/wordmark/verbatim-wordmark-{name}.svg", wordmark_svg(c))
    png(p, [2400], square=False)

# ---------- 04 Color ----------
colors = [
    ("paper", "#F5F0E6", "#18241F", "App background"),
    ("ink", "#26352E", "#F5F0E6", "Primary text, marks"),
    ("persimmon", "#FA6B47", "#F27A57", "Brand accent, app icon, record"),
    ("petal", "#EFB6C8", "#C98EA2", "Supporting color: Journal, Refine"),
    ("butter", "#F4C76B", "#D4AB55", "Supporting color: Idea"),
    ("sage", "#AFC398", "#93A87C", "Supporting color: Meeting, Understand"),
    ("reader", "#FFFDF9", "#1D2B25", "Cards and reading sheet"),
    ("dim", "#545E56", "#D4CDC0", "Secondary text (5.9:1)"),
    ("mute", "#606962", "#A1A29A", "Metadata, timestamps (5.0:1)"),
    ("accent-text", "#B23F24", "#FF8A6B", "Accent text and links"),
    ("sage-text", "#4F6440", "#B9CDA3", "Sage text, switches"),
    ("persimmon-tint", "#FDE4DA", "#3A2A22", "Tile tint"),
    ("petal-tint", "#FAE6EC", "#33282D", "Tile tint"),
    ("butter-tint", "#FCF0D2", "#332E20", "Tile tint"),
    ("sage-tint", "#E9EFE0", "#26322A", "Tile tint"),
]
tokens = {"color": {n: {"$type": "color", "$value": l, "$description": d,
                        "$extensions": {"mode": {"light": l, "dark": dk}}} for n, l, dk, d in colors}}
write("04-color/verbatim-colors.tokens.json", json.dumps(tokens, indent=2))
css = ":root {\n" + "".join(f"  --vb-{n}: {l};\n" for n, l, dk, d in colors) + "}\n@media (prefers-color-scheme: dark) {\n  :root {\n" + "".join(f"    --vb-{n}: {dk};\n" for n, l, dk, d in colors) + "  }\n}\n"
write("04-color/verbatim-colors.css", css)


def rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


lines = ["Verbatim colors", "", f"{'Name':16} {'Light':9} {'RGB':15} {'Dark':9} Use"]
for n, l, dk, d in colors:
    r = rgb(l)
    lines.append(f"{n:16} {l:9} {str(r):15} {dk:9} {d}")
write("04-color/verbatim-colors.txt", "\n".join(lines) + "\n")
cells = []
for i, (n, l, dk, d) in enumerate(colors):
    x, y = (i % 5) * 230 + 40, (i // 5) * 250 + 40
    txt = INK if sum(rgb(l)) > 380 else PAPER
    cells.append(f'<rect x="{x}" y="{y}" width="210" height="150" rx="14" fill="{l}" stroke="#26352E" stroke-opacity=".12"/>'
                 f'<text x="{x}" y="{y + 178}" font-family="Helvetica, Arial" font-size="17" font-weight="bold" fill="{INK}">{n}</text>'
                 f'<text x="{x}" y="{y + 200}" font-family="Menlo, monospace" font-size="14" fill="#545E56">{l} · dark {dk}</text>')
p = write("04-color/verbatim-palette.svg", f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1190 800"><rect width="1190" height="800" fill="{PAPER}"/>{"".join(cells)}</svg>')
png(p, [2380], square=False)

# ---------- 05 Typography ----------
tdir = os.path.join(OUT, "05-typography", "fonts")
os.makedirs(tdir, exist_ok=True)
for f in os.listdir(FONTS):
    shutil.copy(os.path.join(FONTS, f), os.path.join(tdir, f.split("-", 1)[1] if f.endswith(".ttf") else f))
img = Image.new("RGB", (2000, 1100), PAPER)
dr = ImageDraw.Draw(img)
news = ImageFont.truetype(static_path, 150)   # the display instance used for the wordmark (opsz 72, Regular)
news_s = ImageFont.truetype(static_path, 56)
mono = ImageFont.truetype(os.path.join(FONTS, "ibmplexmono-IBMPlexMono-Regular.ttf"), 30)
dej = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
dr.text((90, 70), "◇", font=ImageFont.truetype(dej, 30) if os.path.exists(dej) else mono, fill="#545E56")
dr.text((130, 70), "TYPOGRAPHY ··························· 05", font=mono, fill="#545E56")
dr.text((90, 150), "Words worth keeping.", font=news, fill=INK)
dr.text((90, 360), "Newsreader · display serif for headlines and titles", font=news_s, fill=INK)
dr.text((90, 470), "IBM PLEX MONO · LABELS, TIMECODES, SECTION MARKERS", font=mono, fill="#545E56")
dr.text((90, 540), "00:42 · VOICE NOTE · 2 SPEAKERS · TODAY 9:14 AM", font=mono, fill=INK)
sf = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 34) if os.path.exists("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf") else mono
dr.text((90, 640), "SF Pro (system) · interface, body text, controls, with Dynamic Type", font=sf, fill=INK)
dr.text((90, 760), "Hierarchy: serif headline › system body › mono metadata, with ◇ and dotted leaders", font=sf, fill="#545E56")
img.save(os.path.join(OUT, "05-typography", "verbatim-type-specimen.png"))

# ---------- 06 Icons (fine line, 24-unit grid) ----------
icon_src = open(os.path.join(SCRATCH, "icons", "project", "Icon.dc.html")).read()
js = icon_src[icon_src.index("class Component extends DCLogic {"):icon_src.index("</script>", icon_src.index("class Component"))]
names = ["home", "library", "links", "moments", "queue", "dictations", "activity", "dictionary", "settings", "deleted",
         "language", "voice", "aboutme", "summaries", "appearance", "limitmotion", "quality", "speakers", "applydict", "namesort",
         "filler", "mainspeaker", "sync", "syncoff", "export", "deleteall", "support", "feedback", "diaglog", "privacy", "terms",
         "share", "tour", "transcribing", "waitingmac", "attention", "recovered"]
groups = {"navigation": names[:10], "settings": names[10:33], "status": names[33:]}
runner = os.path.join(HERE, "icons.js")
open(runner, "w").write("class DCLogic {}\n" + js + """
const out = {};
for (const n of %s) { const c = new Component(); c.props = { icon: n, color: 'currentColor' }; out[n] = c.renderVals().els; }
console.log(JSON.stringify(out));
""" % json.dumps(names))
data = json.loads(subprocess.check_output(["node", runner]))
for group, items in groups.items():
    for n in items:
        els = "".join(f'<path d="{e["d"]}" fill="{e["fill"]}" stroke="{e["stroke"]}"' + (f' stroke-dasharray="{e["dash"]}"' if e["dash"] != "none" else "") + "/>" for e in data[n])
        svg = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24" fill="none" '
               f'stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" color="{INK}">{els}</svg>')
        p = write(f"06-icons/{group}/verbatim-icon-{n}.svg", svg)
        cairosvg.svg2png(url=p, write_to=p[:-4] + "@2x.png", output_width=48, output_height=48)
        cairosvg.svg2png(url=p, write_to=p[:-4] + "@3x.png", output_width=72, output_height=72)

# ---------- 07 Diagrams ----------
DIAG = {
    "capture": ('viewBox="168 88 264 342"', 2.8,
                '<circle cx="300" cy="259" r="124"/><circle cx="300" cy="281" r="102"/><circle cx="300" cy="303" r="80"/><circle cx="300" cy="325" r="58"/>'
                '<path d="M300 96 L300 421"/><path d="M280 93h40 M282 425h36"/>', '<circle cx="300" cy="383" r="6"/>'),
    "refine": ('viewBox="70 92 426 314"', 2.7,
               "".join(f'<path d="{d}"/>' for d in [
                   "M75 128 C155 150, 185 100, 246 196 Q258 214 270 247", "M75 168 C155 133, 185 203, 246 213 Q258 225 270 247",
                   "M75 207 C155 229, 185 179, 246 230 Q258 236 270 247", "M75 247 C155 212, 185 282, 246 247 Q258 247 270 247",
                   "M75 287 C155 309, 185 259, 246 264 Q258 258 270 247", "M75 327 C155 292, 185 362, 246 281 Q258 269 270 247",
                   "M75 367 C155 389, 185 339, 246 298 Q258 280 270 247", "M325 128H490", "M325 168H465", "M325 207H440", "M325 247H490",
                   "M325 287H465", "M325 327H440", "M325 367H490", "M299 96 L299 402"]), ""),
}
for name, (vb, sw, strokes, fills) in DIAG.items():
    for cname, c in [("ink", INK), ("paper", PAPER)]:
        p = write(f"07-diagrams/process/verbatim-diagram-{name}-{cname}.svg",
                  f'<svg xmlns="http://www.w3.org/2000/svg" {vb}><g fill="none" stroke="{c}" stroke-width="{sw}" stroke-linecap="round">{strokes}</g><g fill="{c}">{fills}</g></svg>')
        png(p, [1200], square=False)
hatch = "".join(f'<path d="M{200 + 22 * k} 120l-200 290"/>' for k in range(21))
for cname, c in [("ink", INK), ("paper", PAPER)]:
    p = write(f"07-diagrams/process/verbatim-diagram-understand-{cname}.svg",
              '<svg xmlns="http://www.w3.org/2000/svg" viewBox="100 75 400 382"><defs>'
              '<clipPath id="a"><circle cx="300" cy="205" r="126"/></clipPath><clipPath id="b"><circle cx="230" cy="327" r="126"/></clipPath>'
              '<clipPath id="c"><circle cx="370" cy="327" r="126"/></clipPath></defs>'
              f'<g fill="none" stroke="{c}" stroke-width="2.7"><circle cx="300" cy="205" r="126"/><circle cx="230" cy="327" r="126"/><circle cx="370" cy="327" r="126"/></g>'
              f'<g clip-path="url(#a)"><g clip-path="url(#b)"><g clip-path="url(#c)" fill="none" stroke="{c}" stroke-width="2.4">{hatch}</g></g></g></svg>')
    png(p, [1200], square=False)

ns = {}
exec(open(os.path.join(SCRATCH, "gen", "glyphs.py")).read().split("lines=[]")[0], ns)
KIND_COLORS = {"kindJournal": "#EFB6C8", "kindIdea": "#F4C76B", "kindMeeting": "#AFC398", "kindNote": "#FA6B47", "kindDictation": INK}
for gname, (paths, shapes, fills) in ns["G"].items():
    def el(sh):
        return f'<circle cx="{sh[1]}" cy="{sh[2]}" r="{sh[3]}"/>' if sh[0] == "c" else f'<rect x="{sh[1]}" y="{sh[2]}" width="{sh[3]}" height="{sh[4]}"/>'
    folder = "kinds" if gname.startswith("kind") else "features"
    slug = gname[4:].lower() if folder == "kinds" else gname[7:].lower()
    for cname, c in [("ink", INK), ("paper", PAPER)]:
        body = (f'<g fill="none" stroke="{c}" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round">'
                + "".join(f'<path d="{d}"/>' for d in paths) + "".join(el(s) for s in shapes) + "</g>"
                + f'<g fill="{c}">' + "".join(el(s) for s in fills) + "</g>")
        p = write(f"07-diagrams/{folder}/verbatim-{folder[:-1]}-{slug}-{cname}.svg",
                  f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">{body}</svg>')
        png(p, [512])
    if folder == "kinds":
        fg = PAPER if gname == "kindDictation" else INK
        body = (f'<g fill="none" stroke="{fg}" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round">'
                + "".join(f'<path d="{d}"/>' for d in paths) + "".join(el(s) for s in shapes) + "</g>"
                + f'<g fill="{fg}">' + "".join(el(s) for s in fills) + "</g>")
        p = write(f"07-diagrams/kinds/tiles/verbatim-kind-{slug}-tile.svg",
                  f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="-20 -20 140 140"><rect x="-20" y="-20" width="140" height="140" rx="22" fill="{KIND_COLORS[gname]}"/>{body}</svg>')
        png(p, [512])

for f in (runner, static_path):
    os.remove(f)
print("built", OUT)

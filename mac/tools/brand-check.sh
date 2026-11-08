#!/usr/bin/env bash
# Brand check: fails when Swift code breaks the [checked] rules in mac/DESIGN.md.
#   1. SF Symbols outside the allowlist (DESIGN.md §3); system surfaces may mark a line `// brand: system surface`
#   2. Colors outside Tokens.swift: hex literals in color calls and system color names (§1)
#   3. Materials or glass (§5): allowed only on a line marked `// brand: glass ok (no text)`. The refined look's
#      player bar (Views/RefinedPlayback.swift, DESIGN.md §13) is the one place text sits on glass, as in Apple's own
#      players; its line says `// brand: glass ok (the refined player, text allowed by DESIGN.md §13)`.
#   4. The retired V mark, BrandArt.mark (§4)
#   5. Fixed text sizes on iPhone (§13 Type 3): `.font(.system(size:` in VerbatimPhone/ only for an Image (an SF Symbol
#      glyph), or on a line marked `// type: fixed (why)` or `// type: scaled (@ScaledMetric)`. Text uses `refinedFont`
#      or `scaledFont`, which scale with Dynamic Type.
#   6. Literal type, radii, and curves in the Mac app (§5.3, §7, §13; MAC-31): the serif goes through `Refined.serif`
#      (or a kit role), never `.system(size:design: .serif)`, and the counts of literal `.system(size:` fonts, literal
#      `cornerRadius:` numbers, and literal animation curves may only go down. Use `refinedFont`, `RefinedRules.radius`
#      or `Radius`, and the `Motion` tokens; when you remove some, lower the baseline here to the new count.
#   7. In-app toolbars aren't system surfaces (§3): `// brand: system surface (toolbar)` doesn't excuse an SF Symbol.
#   8. Glyphs exported as custom symbols (§3) never fall back to the SF Symbol in the targets that ship them
#      (VerbatimPhone, VerbatimWidgets): `bookmark`, `mic`, and `captions.bubble` fail even on a system surface line;
#      use `mark` or `marked`, `dictate`, or `captions` (`Label(_:image:)`, `Image(_:)`).
#   9. Radius numbers on the small surfaces (§5.3, SF-24): `cornerRadius:` takes a token (`Radius`, `SurfaceRadius`,
#      or one derived from a size) in the widgets, the keyboard, and the watch, never a number.
# Run from anywhere: bash mac/tools/brand-check.sh   (exit 1 lists each problem as file:line)
set -u
cd "$(dirname "$0")/.." || exit 2
DIRS="Verbatim VerbatimPhone VerbatimKeyboard VerbatimShare VerbatimWidgets VerbatimMacWidgets VerbatimWatch VerbatimWatchWidgets"
SRC=$(for d in $DIRS; do [ -d "$d" ] && echo "$d"; done)
fail=0
report() { echo "brand-check: $1"; echo "$2" | sed 's/^/  /'; echo; fail=1; }

ALLOWED='^(xmark|xmark\.circle\.fill|plus|plus\.circle|minus\.circle|chevron\..*|checkmark|checkmark\.circle\.fill|ellipsis|ellipsis\.circle|square\.and\.arrow\.up|trash|magnifyingglass|sidebar\.left|line\.3\.horizontal|arrow\.right|arrow\.up\.arrow\.down|arrow\.uturn\.backward|arrow\.counterclockwise|return|delete\.left|globe|keyboard|shift|shift\.fill|capslock\.fill)$'
syms=$(grep -rnoE --include=*.swift '(systemName|systemImage): *"[^"]+"' $SRC \
  | awk -F: '{ n=$0; sub(/.*: *"/, "", n); sub(/"$/, "", n); print $1 ":" $2 "  " n }' \
  | while IFS= read -r l; do echo "${l##*  }" | grep -qE "$ALLOWED" && continue; f=${l%%:*}; n=${l#*:}; n=${n%%  *}; sed -n "${n}p" "$f" | grep 'brand: system surface' | grep -vq 'brand: system surface (toolbar' || echo "$l"; done)
[ -n "$syms" ] && report "SF Symbols not on the DESIGN.md §3 allowlist (use a BrandArt glyph):" "$syms"

exported=$(for d in VerbatimPhone VerbatimWidgets; do [ -d "$d" ] && grep -rnE --include=*.swift '(systemName|systemImage): *"(bookmark|mic|captions\.bubble)"' "$d"; done | cut -d: -f1,2)
[ -n "$exported" ] && report "SF Symbols for glyphs exported as custom symbols (use mark, marked, dictate, or captions):" "$exported"

hex=$(grep -rnE --include=*.swift '(hex: *0x[0-9A-Fa-f]{6}|Color\(red:|Color\(\.sRGB|UIColor\(red:|NSColor\(red:|NSColor\(calibratedRed:)' $SRC | grep -v 'Views/Tokens.swift' | cut -d: -f1,2)
[ -n "$hex" ] && report "Colors outside Tokens.swift (add or use a Refined token):" "$hex"

sys=$(grep -rnE --include=*.swift '(Color\.|foregroundStyle\(\.|foregroundColor\(\.|tint\(\.|fill\(\.|background\(\.)(red|blue|orange|green|gray|grey|purple|pink|yellow|teal|indigo|mint|cyan|brown|accentColor)\b' $SRC | grep -v 'Views/Tokens.swift' | cut -d: -f1,2)
[ -n "$sys" ] && report "System color names (use Refined tokens; errors use Refined.danger, recording Refined.recordRed):" "$sys"

glass=$(grep -rnE --include=*.swift '\.(ultraThinMaterial|thinMaterial|regularMaterial|thickMaterial|ultraThickMaterial|bar)\b|glassEffect\(' $SRC | grep -E 'Material|glassEffect' | grep -v 'brand: glass ok' | cut -d: -f1,2)
[ -n "$glass" ] && report "Material or glass without '// brand: glass ok (no text)' (never put text on blur):" "$glass"

mark=$(grep -rnE --include=*.swift 'BrandArt\.mark\b|art: *\.mark\b' $SRC | grep -v 'Views/Brand.swift' | cut -d: -f1,2)
[ -n "$mark" ] && report "The retired V mark (use the bars mark):" "$mark"

fixed=$(grep -rn --include=*.swift '\.font(\.system(size:' VerbatimPhone | grep -v '// type: ' | awk '{ i = index($0, ".font(.system(size:"); if (index(substr($0, 1, i), "Image(") == 0) print }' | cut -d: -f1,2)
[ -n "$fixed" ] && report "Fixed text sizes on iPhone (use refinedFont or scaledFont, or mark '// type: fixed (why)'):" "$fixed"

# 6. Literal tokens in the Mac app may only go down (the baselines are the counts on November 7, 2026).
mac_count() { grep -rnE --include=*.swift "$1" Verbatim | grep -vE 'Views/Tokens.swift|Views/MacAppearance.swift|Model/MotionRules.swift' | wc -l | tr -d ' '; }
ratchet() {  # name, pattern, baseline
  local n; n=$(mac_count "$2")
  if [ "$n" -gt "$3" ]; then
    report "$1: $n in the Mac app, more than the $3 allowed (use the tokens; see DESIGN.md §5.3, §7, §13):" "$(grep -rnE --include=*.swift "$2" Verbatim | grep -vE 'Views/Tokens.swift|Views/MacAppearance.swift|Model/MotionRules.swift' | cut -d: -f1,2 | tail -5)"
  elif [ "$n" -lt "$3" ]; then
    echo "brand-check: note: $1 went down to $n (baseline $3); lower the baseline in tools/brand-check.sh"
  fi
}
ratchet "Literal serif fonts (use Refined.serif or a kit role)" 'design: \.serif\)' 2
ratchet "Literal font sizes (use refinedFont)" '\.system\(size:' 319
ratchet "Literal corner radii (use RefinedRules.radius or Radius)" 'cornerRadius: [0-9]' 33
ratchet "Literal animation curves (use the Motion tokens)" '\.(easeOut|easeIn|easeInOut|linear|smooth|snappy|bouncy)\(duration: [0-9]|\.spring\((duration|response): [0-9]' 14
# 9. Radius numbers on the widgets, keyboard, and watch.
radii=$(grep -rnE --include=*.swift 'cornerRadius: *[0-9]' VerbatimWidgets VerbatimMacWidgets VerbatimKeyboard VerbatimWatch VerbatimWatchWidgets 2>/dev/null | cut -d: -f1,2)
[ -n "$radii" ] && report "Radius numbers on the widgets, keyboard, or watch (use Radius or SurfaceRadius, DESIGN.md §5.3):" "$radii"

[ $fail -eq 0 ] && echo "brand-check: OK"
exit $fail

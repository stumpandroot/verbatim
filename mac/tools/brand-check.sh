#!/usr/bin/env bash
# Brand check: fails when Swift code breaks the [checked] rules in mac/DESIGN.md.
#   1. SF Symbols outside the allowlist (DESIGN.md §3); system surfaces may mark a line `// brand: system surface`
#   2. Colors outside Tokens.swift: hex literals in color calls and system color names (§1)
#   3. Materials or glass (§5): allowed only on a line marked `// brand: glass ok (no text)`
#   4. The retired V mark, BrandArt.mark (§4)
#   5. Mono under 12 pt in files marked `// brand: web style` (§2.2, §11)
# Native look code (DESIGN.md §13) is stock Apple: checks 1, 2's system color names, 3, and 5 skip it. Mark a whole
# file with `// brand: native file`, a block between `// brand: native begin` and `// brand: native end`, or one line
# with a trailing `// brand: native`. Hex colors stay in Tokens.swift and the retired mark stays retired everywhere.
# Run from anywhere: bash mac/tools/brand-check.sh   (exit 1 lists each problem as file:line)
set -u
cd "$(dirname "$0")/.." || exit 2
DIRS="Verbatim VerbatimPhone VerbatimKeyboard VerbatimShare VerbatimWidgets"
SRC=$(for d in $DIRS; do [ -d "$d" ] && echo "$d"; done)
fail=0
report() { echo "brand-check: $1"; echo "$2" | sed 's/^/  /'; echo; fail=1; }

# Every file:line inside Native look code (see the header), one per line.
NATIVE=$(grep -rlE --include=*.swift '// brand: native' $SRC | while IFS= read -r f; do
  awk -v f="$f" '
    /^[[:space:]]*\/\/ brand: native file[[:space:]]*$/ { whole = 1 }
    { lines[NR] = $0 }
    END {
      on = 0
      for (i = 1; i <= NR; i++) {
        l = lines[i]
        if (l ~ /\/\/ brand: native begin/) on = 1
        if (whole || on || l ~ /\/\/ brand: native[[:space:]]*$/) print f ":" i
        if (l ~ /\/\/ brand: native end/) on = 0
      }
    }' "$f"
done)
# Drops lines (file:line, or file:line followed by more) that sit in Native look code.
skip_native() {
  if [ -z "$NATIVE" ]; then cat; return; fi
  awk -v list="$NATIVE" 'BEGIN { n = split(list, a, "\n"); for (i = 1; i <= n; i++) skip[a[i]] = 1 }
    { split($0, p, ":"); k = p[1] ":" p[2]; sub(/[[:space:]].*/, "", k); if (!(k in skip)) print }'
}

ALLOWED='^(xmark|xmark\.circle\.fill|plus|plus\.circle|minus\.circle|chevron\..*|checkmark|checkmark\.circle\.fill|ellipsis|ellipsis\.circle|square\.and\.arrow\.up|trash|magnifyingglass|sidebar\.left|line\.3\.horizontal|arrow\.right|arrow\.up\.arrow\.down|arrow\.uturn\.backward|arrow\.counterclockwise|return|delete\.left|globe|keyboard|shift|shift\.fill|capslock\.fill)$'
syms=$(grep -rnoE --include=*.swift '(systemName|systemImage): *"[^"]+"' $SRC \
  | awk -F: '{ n=$0; sub(/.*: *"/, "", n); sub(/"$/, "", n); print $1 ":" $2 "  " n }' \
  | while IFS= read -r l; do echo "${l##*  }" | grep -qE "$ALLOWED" && continue; f=${l%%:*}; n=${l#*:}; n=${n%%  *}; sed -n "${n}p" "$f" | grep -q 'brand: system surface' || echo "$l"; done | skip_native)
[ -n "$syms" ] && report "SF Symbols not on the DESIGN.md §3 allowlist (use a BrandArt glyph):" "$syms"

hex=$(grep -rnE --include=*.swift '(hex: *0x[0-9A-Fa-f]{6}|Color\(red:|Color\(\.sRGB|UIColor\(red:|NSColor\(red:|NSColor\(calibratedRed:)' $SRC | grep -v 'Views/Tokens.swift' | cut -d: -f1,2)
[ -n "$hex" ] && report "Colors outside Tokens.swift (add or use an Ink token):" "$hex"

sys=$(grep -rnE --include=*.swift '(Color\.|foregroundStyle\(\.|foregroundColor\(\.|tint\(\.|fill\(\.|background\(\.)(red|blue|orange|green|gray|grey|purple|pink|yellow|teal|indigo|mint|cyan|brown|accentColor)\b' $SRC | grep -v 'Views/Tokens.swift' | cut -d: -f1,2 | skip_native)
[ -n "$sys" ] && report "System color names (use Ink tokens; errors use Ink.danger):" "$sys"

glass=$(grep -rnE --include=*.swift '\.(ultraThinMaterial|thinMaterial|regularMaterial|thickMaterial|ultraThickMaterial|bar)\b|glassEffect\(' $SRC | grep -E 'Material|glassEffect' | grep -v 'brand: glass ok' | cut -d: -f1,2 | skip_native)
[ -n "$glass" ] && report "Material or glass without '// brand: glass ok (no text)' (never put text on blur):" "$glass"

mark=$(grep -rnE --include=*.swift 'BrandArt\.mark\b|art: *\.mark\b' $SRC | grep -v 'Views/Brand.swift' | cut -d: -f1,2)
[ -n "$mark" ] && report "The retired V mark (use the bars mark):" "$mark"

#   5. Website style (§2.2, §11): in files marked `// brand: web style`, mono text is 12 pt or larger
webfiles=$(grep -rlE --include=*.swift '^// brand: web style' $SRC)
if [ -n "$webfiles" ]; then
  small=$(grep -nE '(Ink\.mono|lookMono)\(([0-9]|1[01])(\.[0-9]+)?[,)]|Overline\(' $webfiles | cut -d: -f1,2)
  keys=$(grep -nE 'Keycap\(' $webfiles | grep -vE 'Keycap\([^)]*size: *(1[2-9]|[2-9][0-9])' | grep -vE 'struct Keycap|Keycap\.spoken' | cut -d: -f1,2)
  small=$(echo "$small" | sed '/^$/d' | skip_native); keys=$(echo "$keys" | sed '/^$/d' | skip_native)
  [ -n "$small$keys" ] && report "Mono under 12 pt in a web-style file (use Ink.mono(12) or larger, Keycap(size: 12)):" "$(printf '%s\n%s' "$small" "$keys" | sed '/^$/d')"
fi

[ $fail -eq 0 ] && echo "brand-check: OK"
exit $fail

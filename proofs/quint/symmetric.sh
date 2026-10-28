#!/usr/bin/env bash
# THIS WAS BUILT BY CLAUDE OPUS and it is not verified.
#
# symmetric.sh FILE MAIN ELEMENT... [-- TLC-ARG...]
#
# Checks the invariant `inv` of instance MAIN in FILE with TLC under SYMMETRY
# over the set {ELEMENT...}. The Quint TLC backend passes no SYMMETRY, and TLC
# permutes only model values, so the compiled module's string literals
# "ELEMENT" become model-value constants of the same name.
#
# Environment: OUT (output directory, default a fresh temporary one), WORKERS
# (default 4), INV (default inv), NOSYM=1 (rewrite but omit SYMMETRY, to
# compare the state count with `quint verify`), JAR (default Quint's Apalache
# JAR, which bundles TLC).
set -euo pipefail

[ $# -ge 3 ] || { sed -n '4p' "$0" >&2; exit 64; }
FILE=$1; MAIN=$2; shift 2
ELEMS=()
while [ $# -gt 0 ] && [ "$1" != "--" ]; do ELEMS+=("$1"); shift; done
[ "${1:-}" = "--" ] && shift

OUT=${OUT:-$(mktemp -d)}
mkdir -p "$OUT"
JAR=${JAR:-$(ls "$HOME"/.quint/apalache-dist-*/apalache/lib/apalache.jar | tail -1)}

quint compile --target tlaplus --main "$MAIN" "$FILE" |
    sed -n '/^-* MODULE/,$p' >"$OUT/raw.tla"
tail -1 "$OUT/raw.tla" | grep -q '^====' || {
    echo "symmetric.sh: quint compile produced no module" >&2
    exit 65
}

python3 -I - "$OUT/raw.tla" "$OUT/$MAIN.tla" "${NOSYM:-}" "${ELEMS[@]}" <<'EOF'
import re, sys
src, dst, nosym, elems = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
text = open(src).read()
for e in elems:
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9]*", e):
        sys.exit(f"symmetric.sh: {e!r} is not a TLA+ identifier")
    if re.search(rf'(?<!["\w]){e}(?!["\w])', text):
        sys.exit(f"symmetric.sh: {e} already names something in the module")
    if f'"{e}"' not in text:
        sys.exit(f'symmetric.sh: no literal "{e}" in the module')
    text = text.replace(f'"{e}"', e)
names = ", ".join(elems)
decl = f"CONSTANTS {names}\n\nSym == Permutations({{ {names} }})\n"
text, n = re.subn(r"^(EXTENDS [^\n]*\bTLC\b[^\n]*\n)", rf"\1\n{decl}", text,
                  count=1, flags=re.M)
if n != 1:
    sys.exit("symmetric.sh: no EXTENDS line naming TLC")
open(dst, "w").write(text)
EOF

{
    printf 'CONSTANTS\n'
    for e in "${ELEMS[@]}"; do printf '    %s = %s\n' "$e" "$e"; done
    printf 'INIT q_init\nNEXT q_step\nINVARIANT %s\n' "${INV:-inv}"
    [ -n "${NOSYM:-}" ] || printf 'SYMMETRY Sym\n'
    printf 'CHECK_DEADLOCK FALSE\n'
} >"$OUT/$MAIN.cfg"

cd "$OUT"
exec java -XX:+UseParallelGC -cp "$JAR" tlc2.TLC \
    -workers "${WORKERS:-4}" -metadir "$OUT/states" \
    -config "$MAIN.cfg" "$@" "$MAIN.tla"

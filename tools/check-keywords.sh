#!/usr/bin/env bash
# Compare the vernacular keyword list in lib/highlight.ml against IDENT
# strings declared in Rocq's grammar (.mlg) files. Prints candidates to
# add and possibly-stale entries.
#
# Usage: tools/check-keywords.sh [path-to-rocq-sources]
# Default: auto-locate ~/.opam/<switch>/.opam-switch/sources/rocq-runtime*

set -euo pipefail

ROOT="${1:-}"
if [[ -z "$ROOT" ]]; then
  ROOT="$(ls -d ~/.opam/*/.opam-switch/sources/rocq-runtime* 2>/dev/null | sort -V | tail -1)"
fi

if [[ -z "$ROOT" || ! -d "$ROOT" ]]; then
  echo "error: could not locate rocq-runtime sources" >&2
  echo "  pass the path explicitly, e.g.:" >&2
  echo "    $0 ~/.opam/rocq/.opam-switch/sources/rocq-runtime.9.1.1" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HIGHLIGHT="$SCRIPT_DIR/../lib/highlight.ml"

# Capitalized keywords at the *start* of a .mlg grammar alternative —
# i.e. lines beginning with `|` or `[` (alt separator / first alternative),
# followed optionally by `IDENT` and then the quoted keyword. This excludes
# sub-keywords like `On`, `Off`, `Sorted` that appear only mid-production
# inside compound vernacs (e.g. `Set Printing Diff On`). Matches both
# `IDENT "Foo"` (identifier-position) and bare `"Foo"` (lexer tokens like
# Theorem/Definition).
mlg_keys=$(grep -rhE '^[[:space:]]*[|[][^"]*"[A-Z][A-Za-z_0-9]*"' "$ROOT" --include='*.mlg' \
  --exclude-dir=test-suite --exclude-dir=plugin_tutorial \
  | sed -E 's/^[[:space:]]*[|[][^"]*"([A-Z][A-Za-z_0-9]*)".*/\1/' \
  | sort -u)

# Extract entries from the `vernac_keywords` list in highlight.ml.
hl_keys=$(awk '
  /^let vernac_keywords / { capture = 1; next }
  capture && /^]/         { exit }
  capture                  { print }
' "$HIGHLIGHT" \
  | grep -o '"[A-Z][A-Za-z_0-9]*"' \
  | tr -d '"' \
  | sort -u)

echo "rocq sources: $ROOT"
echo
echo "== In .mlg, not in highlight.ml (candidates to add):"
comm -23 <(echo "$mlg_keys") <(echo "$hl_keys")
echo
echo "== In highlight.ml, not in .mlg (plugin-defined or possibly stale):"
comm -13 <(echo "$mlg_keys") <(echo "$hl_keys")

#!/usr/bin/env bash
# strip-lua-comments.sh
# Strip comments from Lua source files using an awk state machine.
# Handles strings correctly (single, double, long brackets).
#
# Usage:
#   ./strip-lua-comments.sh input.lua     (stdout)
#   ./strip-lua-comments.sh --dir plugin/ (in-place)
#   ./strip-lua-comments.sh --install     (install awk helper to repo)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
AWK_SCRIPT="$SCRIPT_DIR/.strip-lua-comments.awk"

install_awk() {
  cat > "$AWK_SCRIPT" << 'AWKEOF'
function level(s, i) {
  c = substr(s, i, 1)
  if (c != "[" && c != "]") return -1
  n = 0; j = i + 1
  ch = substr(s, j, 1)
  while (ch == "=") { n++; j++; ch = substr(s, j, 1) }
  if (substr(s, j, 1) != c) return -1
  return n
}

{
  line = $0
  result = ""
  i = 1
  len = length(line)

  while (i <= len) {
    ch = substr(line, i, 1)
    nxt = substr(line, i+1, 1)

    # Line comment
    if (state == 0 && ch == "-" && nxt == "-") {
      bl = level(line, i+2)
      if (bl >= 0) {
        # Block comment start
        nopen[++nstack] = bl
        origstate = state
        state = 4
        i = i + 4 + bl
        continue
      }
      # Single-line comment: skip rest of line
      break
    }

    # Inside block comment
    if (state == 4) {
      bl = level(line, i)
      if (bl >= 0) {
        if (substr(line, i, 1) == "]" && nstack > 0 && nopen[nstack] == bl) {
          nstack--
          if (nstack == 0) {
            state = origstate
            i = i + 2 + bl
            continue
          }
        }
        # No match - still inside
      }
      i++
      continue
    }

    # Short strings
    if (ch == "'" || ch == "\"") {
      result = result ch
      q = ch
      i++
      while (i <= len) {
        c = substr(line, i, 1)
        result = result c
        if (c == "\\") { i++; result = result substr(line, i, 1) }
        else if (c == q) { i++; break }
        i++
      }
      continue
    }

    # Long strings
    bl = level(line, i)
    if (bl >= 0 && substr(line, i, 1) == "[") {
      ol = 2 + bl
      for (j = i; j < i+ol; j++) result = result substr(line, j, 1)
      i = i + ol
      cl = ""
      for (j = 0; j < bl; j++) cl = cl "="
      cl = "]" cl "]"
      cln = length(cl)
      while (i <= len) {
        if (substr(line, i, cln) == cl) {
          for (j = i; j < i+cln; j++) result = result substr(line, j, 1)
          i = i + cln
          break
        }
        result = result substr(line, i, 1)
        i++
      }
      continue
    }

    # Normal
    result = result ch
    i++
  }
  print result
}
AWKEOF
  echo "Installed: $AWK_SCRIPT" >&2
}

if [ ! -f "$AWK_SCRIPT" ]; then
  install_awk
fi

strip_file() {
  local infile="$1"
  local inplace="$2"
  awk -f "$AWK_SCRIPT" "$infile" > "${infile}.stripped"
  if [ "$inplace" = "1" ]; then
    mv "${infile}.stripped" "$infile"
  else
    cat "${infile}.stripped"
    rm "${infile}.stripped"
  fi
}

# -- Main ----------------------------------------------------------------
if [ $# -eq 0 ]; then
  echo "Usage: $0 <file.lua>"
  echo "       $0 --dir <directory>"
  echo "       $0 --install"
  exit 1
fi

if [ "$1" = "--install" ]; then
  install_awk
  exit 0
fi

if [ "$1" = "--dir" ]; then
  dir="$2"
  [ -z "$dir" ] && { echo "ERROR: --dir requires a path" >&2; exit 1; }
  count=0
  while IFS= read -r -d '' file; do
    if echo "$file" | grep -q '/locale/'; then continue; fi
    echo "  $file" >&2
    strip_file "$file" "1" && count=$((count + 1))
  done < <(find "$dir" -name '*.lua' -type f -print0)
  echo "Processed $count files" >&2
  exit 0
fi

infile="$1"
[ ! -f "$infile" ] && { echo "ERROR: File not found: $infile" >&2; exit 1; }
strip_file "$infile" "0"

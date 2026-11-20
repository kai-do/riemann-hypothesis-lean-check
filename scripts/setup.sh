#!/usr/bin/env bash
# Download the 14 archive parts, verify the pinned checksum, and extract read-only into lean/.
#
#   scripts/setup.sh          # idempotent: skips extraction if lean/ is already set up
#   scripts/setup.sh --force  # wipe lean/ (including any build) and re-extract
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DL="$ROOT/downloads"
WORK="$ROOT/.check"
ARCHIVE="$WORK/lean.tar.gz"
SUMS="$WORK/lean.sha256sums"
BASE_URL="https://alpo.ge"
PARTS=14
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

mkdir -p "$DL" "$WORK"

if [ "$FORCE" = 0 ] && [ -f "$SUMS" ] && [ -d "$ROOT/lean/src" ]; then
  echo "lean/ already set up; verifying instead of re-extracting (use --force to redo)."
  ( cd "$ROOT/lean" && sha256sum -c --quiet "$SUMS" )
  echo "All $(wc -l < "$SUMS") files match."
  exit 0
fi

# 1. Download any missing parts (re-run to resume).
for i in $(seq -w 1 $PARTS); do
  part="$DL/lean.tar.gz.part$i"
  if [ ! -s "$part" ]; then
    echo "Downloading part $i/$PARTS"
    curl -fSL --retry 5 --retry-delay 5 -o "$part.tmp" "$BASE_URL/lean.tar.gz.part$i"
    mv "$part.tmp" "$part"
  fi
done

# 2. Reassemble and verify against the checksum committed in ARCHIVE.sha256.
cat $(for i in $(seq -w 1 $PARTS); do echo "$DL/lean.tar.gz.part$i"; done) > "$ARCHIVE"
expected="$(cut -d' ' -f1 "$ROOT/ARCHIVE.sha256")"
actual="$(sha256sum "$ARCHIVE" | cut -d' ' -f1)"
if [ "$expected" != "$actual" ]; then
  echo "Archive checksum mismatch: expected $expected, got $actual" >&2
  echo "Delete downloads/ and re-run to fetch fresh copies." >&2
  exit 1
fi
echo "Archive checksum OK ($actual)"

# 3. Refuse archives with entries outside lean/, path traversal, or non-regular files.
if tar -tzf "$ARCHIVE" | grep -qvE '^lean/' || tar -tzf "$ARCHIVE" | grep -q '\.\.'; then
  echo "Archive contains unexpected paths; refusing to extract." >&2
  exit 1
fi
if tar -tvzf "$ARCHIVE" | cut -c1 | grep -qv '[-d]'; then
  echo "Archive contains links or special files; refusing to extract." >&2
  exit 1
fi

# 4. Fresh extraction.
if [ -d "$ROOT/lean" ]; then
  chmod -R u+w "$ROOT/lean"
  rm -rf "$ROOT/lean"
fi
tar -xzf "$ARCHIVE" -C "$ROOT"

# 5. Record per-file hashes, then make every shipped file read-only.
( cd "$ROOT/lean" && find . -path ./.lake -prune -o -type f -print0 | sort -z | xargs -0 sha256sum ) > "$SUMS"
find "$ROOT/lean" -path "$ROOT/lean/.lake" -prune -o -type f -exec chmod a-w {} +
echo "Extracted $(wc -l < "$SUMS") files into lean/ (read-only)."

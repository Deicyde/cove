#!/usr/bin/env bash
# Build cove/bin/abduco: abduco 0.6 with abduco-no-altscreen.patch applied.
# Stock abduco switches kitty to the alternate screen on every attach, which has
# no scrollback, so the wheel did nothing in codex/shell termlings. The patched
# client stays on the main screen; kitty then scrolls its scrollback as normal.
# The binary is arm64 macOS and syncs to the pro with the rest of cove/.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
brew fetch --build-from-source abduco >/dev/null
TARBALL="$(brew --cache --build-from-source abduco)"
SRC="$(mktemp -d)"
trap 'rm -rf "$SRC"' EXIT
tar xzf "$TARBALL" -C "$SRC" --strip-components=1
(cd "$SRC" && patch -p0 client.c < "$HERE/abduco-no-altscreen.patch" && CFLAGS="-D_DARWIN_C_SOURCE -O2" make abduco >/dev/null)
mkdir -p "$HERE/bin"
cp "$SRC/abduco" "$HERE/bin/abduco"
echo "built $HERE/bin/abduco"

#!/usr/bin/env bash
# Symlink bin/ipa-install-on-mac into ~/.local/bin, so it is on PATH the way
# any other user-installed CLI is. A symlink, not a copy: the script resolves
# its own real location through the link at run time to find lib/ beside it
# (see bin/ipa-install-on-mac's LIB_DIR resolution), so this is the supported
# way to install it, and the checkout can be updated (git pull) in place.
#
# Usage: install.sh [--bin-dir DIR]     link (default DIR: ~/.local/bin)
#        install.sh --uninstall [--bin-dir DIR]

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$DIR/bin/ipa-install-on-mac"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
UNINSTALL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --uninstall) UNINSTALL=1; shift ;;
    --bin-dir)
      [ $# -ge 2 ] || { echo "install.sh: --bin-dir needs a value" >&2; exit 1; }
      BIN_DIR="$2"; shift 2 ;;
    -h|--help) echo "Usage: install.sh [--bin-dir DIR] | --uninstall [--bin-dir DIR]"; exit 0 ;;
    *) echo "install.sh: unknown argument: $1" >&2; exit 1 ;;
  esac
done

LINK="$BIN_DIR/ipa-install-on-mac"

if [ "$UNINSTALL" -eq 1 ]; then
  if [ -L "$LINK" ] && [ "$(readlink "$LINK")" = "$SRC" ]; then
    rm -f "$LINK"
    echo "Removed $LINK"
  elif [ -e "$LINK" ]; then
    echo "install.sh: $LINK does not point at this checkout ($SRC); leaving it" >&2
    exit 1
  else
    echo "install.sh: $LINK does not exist; nothing to do"
  fi
  exit 0
fi

[ -x "$SRC" ] || chmod +x "$SRC"
mkdir -p "$BIN_DIR"
ln -sf "$SRC" "$LINK"
echo "Linked $LINK -> $SRC"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "Note: $BIN_DIR is not on your PATH; add it in your shell's profile." ;;
esac

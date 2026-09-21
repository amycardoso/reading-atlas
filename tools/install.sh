#!/bin/sh
# Copy Reading Atlas into a KOReader settings directory.
#
#   sh tools/install.sh /mnt/onboard/.adds/koreader/settings      # Kobo
#   sh tools/install.sh /mnt/us/koreader/settings                 # Kindle
#
# The target is KOReader's SETTINGS dir, not its plugins dir: bookshelf scans
# <settings>/bookshelf/micromodules/ for user modules, and that location
# survives bookshelf updates.
set -e

SETTINGS="$1"
if [ -z "$SETTINGS" ]; then
    echo "usage: sh tools/install.sh <koreader-settings-dir>" >&2
    exit 2
fi
if [ ! -d "$SETTINGS" ]; then
    echo "not a directory: $SETTINGS" >&2
    exit 2
fi

# Resolve to an absolute path now, before anything below cd's the shell to
# the repo root: a relative $SETTINGS would otherwise resolve against two
# different working directories between mkdir and cp.
SETTINGS="$(cd "$SETTINGS" && pwd)"

DEST="$SETTINGS/bookshelf/micromodules"
mkdir -p "$DEST/atlas"

cd "$(dirname "$0")/.."
cp micromodules/atlas_heatmap.lua micromodules/atlas_clock.lua "$DEST/"
cp micromodules/atlas/*.lua "$DEST/atlas/"

echo "installed to $DEST"
echo "restart KOReader, then add the modules from the bookshelf module picker."

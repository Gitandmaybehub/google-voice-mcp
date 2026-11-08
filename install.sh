#!/bin/bash
# Builds gvoice and puts it on this Mac's PATH. Run it again after any code change.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --product gvoice
mkdir -p bin
# Swap the file in one step, so an MCP server already running keeps its copy until it restarts.
cp -f .build/release/gvoice bin/gvoice.new
mv -f bin/gvoice.new bin/gvoice
DEST=/opt/homebrew/bin
[ -d "$DEST" ] || DEST=/usr/local/bin
ln -sfn "$PWD/bin/gvoice" "$DEST/gvoice"

echo "Installed $("$DEST/gvoice" --version --output pretty) at $DEST/gvoice"

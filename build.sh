#!/bin/bash
# Packages the plugin into the format DirectAdmin expects.
# Files are at the tarball root — DA extracts them into the plugin directory itself.
#
#   da_dnssec_sync_manager.tar.gz
#   ├── plugin.conf
#   ├── admin/
#   ├── reseller/
#   ├── exec/
#   ├── hooks/
#   ├── sync/
#   │   └── da-odr-dnssec-sync.sh
#   ├── scripts/
#   │   ├── install.sh
#   │   ├── uninstall.sh
#   │   └── update.sh
#   └── images/

set -e

PLUGIN_ID="da_dnssec_sync_manager"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Local builds write to build/ (gitignored). The release workflow copies it
# from there to the repo root before publishing, so the tracked tarball at
# the root is only ever written by CI — local rebuilds don't dirty git.
BUILD_DIR="${BUILD_DIR:-$SCRIPT_DIR/build}"
OUTPUT="$BUILD_DIR/${PLUGIN_ID}.tar.gz"
mkdir -p "$BUILD_DIR"
TMPDIR="$(mktemp -d)"

cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

cp -r \
    "$SCRIPT_DIR/admin" \
    "$SCRIPT_DIR/reseller" \
    "$SCRIPT_DIR/exec" \
    "$SCRIPT_DIR/hooks" \
    "$SCRIPT_DIR/sync" \
    "$SCRIPT_DIR/scripts" \
    "$SCRIPT_DIR/images" \
    "$SCRIPT_DIR/plugin.conf" \
    "$SCRIPT_DIR/version.html" \
    "$TMPDIR/"

find "$TMPDIR" -name '.DS_Store' -delete
find "$TMPDIR" -name '.gitkeep' -delete

tar -czf "$OUTPUT" -C "$TMPDIR" .

echo "Built: $OUTPUT"

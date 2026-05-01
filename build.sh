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
OUTPUT="${PLUGIN_ID}.tar.gz"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
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

tar -czf "$SCRIPT_DIR/$OUTPUT" -C "$TMPDIR" .

echo "Built: $OUTPUT"

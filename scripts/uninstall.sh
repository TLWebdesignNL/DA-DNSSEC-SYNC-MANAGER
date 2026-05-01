#!/bin/bash

PLUGIN_PATH="/usr/local/directadmin/plugins/da_dnssec_sync_manager"
SYNC_SCRIPT_PATH="/usr/local/directadmin/scripts/custom/da-odr-dnssec-sync.sh"
HOOK_PATH="/usr/local/directadmin/scripts/custom/dnssec_sign_post.sh"
BACKUP_FILE="/usr/local/directadmin/plugins/da_dnssec_sync_manager_excluded_backup.txt"
MARKER="# managed-by: da_dnssec_sync_manager"

# Back up excluded.txt before removing data directory
if [ -f "$PLUGIN_PATH/data/excluded.txt" ]; then
    cp "$PLUGIN_PATH/data/excluded.txt" "$BACKUP_FILE"
    echo "Exclusion list backed up to $BACKUP_FILE"
fi

if [ -d "$PLUGIN_PATH/data" ]; then
    rm -rf "$PLUGIN_PATH/data"
fi

# Remove the sync script
if [ -f "$SYNC_SCRIPT_PATH" ]; then
    rm -f "$SYNC_SCRIPT_PATH"
    echo "Sync script removed."
fi

# Remove the post-hook only if it is managed by this plugin
if [ -f "$HOOK_PATH" ] && grep -q "$MARKER" "$HOOK_PATH" 2>/dev/null; then
    rm -f "$HOOK_PATH"
    echo "Post-hook removed."
fi

echo "DA DNSSEC Sync Manager uninstalled."
exit 0

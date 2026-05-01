#!/bin/bash
# Runs when the plugin is updated via the DirectAdmin GUI.
# Also updates the ODR DNSSEC sync script from the bundled version in the plugin package.

PLUGIN_PATH="/usr/local/directadmin/plugins/da_dnssec_sync_manager"
SYNC_SCRIPT_PATH="/usr/local/directadmin/scripts/custom/da-odr-dnssec-sync.sh"

# Reapply ownership and permissions
chown -R diradmin:diradmin "$PLUGIN_PATH"
find "$PLUGIN_PATH" -type d -exec chmod 755 {} \;
find "$PLUGIN_PATH" -type f -exec chmod 644 {} \;

chmod 755 "$PLUGIN_PATH/scripts/install.sh"
chmod 755 "$PLUGIN_PATH/scripts/uninstall.sh"
chmod 755 "$PLUGIN_PATH/scripts/update.sh"

for dir in admin reseller; do
    if [ -d "$PLUGIN_PATH/$dir" ]; then
        chmod 755 "$PLUGIN_PATH/$dir/"*
    fi
done

# Update the sync script only if it is already installed — never auto-install
if [ -f "$SYNC_SCRIPT_PATH" ]; then
    if [ -f "$PLUGIN_PATH/sync/da-odr-dnssec-sync.sh" ]; then
        cp "$PLUGIN_PATH/sync/da-odr-dnssec-sync.sh" "$SYNC_SCRIPT_PATH"
        chmod 755 "$SYNC_SCRIPT_PATH"
        chown diradmin:diradmin "$SYNC_SCRIPT_PATH"
        echo "Sync script updated successfully."
    else
        echo "Warning: Bundled sync script not found in plugin package. Manual update may be required."
    fi
else
    echo "Sync script not found at $SYNC_SCRIPT_PATH — skipping (not installed on this server)."
fi

echo "DA DNSSEC Sync Manager updated successfully."
exit 0

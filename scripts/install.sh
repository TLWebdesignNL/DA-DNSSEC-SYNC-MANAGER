#!/bin/bash

PLUGIN_PATH="/usr/local/directadmin/plugins/da_dnssec_sync_manager"
CUSTOM_PATH="/usr/local/directadmin/scripts/custom"
SYNC_SCRIPT_PATH="$CUSTOM_PATH/da-odr-dnssec-sync.sh"
HOOK_PATH="$CUSTOM_PATH/dnssec_sign_post.sh"
MARKER="# managed-by: da_dnssec_sync_manager"

# Verify diradmin user exists before attempting chown
if ! id "diradmin" &>/dev/null; then
    echo "Error: diradmin user not found. Aborting install."
    exit 1
fi

# Apply ownership and permissions to plugin files
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

# Create plugin data directory and runtime files
mkdir -p "$PLUGIN_PATH/data"
chown diradmin:diradmin "$PLUGIN_PATH/data"
chmod 755 "$PLUGIN_PATH/data"

if [ ! -f "$PLUGIN_PATH/data/excluded.txt" ]; then
    touch "$PLUGIN_PATH/data/excluded.txt"
    chown diradmin:diradmin "$PLUGIN_PATH/data/excluded.txt"
    chmod 644 "$PLUGIN_PATH/data/excluded.txt"
fi

# Create credentials directory (chmod 700 — contains per-reseller API keys)
mkdir -p "$PLUGIN_PATH/data/credentials"
chown diradmin:diradmin "$PLUGIN_PATH/data/credentials"
chmod 700 "$PLUGIN_PATH/data/credentials"

# Seed TLD exception list with the defaults previously hardcoded in the sync script
if [ ! -f "$PLUGIN_PATH/data/tld_exceptions.txt" ]; then
    printf 'com\ncare\n' > "$PLUGIN_PATH/data/tld_exceptions.txt"
    chown diradmin:diradmin "$PLUGIN_PATH/data/tld_exceptions.txt"
    chmod 644 "$PLUGIN_PATH/data/tld_exceptions.txt"
fi

# Copy the bundled DNSSEC sync script into the DA custom scripts folder
mkdir -p "$CUSTOM_PATH"
if [ -f "$PLUGIN_PATH/sync/da-odr-dnssec-sync.sh" ]; then
    cp "$PLUGIN_PATH/sync/da-odr-dnssec-sync.sh" "$SYNC_SCRIPT_PATH"
    chmod 755 "$SYNC_SCRIPT_PATH"
    chown diradmin:diradmin "$SYNC_SCRIPT_PATH"
    echo "Sync script installed at $SYNC_SCRIPT_PATH"
else
    echo "Warning: Bundled sync script not found in plugin package. Install it manually at:"
    echo "  $SYNC_SCRIPT_PATH"
fi

# Create or update dnssec_sign_post.sh:
#   1. Doesn't exist          → create our managed wrapper
#   2. Has our marker         → managed by us, rewrite it
#   3. Already calls our script (no marker) → already set up, leave it
#   4. Exists, custom, no call to our script → append our call at the bottom
if [ ! -f "$HOOK_PATH" ]; then
    cat > "$HOOK_PATH" <<EOF
#!/bin/bash
$MARKER
bash $SYNC_SCRIPT_PATH
EOF
    chmod 755 "$HOOK_PATH"
    chown diradmin:diradmin "$HOOK_PATH"
    echo "Post-hook created at $HOOK_PATH"
elif grep -q "$MARKER" "$HOOK_PATH" 2>/dev/null; then
    cat > "$HOOK_PATH" <<EOF
#!/bin/bash
$MARKER
bash $SYNC_SCRIPT_PATH
EOF
    chmod 755 "$HOOK_PATH"
    chown diradmin:diradmin "$HOOK_PATH"
    echo "Post-hook updated at $HOOK_PATH"
elif grep -q "da-odr-dnssec-sync.sh" "$HOOK_PATH" 2>/dev/null; then
    echo "Post-hook already calls the sync script — no changes made to $HOOK_PATH"
else
    printf '\n# Added by da_dnssec_sync_manager\nbash %s\n' "$SYNC_SCRIPT_PATH" >> "$HOOK_PATH"
    echo "Appended sync script call to existing $HOOK_PATH"
fi

echo "DA DNSSEC Sync Manager installed successfully."
exit 0

#!/bin/bash
# *******************************************************************************
#* @file        da-odr-dnssec-sync.sh
#*
#* @brief       DNSSEC sync core — routes to the correct registrar module
#*
#* @details     Handles domain detection, key file reading, owner/reseller lookup,
#*              exclusion check, and credentials loading. The registrar-specific
#*              API logic lives in sync/registrars/<registrar>.sh.
#*
#* @author      Tom van der Laan - TLWebdesign.nl
#* @contact     info@tlwebdesign.nl
#* @website     https://tlwebdesign.nl
#* @version     4.0.0
#* @copyright   GNU General Public License version 3 or later
#*
#* @date        2024-07-03
#*
#*******************************************************************************

LOGFILE="/var/log/da-odr-dnssec-sync.log"
exec > >(tee -a "$LOGFILE") 2>&1

echo "//////////////////////////$(date)//////////////////////////"
echo "START OF DNSSEC SYNC"
echo "///////////////////////////////////////////////"

PLUGIN_PATH="/usr/local/directadmin/plugins/da_dnssec_sync_manager"
ADMINUSERNAME=$(grep -m1 "^adminuser=" /usr/local/directadmin/conf/directadmin.conf 2>/dev/null | cut -d= -f2)
ADMINUSERNAME="${ADMINUSERNAME:-admin}"

#------------------------------------------------
# SHARED FUNCTIONS
#------------------------------------------------
write_status() {
    local domain="$1"
    local status="$2"
    local owner="${3:-}"
    local reseller="${4:-}"
    local message="$5"
    [ -z "$domain" ] && return
    local dir="$PLUGIN_PATH/data/sync"
    mkdir -p "$dir"
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    jq -n \
        --arg domain    "$domain" \
        --arg last_sync "$ts" \
        --arg status    "$status" \
        --arg owner     "$owner" \
        --arg reseller  "$reseller" \
        --arg message   "$message" \
        '{domain:$domain,last_sync:$last_sync,status:$status,owner:$owner,reseller:$reseller,message:$message}' \
        > "$dir/${domain}.json"
    chown diradmin:diradmin "$dir/${domain}.json" 2>/dev/null
    chmod 644 "$dir/${domain}.json"
}

send_notification() {
    local user="$1"
    local subject="$2"
    local message="$3"
    echo "action=notify&value=users&subject=$subject&message=$message&users=select1=$user" \
        >> /usr/local/directadmin/data/task.queue
    echo "Notification sent to $user"
}

find_domain_owner() {
    local domain="$1"
    for user_dir in /usr/local/directadmin/data/users/*; do
        [ -d "$user_dir" ] || continue
        local user
        user=$(basename "$user_dir")
        if grep -q "^$domain$" "$user_dir/domains.list" 2>/dev/null; then
            echo "$user"
            return
        fi
    done
    for pointer_file in /usr/local/directadmin/data/users/*/domains/*.pointers; do
        if grep -q "^$domain=" "$pointer_file" 2>/dev/null; then
            local owner_domain
            owner_domain=$(basename "$pointer_file" .pointers)
            find_domain_owner "$owner_domain"
            return
        fi
    done
}

find_reseller() {
    local user="$1"
    local conf="/usr/local/directadmin/data/users/$user/user.conf"
    [ -f "$conf" ] && grep -m1 "^creator=" "$conf" | cut -d= -f2
}

is_domain_excluded() {
    local domain="$1"
    local list_file="$2"
    local now
    now=$(date +%s)
    while IFS='|' read -r u d reason added expires rest; do
        [ "$d" != "$domain" ] && continue
        if [ -n "$expires" ]; then
            local exp_epoch
            exp_epoch=$(date -d "$expires" +%s 2>/dev/null)
            [ -n "$exp_epoch" ] && [ "$now" -gt "$exp_epoch" ] && continue
        fi
        return 0
    done < "$list_file"
    return 1
}

is_exception_domain() {
    local domain="$1"
    local parts
    IFS='.' read -ra parts <<< "$domain"
    local extension=""
    if [ ${#parts[@]} -eq 2 ]; then
        extension="${parts[1]}"
    elif [ ${#parts[@]} -eq 3 ]; then
        extension="${parts[1]}.${parts[2]}"
    fi
    for ext in "${EXCEPTION_DOMAINS[@]}"; do
        [ "$ext" = "$extension" ] && return 0
    done
    return 1
}

#------------------------------------------------
# CHECK DEPENDENCIES
#------------------------------------------------
if ! command -v jq > /dev/null 2>&1; then
    echo "jq is not installed. Please install jq to proceed."
    send_notification "$ADMINUSERNAME" "jq not installed" "The DNSSEC sync script requires jq. Please install it."
    exit 0
fi

#------------------------------------------------
# DETERMINE DOMAIN
#------------------------------------------------
if [ -n "${domain}" ]; then
    echo "DIRECTADMIN DOMAIN SOURCE"
    DOMAIN="${domain}"
elif [ -n "$1" ]; then
    echo "CLI DOMAIN SOURCE"
    DOMAIN="$1"
else
    echo "NO DOMAIN INFORMATION AVAILABLE."
    send_notification "$ADMINUSERNAME" "No domain information available!" "The DNSSEC sync script was triggered but no domain was found."
    exit 0
fi

#------------------------------------------------
# EXCLUSION LIST CHECK
#------------------------------------------------
EXCEPTION_LIST="$PLUGIN_PATH/data/excluded.txt"
if [ -f "$EXCEPTION_LIST" ] && is_domain_excluded "$DOMAIN" "$EXCEPTION_LIST"; then
    echo "Domain $DOMAIN is in the exclusion list. Skipping sync."
    write_status "$DOMAIN" "excluded" "" "" "Domain is in the sync exclusion list"
    exit 0
fi

#------------------------------------------------
# READ ZSK KEY FILE
#------------------------------------------------
ZSK_KEY_FILE="/var/named/${DOMAIN}.zsk.key"
if [ -f "$ZSK_KEY_FILE" ]; then
    ZSK_LINE=$(grep -E 'IN\s+DNSKEY' "$ZSK_KEY_FILE")
    DIRECTADMIN_ZSK_FLAG=$(echo "$ZSK_LINE" | awk '{print $4}')
    DIRECTADMIN_ZSK_ALGORITHM=$(echo "$ZSK_LINE" | awk '{print $6}')
    DIRECTADMIN_ZSK_PUBKEY=$(echo "$ZSK_LINE" | awk '{for (i=7; i<=NF; i++) printf $i; print ""}')
    echo "DA ZSK Flag: $DIRECTADMIN_ZSK_FLAG"
    echo "DA ZSK Algorithm: $DIRECTADMIN_ZSK_ALGORITHM"
    echo "DA ZSK Key: $DIRECTADMIN_ZSK_PUBKEY"
else
    echo "DA ZSK FILE DOES NOT EXIST: $ZSK_KEY_FILE"
    send_notification "$ADMINUSERNAME" "$DOMAIN DOES NOT HAVE DNSSEC ENABLED" "ZSK FILE NOT FOUND: $ZSK_KEY_FILE"
    write_status "$DOMAIN" "error" "" "" "DNSSEC not enabled: ZSK key file not found ($ZSK_KEY_FILE)"
    exit 0
fi

#------------------------------------------------
# READ KSK KEY FILE
#------------------------------------------------
KSK_KEY_FILE="/var/named/${DOMAIN}.ksk.key"
if [ -f "$KSK_KEY_FILE" ]; then
    KSK_LINE=$(grep -E 'IN\s+DNSKEY' "$KSK_KEY_FILE")
    DIRECTADMIN_KSK_FLAG=$(echo "$KSK_LINE" | awk '{print $4}')
    DIRECTADMIN_KSK_ALGORITHM=$(echo "$KSK_LINE" | awk '{print $6}')
    DIRECTADMIN_KSK_PUBKEY=$(echo "$KSK_LINE" | awk '{for (i=7; i<=NF; i++) printf $i; print ""}')
    echo "DA KSK Flag: $DIRECTADMIN_KSK_FLAG"
    echo "DA KSK Algorithm: $DIRECTADMIN_KSK_ALGORITHM"
    echo "DA KSK Key: $DIRECTADMIN_KSK_PUBKEY"
else
    echo "DA KSK FILE DOES NOT EXIST: $KSK_KEY_FILE"
    send_notification "$ADMINUSERNAME" "$DOMAIN DOES NOT HAVE DNSSEC ENABLED" "KSK FILE NOT FOUND: $KSK_KEY_FILE"
    write_status "$DOMAIN" "error" "" "" "DNSSEC not enabled: KSK key file not found ($KSK_KEY_FILE)"
    exit 0
fi

#------------------------------------------------
# FIND DOMAIN OWNER AND RESELLER
#------------------------------------------------
OWNER=$(find_domain_owner "$DOMAIN")
if [ -z "$OWNER" ]; then
    echo "Domain owner not found for: $DOMAIN"
    send_notification "$ADMINUSERNAME" "Domain owner not found for $DOMAIN" "Could not determine owner for domain: $DOMAIN"
    write_status "$DOMAIN" "error" "" "" "Domain owner not found in DirectAdmin"
    exit 0
fi
echo "Owner of $DOMAIN: $OWNER"

RESELLER=$(find_reseller "$OWNER")
if [ -z "$RESELLER" ]; then
    echo "Reseller not found for user: $OWNER"
    send_notification "$ADMINUSERNAME" "Reseller not found for $DOMAIN" "Could not determine reseller for owner: $OWNER"
    write_status "$DOMAIN" "error" "$OWNER" "" "Reseller not found for owner $OWNER"
    exit 0
fi
echo "Reseller for $DOMAIN: $RESELLER"

#------------------------------------------------
# LOAD TLD EXCEPTIONS
#------------------------------------------------
EXCEPTION_DOMAINS=()
TLD_EXCEPTION_FILE="$PLUGIN_PATH/data/tld_exceptions.txt"
if [ -f "$TLD_EXCEPTION_FILE" ]; then
    while IFS= read -r tld || [ -n "$tld" ]; do
        [[ -n "$tld" ]] && EXCEPTION_DOMAINS+=("$tld")
    done < "$TLD_EXCEPTION_FILE"
else
    EXCEPTION_DOMAINS=("com" "care")
fi

#------------------------------------------------
# LOAD CREDENTIALS AND DETERMINE REGISTRAR
#------------------------------------------------
PLUGIN_CREDS_FILE="$PLUGIN_PATH/data/credentials/${RESELLER}.conf"
if [ ! -f "$PLUGIN_CREDS_FILE" ]; then
    echo "Credentials file not found for reseller $RESELLER"
    send_notification "$ADMINUSERNAME" "Credentials missing for $DOMAIN" "No credentials file found for reseller $RESELLER"
    write_status "$DOMAIN" "error" "$OWNER" "$RESELLER" "Credentials not configured for reseller $RESELLER"
    exit 0
fi
source "$PLUGIN_CREDS_FILE"
REGISTRAR="${REGISTRAR:-odr}"
echo "Registrar for $RESELLER: $REGISTRAR"

#------------------------------------------------
# ROUTE TO REGISTRAR MODULE
#------------------------------------------------
MODULE="$PLUGIN_PATH/sync/registrars/${REGISTRAR}.sh"
if [ ! -f "$MODULE" ]; then
    echo "Registrar module not found: $MODULE"
    send_notification "$ADMINUSERNAME" "Unknown registrar for $DOMAIN" "Registrar '$REGISTRAR' is not supported (no module found) for reseller $RESELLER"
    write_status "$DOMAIN" "error" "$OWNER" "$RESELLER" "Unknown registrar: $REGISTRAR"
    exit 0
fi

echo "Loading registrar module: $REGISTRAR"
source "$MODULE"

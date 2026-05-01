#!/bin/bash
# *******************************************************************************
#* @file        da-odr-dnssec-sync.sh
#*
#* @brief       This script handles the registration of DNSSEC Keys at ODR (Open Domain Registry)
#*
#* @details     It checks if there are DNSSEC keys on the server.
#*              These are compared with those at ODR. If they are different, they are updated.
#*              The script can be saved in /usr/local/directadmin/scripts/custom/dnssec_sign_post.sh to run automatically after signing.
#*              Alternatively, it can be called standalone with the domain name as a parameter.
#*              Special thanks to Jordi van Nistelrooij @ Webs en Systems for the inspiration from his own script for oxxa syncing.
#*
#* @author      Tom van der Laan - TLWebdesign.nl.
#* @contact     info@tlwebdesign.nl
#* @website     https://tlwebdesign.nl
#* @version     1.0.0
#* @copyright   GNU General Public License version 3 or later;
#*
#* @date        2024-07-03
#*
#*******************************************************************************

# Define the log file
LOGFILE="/var/log/da-odr-dnssec-sync.log"

# Redirect both stdout and stderr to the log file
exec > >(tee -a "$LOGFILE") 2>&1

echo "//////////////////////////$(date)//////////////////////////"
echo "START OF THE SCRIPT TO UPDATE ODR DETAILS"
echo "///////////////////////////////////////////////"
# load the reseller credentials from external file
source /usr/local/directadmin/scripts/custom/da-odr-dnssec-config.sh

#------------------------------------------------
# BEGIN FUNCTIONS USED IN SCRIPT
#------------------------------------------------
# Function to generate SHA1 hash
generate_sha1() {
  echo -n "$1" | shasum | awk '{print $1}'
}

# Function to extract value using jq
extract_value() {
    local key=$1
    local response=$2
    echo "$response" | jq -r ".response.${key}"
}

# Function to make a POST request with JSON data
post_request() {
    local url=$1
    local json_data=$2
    echo "Sending POST request to $url with data: $json_data" >&2
    curl -v -X POST -H "Content-Type: application/json" -d "$json_data" "$url"
}

# Function to make a GET request with an access token in the header
get_request() {
    local url=$1
    local token=$2

    if [ -z "$url" ]; then
        echo "Error: URL is empty" >&2
        exit 0
    fi

    if [ -z "$token" ]; then
        echo "Error: Token is empty" >&2
        exit 0
    fi
    echo "Sending GET request to $url with token: $token" >&2
    curl -s -H "X-Access-Token: $token" "$url"
}

# Function to make a PUT request with JSON data
put_request() {
    local url=$1
    local json_data=$2
    local token=$3
    echo "Sending PUT request to $url with data: $json_data and token: $token" >&2
    curl -s -X PUT -H "Content-Type: application/json" -H "X-Access-Token: $token" -d "$json_data" "$url"
}

# Function to find the owner of the domain, including pointers
find_domain_owner() {
    local domain=$1

    # Search for the domain in the domains.list files
    for user_dir in /usr/local/directadmin/data/users/*; do
        if [ -d "$user_dir" ]; then
            user=$(basename "$user_dir")
            if grep -q "^$domain$" "$user_dir/domains.list"; then
                echo "$user"
                return
            fi
        fi
    done

    # Search for the domain in the .pointers files
    for pointer_file in /usr/local/directadmin/data/users/*/domains/*.pointers; do
        if grep -q "^$domain=" "$pointer_file"; then
            owner_domain=$(basename "$pointer_file" .pointers)
            find_domain_owner "$owner_domain"
            return
        fi
    done
}

# Function to find the reseller for a given user
find_reseller() {
    local user=$1
    if [ -f "/usr/local/directadmin/data/users/$user/user.conf" ]; then
        grep -m1 "^creator=" "/usr/local/directadmin/data/users/$user/user.conf" | cut -d= -f2
    fi
}

# Function to get the value from the array
get_value_from_credentials() {
    local reseller=$1
    local type=$2
    for entry in "${ODR_CREDENTIALS[@]}"; do
        IFS=',' read -r entry_reseller entry_type entry_value <<< "$entry"
        if [[ "$entry_reseller" == "$reseller" && "$entry_type" == "$type" ]]; then
            echo "$entry_value"
            return
        fi
    done
}

# Function to send a notification to a DirectAdmin user
send_notification() {
  local user=$1
  local subject=$2
  local message=$3
  task="action=notify&value=users&subject=$subject&message=$message&users=select1=$user"
  echo $task >> /usr/local/directadmin/data/task.queue
  echo "Notification sent to $user"
}

# Function to write a JSON status file for a domain
SYNC_STATUS_DIR="/usr/local/directadmin/plugins/da_dnssec_sync_manager/data/sync"
write_status() {
    local domain="$1"
    local status="$2"
    local owner="${3:-}"
    local reseller="${4:-}"
    local message="$5"
    [ -z "$domain" ] && return
    mkdir -p "$SYNC_STATUS_DIR"
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    jq -n \
        --arg domain    "$domain" \
        --arg last_sync "$timestamp" \
        --arg status    "$status" \
        --arg owner     "$owner" \
        --arg reseller  "$reseller" \
        --arg message   "$message" \
        '{domain:$domain,last_sync:$last_sync,status:$status,owner:$owner,reseller:$reseller,message:$message}' \
        > "$SYNC_STATUS_DIR/${domain}.json"
    chown diradmin:diradmin "$SYNC_STATUS_DIR/${domain}.json" 2>/dev/null
    chmod 644 "$SYNC_STATUS_DIR/${domain}.json"
}

# Function to check if a domain extension is in the exception list
is_exception_domain() {
    local domain=$1
    local parts=(${domain//./ })
    local extension=""

    # Check the number of elements in the array
    if [ ${#parts[@]} -eq 2 ]; then
        extension="${parts[1]}"
    elif [ ${#parts[@]} -eq 3 ]; then
        extension="${parts[1]}.${parts[2]}"
    fi

    for ext in "${EXCEPTION_DOMAINS[@]}"; do
        if [ "$ext" == "$extension" ]; then
            return 0
        fi
    done
    return 1
}

#------------------------------------------------
# CHECK IF jq IS INSTALLED
#------------------------------------------------
if ! command -v jq > /dev/null 2>&1; then
        echo "jq is not installed. Please install jq to proceed."
        send_notification "$ADMINUSERNAME" "jq is not installed." "The post dnssec script to sync with odr returned: jq is not installed. Please install jq to proceed."
        exit 0
fi

#------------------------------------------------
# CHECK IF DOMAIN IS FOUND IN DIRECTADMIN OR DEFINED AS PARAMETER
#------------------------------------------------
if [[ ! -z ${domain} ]]
  then
    echo "DIRECTADMIN DOMAIN SOURCE"
    DOMAIN=${domain}
elif [[ ! -z $1 ]]
  then
    echo "CLI DOMAIN SOURCE"
    DOMAIN=$1
else
    echo "NO DOMAIN INFORMATION AVAILABLE."
    send_notification "$ADMINUSERNAME" "No domain information available!" "The post dnssec script was triggered but there was no domain found."
    exit 0;
fi

#------------------------------------------------
# CHECK DNSSEC SYNC MANAGER EXCLUSION LIST
# Uses suffix-match "|domain$" to avoid partial matches (sub.example.com won't match example.com)
#------------------------------------------------
EXCEPTION_LIST="/usr/local/directadmin/plugins/da_dnssec_sync_manager/data/excluded.txt"
if [ -f "$EXCEPTION_LIST" ] && grep -q "|${DOMAIN}$" "$EXCEPTION_LIST"; then
    echo "Domain $DOMAIN is in the DNSSEC sync manager exclusion list. Skipping sync."
    write_status "$DOMAIN" "excluded" "" "" "Domain is in the sync exclusion list"
    exit 0
fi

#------------------------------------------------
# CHECK IF DOMAIN HAS DNSSEC KEY FILES (ZSK & KSK) AND SET VARS
#------------------------------------------------

# Path to the ZSK key file
ZSK_KEY_FILE="/var/named/${DOMAIN}.zsk.key"

if [[ -f $ZSK_KEY_FILE ]]
then
  # Read the line containing the DNSKEY
  ZSK_DNSEY_LINE=$(grep -E 'IN\s+DNSKEY' "$ZSK_KEY_FILE")

  # Extract the individual parts
  DIRECTADMIN_ZSK_FLAG=$(echo "$ZSK_DNSEY_LINE" | awk '{print $4}')
  DIRECTADMIN_ZSK_ALGORITHM=$(echo "$ZSK_DNSEY_LINE" | awk '{print $6}')
  DIRECTADMIN_ZSK_PUBKEY=$(echo "$ZSK_DNSEY_LINE" | awk '{for (i=7; i<=NF; i++) printf $i; print ""}')

  # Output the values for verification
  echo "DA ZSK Flag: $DIRECTADMIN_ZSK_FLAG"
  echo "DA ZSK Algortihm: $DIRECTADMIN_ZSK_ALGORITHM"
  echo "DA ZSK Key: $DIRECTADMIN_ZSK_PUBKEY"
else
  echo "DA ZSK FILE DOES NOT EXIST. THIS DOMAIN DOES NOT HAVE DNSSEC ENABLED"
  send_notification "$ADMINUSERNAME" "$DOMAIN DOES NOT HAVE DNSSEC ENABLED" "ZSK FILE NOT FOUND. $DOMAIN DOES NOT HAVE DNSSEC ENABLED"
  write_status "$DOMAIN" "error" "" "" "DNSSEC not enabled: ZSK key file not found"
  exit 0;
fi

# Path to the KSK key file
KSK_KEY_FILE="/var/named/${DOMAIN}.ksk.key"

if [[ -f $KSK_KEY_FILE ]]
then
  # Read the line containing the DNSKEY
  KSK_DNSEY_LINE=$(grep -E 'IN\s+DNSKEY' "$KSK_KEY_FILE")

  # Extract the individual parts
  DIRECTADMIN_KSK_FLAG=$(echo "$KSK_DNSEY_LINE" | awk '{print $4}')
  DIRECTADMIN_KSK_ALGORITHM=$(echo "$KSK_DNSEY_LINE" | awk '{print $6}')
  DIRECTADMIN_KSK_PUBKEY=$(echo "$KSK_DNSEY_LINE" | awk '{for (i=7; i<=NF; i++) printf $i; print ""}')

  # Output the values for verification
  echo "KSK Flag: $DIRECTADMIN_KSK_FLAG"
  echo "KSK Algorithm: $DIRECTADMIN_KSK_ALGORITHM"
  echo "KSK Key: $DIRECTADMIN_KSK_PUBKEY"
else
  echo "DA KSK FILE DOES NOT EXIST. THIS DOMAIN DOES NOT HAVE DNSSEC ENABLED"
  send_notification "$ADMINUSERNAME" "$DOMAIN DOES NOT HAVE DNSSEC ENABLED" "KSK FILE NOT FOUND. $DOMAIN DOES NOT HAVE DNSSEC ENABLED"
  write_status "$DOMAIN" "error" "" "" "DNSSEC not enabled: KSK key file not found"
  exit 0;
fi

#------------------------------------------------
# GET RESELLER OF OWNER OF DOMAIN IN DA
#------------------------------------------------

# Find the owner of the domain
OWNER=$(find_domain_owner "$DOMAIN")
if [ -z "$OWNER" ]; then
    echo "Domain owner not found for domain: $DOMAIN"
    send_notification "$ADMINUSERNAME" "Domain owner not found for domain: $DOMAIN" "Domain owner not found for domain: $DOMAIN"
    write_status "$DOMAIN" "error" "" "" "Domain owner not found in DirectAdmin"
    exit 0;
fi

echo "Owner of domain $DOMAIN: $OWNER"

# Find the reseller of the owner
RESELLER=$(find_reseller "$OWNER")
if [ -z "$RESELLER" ]; then
    echo "Reseller not found for user: $OWNER"
    send_notification "$ADMINUSERNAME" "Reseller not found for user: $OWNER" "Reseller not found for user: $OWNER"
    write_status "$DOMAIN" "error" "$OWNER" "" "Reseller not found for owner $OWNER"
    exit 0;
fi

echo "Reseller for domain $DOMAIN is: $RESELLER"

#------------------------------------------------
# START DEFINING VARIABLES
#------------------------------------------------

# API endpoints
LOGIN_URL="https://api.opendomainregistry.net/user/login"
DOMAININFO_URL="https://api.opendomainregistry.net/domain/$DOMAIN/info"
CHANGEDNSSEC_URL="https://api.opendomainregistry.net/domain/$DOMAIN/dnssec"

# Check for per-reseller credentials file (set via plugin UI); fall back to config array
PLUGIN_CREDS_FILE="/usr/local/directadmin/plugins/da_dnssec_sync_manager/data/credentials/${RESELLER}.conf"
if [ -f "$PLUGIN_CREDS_FILE" ]; then
    source "$PLUGIN_CREDS_FILE"
    API_KEY="$ODR_PUBLIC_KEY"
    API_SECRET="$ODR_PRIVATE_KEY"
else
    API_KEY=$(get_value_from_credentials "$RESELLER" "public")
    API_SECRET=$(get_value_from_credentials "$RESELLER" "private")
fi

# Check if API_KEY or API_SECRET is empty and exit if they are stop the script because there is nothing we can do.
if [ -z "$API_KEY" ] && [ -z "$API_SECRET" ]; then
    echo "Both API_KEY and API_SECRET are empty. Exiting."
    send_notification "$ADMINUSERNAME" "Both API_KEY and API_SECRET are empty for domain: $DOMAIN with reseller $RESELLER. Exiting." "Both API_KEY and API_SECRET are empty for $RESELLER. Exiting."
    write_status "$DOMAIN" "error" "$OWNER" "$RESELLER" "ODR credentials not configured for reseller $RESELLER"
    exit 0;
elif [ -z "$API_KEY" ]; then
    echo "API_KEY is empty. Exiting."
    send_notification "$ADMINUSERNAME" "API_KEY is empty for domain: $DOMAIN with reseller $RESELLER. Exiting." "API_KEY is empty for $RESELLER. Exiting."
    write_status "$DOMAIN" "error" "$OWNER" "$RESELLER" "ODR public key not configured for reseller $RESELLER"
    exit 0;
elif [ -z "$API_SECRET" ]; then
    echo "API_SECRET is empty. Exiting."
    send_notification "$ADMINUSERNAME" "API_SECRET is empty for domain: $DOMAIN with reseller $RESELLER. Exiting." "API_SECRET is empty for $RESELLER. Exiting."
    write_status "$DOMAIN" "error" "$OWNER" "$RESELLER" "ODR private key not configured for reseller $RESELLER"
    exit 0;
fi

# Corrected variable assignments
API_SECRET_SHA1=$(generate_sha1 "$API_SECRET")
# Generate current timestamp
TIMESTAMP=$(date +%s)
# The signature as in sha1
SIGNATURE=$(generate_sha1 "$API_KEY $TIMESTAMP $API_SECRET_SHA1")

# JSON data for ODR Login call
JSON_DATA=$(cat <<EOF
{
    "api_key": "$API_KEY",
    "signature": "token\$${SIGNATURE}",
    "timestamp": "$TIMESTAMP"
}
EOF
)
# Default ODR vars to be updated later on
ODR_ZSK_FLAG=""
ODR_ZSK_PUBKEY=""
ODR_ZSK_ALGORITHM=""
ODR_KSK_FLAG=""
ODR_KSK_PUBKEY=""
ODR_KSK_ALGORITHM=""

# TLD exceptions: extensions where ODR does not return pubkey data in the update response
# Read from plugin data file; fall back to hardcoded defaults if plugin is not installed
EXCEPTION_DOMAINS=()
TLD_EXCEPTION_FILE="/usr/local/directadmin/plugins/da_dnssec_sync_manager/data/tld_exceptions.txt"
if [ -f "$TLD_EXCEPTION_FILE" ]; then
    while IFS= read -r tld || [ -n "$tld" ]; do
        [[ -n "$tld" ]] && EXCEPTION_DOMAINS+=("$tld")
    done < "$TLD_EXCEPTION_FILE"
else
    EXCEPTION_DOMAINS=("com" "care")
fi

#------------------------------------------------
# LOGIN ODR API & EXTRACT TOKEN
#------------------------------------------------

# Make the POST request
LOGIN_RESPONSE=$(post_request "$LOGIN_URL" "$JSON_DATA")

# Print the response
echo "POST Response: $LOGIN_RESPONSE"
ACCESS_TOKEN=$(extract_value "token" "$LOGIN_RESPONSE")

#------------------------------------------------
# GET DOMAIN INFO FROM ODR (CURRENT DNSSEC VALUES)
#------------------------------------------------
DOMAININFO_RESPONSE=$(get_request "$DOMAININFO_URL" "$ACCESS_TOKEN")

echo "GET Response: $DOMAININFO_RESPONSE"

DOMAININFO_STATUS=$(echo "$DOMAININFO_RESPONSE" | jq -r '.status')
DOMAININFO_MESSAGE=$(echo "$DOMAININFO_RESPONSE" | jq -r '.response.message')
DOMAININFO_CODE=$(echo "$DOMAININFO_RESPONSE" | jq -r '.code')

# Check for 404 error domain not found
if [ "$DOMAININFO_STATUS" != "success" ]; then
    message="Domain $DOMAIN not found in ODR ($DOMAININFO_CODE): $DOMAININFO_MESSAGE"
    echo $message
    # Notify admin and reseller
    encoded_message=$(echo -e "$message" | sed ':a;N;$!ba;s/\n/%0A/g')
    send_notification "$ADMINUSERNAME" "Domain $DOMAIN not found in ODR ($DOMAININFO_CODE)" "$encoded_message"
    send_notification "$RESELLER" "Domain $DOMAIN not found in ODR ($DOMAININFO_CODE)" "$encoded_message"
    write_status "$DOMAIN" "error" "$OWNER" "$RESELLER" "Domain not found in ODR ($DOMAININFO_CODE): $DOMAININFO_MESSAGE"
    exit 0;
fi

DNSSEC_ENTRIES=$(echo "$DOMAININFO_RESPONSE" | jq -c '.response.dnssec[]')

# Check if DNSSEC_ENTRIES is empty
if [ -z "$DNSSEC_ENTRIES" ]; then
    echo "No DNSSEC entries found."
else
    # Iterate over DNSSEC entries and set ODR variables
    while IFS= read -r entry; do
        flag=$(echo "$entry" | jq -r '.flag')
        if [ "$flag" -eq "256" ]; then
            ODR_ZSK_FLAG="$flag"
            ODR_ZSK_PUBKEY=$(echo "$entry" | jq -r '.pubkey')
            ODR_ZSK_ALGORITHM=$(echo "$entry" | jq -r '.algorithm')
            echo "ODR ZSK Flag: $ODR_ZSK_FLAG"
            echo "ODR ZSK Public Key: $ODR_ZSK_PUBKEY"
            echo "ODR ZSK Algorithm: $ODR_ZSK_ALGORITHM"
            echo "-----------------------------"
        elif [ "$flag" -eq "257" ]; then
            ODR_KSK_FLAG="$flag"
            ODR_KSK_PUBKEY=$(echo "$entry" | jq -r '.pubkey')
            ODR_KSK_ALGORITHM=$(echo "$entry" | jq -r '.algorithm')
            echo "ODR KSK Flag: $ODR_KSK_FLAG"
            echo "ODR KSK Public Key: $ODR_KSK_PUBKEY"
            echo "ODR KSK Algorithm: $ODR_KSK_ALGORITHM"
            echo "-----------------------------"
        fi
    done <<< "$DNSSEC_ENTRIES"
fi

#------------------------------------------------
# ACTION ON DNSSEC VALUES AT ODR
#------------------------------------------------
# Perform comparison and update if necessary
update_needed=false

if [ "$ODR_ZSK_FLAG" != "$DIRECTADMIN_ZSK_FLAG" ] || [ "$ODR_ZSK_PUBKEY" != "$DIRECTADMIN_ZSK_PUBKEY" ] || [ "$ODR_ZSK_ALGORITHM" != "$DIRECTADMIN_ZSK_ALGORITHM" ]; then
    ODR_ZSK_FLAG="$DIRECTADMIN_ZSK_FLAG"
    ODR_ZSK_PUBKEY="$DIRECTADMIN_ZSK_PUBKEY"
    ODR_ZSK_ALGORITHM="$DIRECTADMIN_ZSK_ALGORITHM"
    update_needed=true
    echo "ODR ZSK NEEDS UPDATING"
fi

if [ "$ODR_KSK_FLAG" != "$DIRECTADMIN_KSK_FLAG" ] || [ "$ODR_KSK_PUBKEY" != "$DIRECTADMIN_KSK_PUBKEY" ] || [ "$ODR_KSK_ALGORITHM" != "$DIRECTADMIN_KSK_ALGORITHM" ]; then
    ODR_KSK_FLAG="$DIRECTADMIN_KSK_FLAG"
    ODR_KSK_PUBKEY="$DIRECTADMIN_KSK_PUBKEY"
    ODR_KSK_ALGORITHM="$DIRECTADMIN_KSK_ALGORITHM"
    update_needed=true
    echo "ODR KSK NEEDS UPDATING"
fi

if [ "$update_needed" = true ]; then
    # JSON data for the PUT request
    PUT_JSON_DATA=$(cat <<EOF
{
    "domain_name": "$DOMAIN",
    "dnssec1": {
            "flag": "$ODR_ZSK_FLAG",
            "protocol": 3,
            "pubkey": "$ODR_ZSK_PUBKEY",
            "algorithm": "$ODR_ZSK_ALGORITHM"
        },
    "dnssec2": {
            "flag": "$ODR_KSK_FLAG",
            "protocol": 3,
            "pubkey": "$ODR_KSK_PUBKEY",
            "algorithm": "$ODR_KSK_ALGORITHM"
        }
}
EOF
    )

    # Perform the PUT request to update ODR DNSSEC settings
    PUT_RESPONSE=$(put_request "$CHANGEDNSSEC_URL" "$PUT_JSON_DATA" "$ACCESS_TOKEN")

    echo "PUT Response: $PUT_RESPONSE"

    # Extract the status and data from the PUT response
    PUT_STATUS=$(echo "$PUT_RESPONSE" | jq -r '.status')
    PUT_CODE=$(echo "$PUT_RESPONSE" | jq -r '.code')
    PUT_RESPONSE_STATUS=$(echo "$PUT_RESPONSE" | jq -r '.response.status')
    TO_APPEND=$(echo "$PUT_RESPONSE" | jq -r '.response.data.to_append.dnssec // empty')
    MESSAGEX=$(echo "$PUT_RESPONSE" | jq -r '.response.data.messagex // empty')
    if [ "$PUT_STATUS" == "success" ]; then
        # Check if the status is "COMPLETED" and the to_append is not empty
        if [ "$PUT_RESPONSE_STATUS" == "COMPLETED" ] && [ -n "$TO_APPEND" ]; then
            # Extract pubkeys from the response
            ODR_ZSK_PUBKEY_RESPONSE=$(echo "$PUT_RESPONSE" | jq -r '.response.data.to_append.dnssec[] | select(.flag == "256") | .pubkey')
            ODR_KSK_PUBKEY_RESPONSE=$(echo "$PUT_RESPONSE" | jq -r '.response.data.to_append.dnssec[] | select(.flag == "257") | .pubkey')
            if is_exception_domain "$DOMAIN"; then
                message="DNSSEC update at ODR completed successfully for exception domain $DOMAIN."
                echo $message
                # Notify admin and reseller
                encoded_message=$(echo -e "$message" | sed ':a;N;$!ba;s/\n/%0A/g')
                send_notification "$RESELLER" "DNSSEC Update Completed for exception domain $DOMAIN" "$encoded_message"
                write_status "$DOMAIN" "ok" "$OWNER" "$RESELLER" "DNSSEC update completed (TLD exception — pubkey check skipped)"
            else
                # Check if the pubkeys match
                if [ "$ODR_ZSK_PUBKEY_RESPONSE" == "$ODR_ZSK_PUBKEY" ] && [ "$ODR_KSK_PUBKEY_RESPONSE" == "$ODR_KSK_PUBKEY" ]; then
                    message="DNSSEC update at ODR completed successfully for domain $DOMAIN."
                    echo $message
                    # Notify reseller
                    encoded_message=$(echo -e "$message" | sed ':a;N;$!ba;s/\n/%0A/g')
                    send_notification "$RESELLER" "DNSSEC Update Completed for domain $DOMAIN" "$encoded_message"
                    write_status "$DOMAIN" "ok" "$OWNER" "$RESELLER" "DNSSEC update completed and verified"
                else
                    message="DNSSEC update at ODR failed for domain $DOMAIN. Pubkeys do not match."
                    echo $message
                    # Notify admin and reseller
                    encoded_message=$(echo -e "$message" | sed ':a;N;$!ba;s/\n/%0A/g')
                    send_notification "$ADMINUSERNAME" "DNSSEC Update Failed for domain $DOMAIN" "$encoded_message"
                    send_notification "$RESELLER" "DNSSEC Update Failed for domain $DOMAIN" "$encoded_message"
                    write_status "$DOMAIN" "error" "$OWNER" "$RESELLER" "DNSSEC update at ODR failed: pubkeys do not match"
                fi
            fi
        else
            message="DNSSEC update at ODR failed or is incomplete for domain $DOMAIN. Status: $PUT_RESPONSE_STATUS. Message: $MESSAGEX"
            echo $message
            # Notify admin and reseller
            encoded_message=$(echo -e "$message" | sed ':a;N;$!ba;s/\n/%0A/g')
            send_notification "$ADMINUSERNAME" "DNSSEC Update Failed for domain $DOMAIN" "$encoded_message"
            send_notification "$RESELLER" "DNSSEC Update Failed for domain $DOMAIN" "$encoded_message"
            write_status "$DOMAIN" "error" "$OWNER" "$RESELLER" "DNSSEC update failed or incomplete: $PUT_RESPONSE_STATUS $MESSAGEX"
        fi
    else
        PUT_MESSAGE=$(echo "$PUT_RESPONSE" | jq -r '.response.message // empty')
        message="DNSSEC update failed for $DOMAIN in ODR ($PUT_CODE): $PUT_MESSAGE"
        echo $message
        # Notify admin and reseller
        encoded_message=$(echo -e "$message" | sed ':a;N;$!ba;s/\n/%0A/g')
        send_notification "$ADMINUSERNAME" "DNSSEC update failed for $DOMAIN in ODR ($PUT_CODE)" "$encoded_message"
        send_notification "$RESELLER" "DNSSEC update failed for $DOMAIN in ODR ($PUT_CODE)" "$encoded_message"
        write_status "$DOMAIN" "error" "$OWNER" "$RESELLER" "DNSSEC update failed in ODR ($PUT_CODE): $PUT_MESSAGE"
        exit 0;
    fi
else
    echo "No update needed. ODR DNSSEC settings are up to date."
    write_status "$DOMAIN" "ok" "$OWNER" "$RESELLER" "DNSSEC keys are already in sync"
fi

echo "///////////////////////////////////////////////"
echo "END OF THE SCRIPT TO UPDATE ODR DETAILS FOR $DOMAIN"
echo "//////////////////////////$(date)//////////////////////////"
echo " "
exit 0;

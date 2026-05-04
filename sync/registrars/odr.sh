#!/bin/bash
# ODR (Open Domain Registry) registrar module
# Sourced by da-odr-dnssec-sync.sh — do not execute directly
# Expects: DOMAIN, OWNER, RESELLER, ADMINUSERNAME, DIRECTADMIN_ZSK_*, DIRECTADMIN_KSK_*
# Uses: write_status(), send_notification(), is_exception_domain(), EXCEPTION_DOMAINS[]

generate_sha1() {
    echo -n "$1" | shasum | awk '{print $1}'
}

post_request() {
    local url="$1"
    local json_data="$2"
    echo "Sending POST request to $url with data: $json_data" >&2
    curl -v -X POST -H "Content-Type: application/json" -d "$json_data" "$url"
}

get_request() {
    local url="$1"
    local token="$2"
    [ -z "$url" ]   && echo "Error: URL is empty" >&2   && exit 0
    [ -z "$token" ] && echo "Error: Token is empty" >&2 && exit 0
    echo "Sending GET request to $url" >&2
    curl -s -H "X-Access-Token: $token" "$url"
}

put_request() {
    local url="$1"
    local json_data="$2"
    local token="$3"
    echo "Sending PUT request to $url with data: $json_data" >&2
    curl -s -X PUT -H "Content-Type: application/json" -H "X-Access-Token: $token" -d "$json_data" "$url"
}

extract_value() {
    local key="$1"
    local response="$2"
    echo "$response" | jq -r ".response.${key}"
}

#------------------------------------------------
# VALIDATE ODR CREDENTIALS
#------------------------------------------------
API_KEY="$ODR_PUBLIC_KEY"
API_SECRET="$ODR_PRIVATE_KEY"

if [ -z "$API_KEY" ] && [ -z "$API_SECRET" ]; then
    echo "ODR credentials not configured for reseller $RESELLER"
    send_notification "$ADMINUSERNAME" "ODR credentials missing for $DOMAIN" "No ODR credentials found for reseller $RESELLER"
    write_status "$DOMAIN" "error" "$OWNER" "$RESELLER" "ODR credentials not configured for reseller $RESELLER"
    exit 0
elif [ -z "$API_KEY" ]; then
    echo "ODR_PUBLIC_KEY is empty for reseller $RESELLER"
    send_notification "$ADMINUSERNAME" "ODR public key missing for $DOMAIN" "ODR_PUBLIC_KEY not configured for reseller $RESELLER"
    write_status "$DOMAIN" "error" "$OWNER" "$RESELLER" "ODR public key not configured for reseller $RESELLER"
    exit 0
elif [ -z "$API_SECRET" ]; then
    echo "ODR_PRIVATE_KEY is empty for reseller $RESELLER"
    send_notification "$ADMINUSERNAME" "ODR private key missing for $DOMAIN" "ODR_PRIVATE_KEY not configured for reseller $RESELLER"
    write_status "$DOMAIN" "error" "$OWNER" "$RESELLER" "ODR private key not configured for reseller $RESELLER"
    exit 0
fi

#------------------------------------------------
# BUILD AUTH AND API ENDPOINTS
#------------------------------------------------
LOGIN_URL="https://api.opendomainregistry.net/user/login"
DOMAININFO_URL="https://api.opendomainregistry.net/domain/$DOMAIN/info"
CHANGEDNSSEC_URL="https://api.opendomainregistry.net/domain/$DOMAIN/dnssec"

API_SECRET_SHA1=$(generate_sha1 "$API_SECRET")
TIMESTAMP=$(date +%s)
SIGNATURE=$(generate_sha1 "$API_KEY $TIMESTAMP $API_SECRET_SHA1")

JSON_DATA=$(cat <<EOF
{
    "api_key": "$API_KEY",
    "signature": "token\$${SIGNATURE}",
    "timestamp": "$TIMESTAMP"
}
EOF
)

ODR_ZSK_FLAG=""
ODR_ZSK_PUBKEY=""
ODR_ZSK_ALGORITHM=""
ODR_KSK_FLAG=""
ODR_KSK_PUBKEY=""
ODR_KSK_ALGORITHM=""

#------------------------------------------------
# LOGIN AND GET DOMAIN INFO
#------------------------------------------------
LOGIN_RESPONSE=$(post_request "$LOGIN_URL" "$JSON_DATA")
echo "POST Response: $LOGIN_RESPONSE"
ACCESS_TOKEN=$(extract_value "token" "$LOGIN_RESPONSE")

DOMAININFO_RESPONSE=$(get_request "$DOMAININFO_URL" "$ACCESS_TOKEN")
echo "GET Response: $DOMAININFO_RESPONSE"

DOMAININFO_STATUS=$(echo "$DOMAININFO_RESPONSE" | jq -r '.status')
DOMAININFO_MESSAGE=$(echo "$DOMAININFO_RESPONSE" | jq -r '.response.message')
DOMAININFO_CODE=$(echo "$DOMAININFO_RESPONSE" | jq -r '.code')

if [ "$DOMAININFO_STATUS" != "success" ]; then
    message="Domain $DOMAIN not found in ODR ($DOMAININFO_CODE): $DOMAININFO_MESSAGE"
    echo "$message"
    encoded_message=$(echo -e "$message" | sed ':a;N;$!ba;s/\n/%0A/g')
    send_notification "$ADMINUSERNAME" "Domain $DOMAIN not found in ODR ($DOMAININFO_CODE)" "$encoded_message"
    send_notification "$RESELLER" "Domain $DOMAIN not found in ODR ($DOMAININFO_CODE)" "$encoded_message"
    write_status "$DOMAIN" "error" "$OWNER" "$RESELLER" "Domain not found in ODR ($DOMAININFO_CODE): $DOMAININFO_MESSAGE"
    exit 0
fi

DNSSEC_ENTRIES=$(echo "$DOMAININFO_RESPONSE" | jq -c '.response.dnssec[]' 2>/dev/null)
if [ -n "$DNSSEC_ENTRIES" ]; then
    while IFS= read -r entry; do
        flag=$(echo "$entry" | jq -r '.flag')
        if [ "$flag" -eq 256 ]; then
            ODR_ZSK_FLAG="$flag"
            ODR_ZSK_PUBKEY=$(echo "$entry" | jq -r '.pubkey')
            ODR_ZSK_ALGORITHM=$(echo "$entry" | jq -r '.algorithm')
            echo "ODR ZSK Flag: $ODR_ZSK_FLAG"
            echo "ODR ZSK Public Key: $ODR_ZSK_PUBKEY"
            echo "ODR ZSK Algorithm: $ODR_ZSK_ALGORITHM"
        elif [ "$flag" -eq 257 ]; then
            ODR_KSK_FLAG="$flag"
            ODR_KSK_PUBKEY=$(echo "$entry" | jq -r '.pubkey')
            ODR_KSK_ALGORITHM=$(echo "$entry" | jq -r '.algorithm')
            echo "ODR KSK Flag: $ODR_KSK_FLAG"
            echo "ODR KSK Public Key: $ODR_KSK_PUBKEY"
            echo "ODR KSK Algorithm: $ODR_KSK_ALGORITHM"
        fi
    done <<< "$DNSSEC_ENTRIES"
fi

#------------------------------------------------
# COMPARE AND UPDATE
#------------------------------------------------
update_needed=false

if [ "$ODR_ZSK_FLAG" != "$DIRECTADMIN_ZSK_FLAG" ] \
    || [ "$ODR_ZSK_PUBKEY" != "$DIRECTADMIN_ZSK_PUBKEY" ] \
    || [ "$ODR_ZSK_ALGORITHM" != "$DIRECTADMIN_ZSK_ALGORITHM" ]; then
    update_needed=true
    echo "ODR ZSK NEEDS UPDATING"
fi

if [ "$ODR_KSK_FLAG" != "$DIRECTADMIN_KSK_FLAG" ] \
    || [ "$ODR_KSK_PUBKEY" != "$DIRECTADMIN_KSK_PUBKEY" ] \
    || [ "$ODR_KSK_ALGORITHM" != "$DIRECTADMIN_KSK_ALGORITHM" ]; then
    update_needed=true
    echo "ODR KSK NEEDS UPDATING"
fi

if [ "$update_needed" = true ]; then
    PUT_JSON_DATA=$(cat <<EOF
{
    "domain_name": "$DOMAIN",
    "dnssec1": {
        "flag": "$DIRECTADMIN_ZSK_FLAG",
        "protocol": 3,
        "pubkey": "$DIRECTADMIN_ZSK_PUBKEY",
        "algorithm": "$DIRECTADMIN_ZSK_ALGORITHM"
    },
    "dnssec2": {
        "flag": "$DIRECTADMIN_KSK_FLAG",
        "protocol": 3,
        "pubkey": "$DIRECTADMIN_KSK_PUBKEY",
        "algorithm": "$DIRECTADMIN_KSK_ALGORITHM"
    }
}
EOF
    )

    PUT_RESPONSE=$(put_request "$CHANGEDNSSEC_URL" "$PUT_JSON_DATA" "$ACCESS_TOKEN")
    echo "PUT Response: $PUT_RESPONSE"

    PUT_STATUS=$(echo "$PUT_RESPONSE" | jq -r '.status')
    PUT_CODE=$(echo "$PUT_RESPONSE" | jq -r '.code')
    PUT_RESPONSE_STATUS=$(echo "$PUT_RESPONSE" | jq -r '.response.status')
    TO_APPEND=$(echo "$PUT_RESPONSE" | jq -r '.response.data.to_append.dnssec // empty')
    MESSAGEX=$(echo "$PUT_RESPONSE" | jq -r '.response.data.messagex // empty')

    if [ "$PUT_STATUS" = "success" ]; then
        if [ "$PUT_RESPONSE_STATUS" = "COMPLETED" ] && [ -n "$TO_APPEND" ]; then
            ODR_ZSK_PUBKEY_RESPONSE=$(echo "$PUT_RESPONSE" | jq -r '.response.data.to_append.dnssec[] | select(.flag == "256") | .pubkey')
            ODR_KSK_PUBKEY_RESPONSE=$(echo "$PUT_RESPONSE" | jq -r '.response.data.to_append.dnssec[] | select(.flag == "257") | .pubkey')
            if is_exception_domain "$DOMAIN"; then
                message="DNSSEC update at ODR completed for exception domain $DOMAIN."
                echo "$message"
                encoded_message=$(echo -e "$message" | sed ':a;N;$!ba;s/\n/%0A/g')
                send_notification "$RESELLER" "DNSSEC Update Completed for exception domain $DOMAIN" "$encoded_message"
                write_status "$DOMAIN" "ok" "$OWNER" "$RESELLER" "DNSSEC update completed (TLD exception — pubkey check skipped)"
            else
                if [ "$ODR_ZSK_PUBKEY_RESPONSE" = "$DIRECTADMIN_ZSK_PUBKEY" ] && [ "$ODR_KSK_PUBKEY_RESPONSE" = "$DIRECTADMIN_KSK_PUBKEY" ]; then
                    message="DNSSEC update at ODR completed for domain $DOMAIN."
                    echo "$message"
                    encoded_message=$(echo -e "$message" | sed ':a;N;$!ba;s/\n/%0A/g')
                    send_notification "$RESELLER" "DNSSEC Update Completed for domain $DOMAIN" "$encoded_message"
                    write_status "$DOMAIN" "ok" "$OWNER" "$RESELLER" "DNSSEC update completed and verified"
                else
                    message="DNSSEC update at ODR failed for domain $DOMAIN. Pubkeys do not match."
                    echo "$message"
                    encoded_message=$(echo -e "$message" | sed ':a;N;$!ba;s/\n/%0A/g')
                    send_notification "$ADMINUSERNAME" "DNSSEC Update Failed for domain $DOMAIN" "$encoded_message"
                    send_notification "$RESELLER" "DNSSEC Update Failed for domain $DOMAIN" "$encoded_message"
                    write_status "$DOMAIN" "error" "$OWNER" "$RESELLER" "DNSSEC update at ODR failed: pubkeys do not match"
                fi
            fi
        else
            message="DNSSEC update at ODR failed or incomplete for domain $DOMAIN. Status: $PUT_RESPONSE_STATUS. Message: $MESSAGEX"
            echo "$message"
            encoded_message=$(echo -e "$message" | sed ':a;N;$!ba;s/\n/%0A/g')
            send_notification "$ADMINUSERNAME" "DNSSEC Update Failed for domain $DOMAIN" "$encoded_message"
            send_notification "$RESELLER" "DNSSEC Update Failed for domain $DOMAIN" "$encoded_message"
            write_status "$DOMAIN" "error" "$OWNER" "$RESELLER" "DNSSEC update failed or incomplete: $PUT_RESPONSE_STATUS $MESSAGEX"
        fi
    else
        PUT_MESSAGE=$(echo "$PUT_RESPONSE" | jq -r '.response.message // empty')
        message="DNSSEC update failed for $DOMAIN in ODR ($PUT_CODE): $PUT_MESSAGE"
        echo "$message"
        encoded_message=$(echo -e "$message" | sed ':a;N;$!ba;s/\n/%0A/g')
        send_notification "$ADMINUSERNAME" "DNSSEC update failed for $DOMAIN in ODR ($PUT_CODE)" "$encoded_message"
        send_notification "$RESELLER" "DNSSEC update failed for $DOMAIN in ODR ($PUT_CODE)" "$encoded_message"
        write_status "$DOMAIN" "error" "$OWNER" "$RESELLER" "DNSSEC update failed in ODR ($PUT_CODE): $PUT_MESSAGE"
        exit 0
    fi
else
    echo "No update needed. ODR DNSSEC settings are up to date."
    write_status "$DOMAIN" "ok" "$OWNER" "$RESELLER" "DNSSEC keys are already in sync"
fi

echo "///////////////////////////////////////////////"
echo "END OF DNSSEC SYNC FOR $DOMAIN"
echo "//////////////////////////$(date)//////////////////////////"
exit 0

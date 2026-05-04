#!/bin/bash
# OXXA registrar module
# Sourced by da-odr-dnssec-sync.sh — do not execute directly
# Expects: DOMAIN, OWNER, RESELLER, ADMINUSERNAME, DIRECTADMIN_ZSK_*, DIRECTADMIN_KSK_*
# Uses: write_status(), send_notification()
# Credentials expected: OXXA_USER, OXXA_PASS

#------------------------------------------------
# CHECK xmllint
#------------------------------------------------
if ! command -v xmllint > /dev/null 2>&1; then
    echo "xmllint is not installed. Please install libxml2-utils."
    send_notification "$ADMINUSERNAME" "xmllint not installed" "The DNSSEC sync script requires xmllint for OXXA. Install libxml2-utils."
    write_status "$DOMAIN" "error" "$OWNER" "$RESELLER" "xmllint not installed (required for OXXA)"
    exit 0
fi

#------------------------------------------------
# VALIDATE OXXA CREDENTIALS
#------------------------------------------------
if [ -z "$OXXA_USER" ] || [ -z "$OXXA_PASS" ]; then
    echo "OXXA credentials not configured for reseller $RESELLER"
    send_notification "$ADMINUSERNAME" "OXXA credentials missing for $DOMAIN" "OXXA_USER or OXXA_PASS not configured for reseller $RESELLER"
    write_status "$DOMAIN" "error" "$OWNER" "$RESELLER" "OXXA credentials not configured for reseller $RESELLER"
    exit 0
fi

#------------------------------------------------
# SPLIT DOMAIN INTO SLD AND TLD
# Simple split: first label is SLD, the rest is TLD (e.g. example.co.uk → SLD=example TLD=co.uk)
#------------------------------------------------
SLD=$(echo "$DOMAIN" | cut -d'.' -f1)
TLD=$(echo "$DOMAIN" | cut -d'.' -f2-)

echo "OXXA: SLD=$SLD TLD=$TLD"

#------------------------------------------------
# HELPERS
#------------------------------------------------
OXXA_API="https://api.oxxa.com/command.php"
OXXA_AUTH="apiuser=${OXXA_USER}&apipassword=${OXXA_PASS}"

# URL-encode a value using curl
urlencode() {
    curl -s -w '%{url_effective}\n' -G / --data-urlencode "=$1" | cut -c 3-
}

# Call OXXA API, print status_description to stdout, clean up temp file
oxxa_call() {
    local params="$1"
    local tmpfile
    tmpfile=$(mktemp "/tmp/oxxa_${DOMAIN}_$$.xml")
    curl -s "${OXXA_API}?${OXXA_AUTH}&${params}" > "$tmpfile"
    local status_desc
    status_desc=$(xmllint --xpath "string(//status_description)" "$tmpfile" 2>/dev/null)
    echo "OXXA response: $status_desc"
    rm -f "$tmpfile"
}

# Read a field from OXXA XML response by index and element name
# Usage: xml_key <file> <index> <element>
xml_key() {
    xmllint --xpath "string(//dnssec/key[$1]/$2)" "$3" 2>/dev/null
}

#------------------------------------------------
# FETCH CURRENT DNSSEC INFO FROM OXXA
#------------------------------------------------
RESP=$(mktemp "/tmp/oxxa_${DOMAIN}_$$.xml")
curl -s "${OXXA_API}?${OXXA_AUTH}&command=dnssec_info&sld=${SLD}&tld=${TLD}" > "$RESP"
STATUS_DESC=$(xmllint --xpath "string(//status_description)" "$RESP" 2>/dev/null)
echo "OXXA dnssec_info: $STATUS_DESC"

KEY_COUNT=$(xmllint --xpath "count(//dnssec/key)" "$RESP" 2>/dev/null)
KEY_COUNT="${KEY_COUNT:-0}"
# xmllint returns a float for count(), strip the decimal part
KEY_COUNT="${KEY_COUNT%%.*}"
echo "OXXA key count: $KEY_COUNT"

#------------------------------------------------
# COMPARE OXXA KEYS WITH LOCAL — DELETE STALE KEYS
#------------------------------------------------
NEEDS_ZSK=true
NEEDS_KSK=true

if [ "$KEY_COUNT" -gt 0 ]; then
    i=1
    while [ "$i" -le "$KEY_COUNT" ]; do
        R_FLAG=$(xml_key "$i" "flags"  "$RESP")
        R_PRO=$(xml_key  "$i" "protocol" "$RESP")
        R_ALG=$(xml_key  "$i" "alg"    "$RESP")
        R_PUBKEY=$(xml_key "$i" "pubKey" "$RESP")
        R_PUBKEY_ENC=$(urlencode "$R_PUBKEY")

        if [ "$R_FLAG" -eq 256 ] 2>/dev/null; then
            if [ "$R_PUBKEY" = "$DIRECTADMIN_ZSK_PUBKEY" ] && [ "$R_ALG" = "$DIRECTADMIN_ZSK_ALGORITHM" ]; then
                echo "OXXA ZSK matches local — no change needed"
                NEEDS_ZSK=false
            else
                echo "OXXA ZSK differs from local — deleting stale key"
                oxxa_call "command=dnssec_del&sld=${SLD}&tld=${TLD}&flag=${R_FLAG}&protocol=${R_PRO}&alg=${R_ALG}&pubkey=${R_PUBKEY_ENC}"
            fi
        elif [ "$R_FLAG" -eq 257 ] 2>/dev/null; then
            if [ "$R_PUBKEY" = "$DIRECTADMIN_KSK_PUBKEY" ] && [ "$R_ALG" = "$DIRECTADMIN_KSK_ALGORITHM" ]; then
                echo "OXXA KSK matches local — no change needed"
                NEEDS_KSK=false
            else
                echo "OXXA KSK differs from local — deleting stale key"
                oxxa_call "command=dnssec_del&sld=${SLD}&tld=${TLD}&flag=${R_FLAG}&protocol=${R_PRO}&alg=${R_ALG}&pubkey=${R_PUBKEY_ENC}"
            fi
        else
            echo "OXXA key[$i] has unknown flag '$R_FLAG' — deleting"
            oxxa_call "command=dnssec_del&sld=${SLD}&tld=${TLD}&flag=${R_FLAG}&protocol=${R_PRO}&alg=${R_ALG}&pubkey=${R_PUBKEY_ENC}"
        fi

        i=$((i + 1))
    done
fi

rm -f "$RESP"

#------------------------------------------------
# ADD MISSING KEYS
#------------------------------------------------
update_happened=false

if [ "$NEEDS_ZSK" = true ]; then
    ZSK_ENC=$(urlencode "$DIRECTADMIN_ZSK_PUBKEY")
    echo "Adding ZSK to OXXA (flag=$DIRECTADMIN_ZSK_FLAG alg=$DIRECTADMIN_ZSK_ALGORITHM)"
    oxxa_call "command=dnssec_add&sld=${SLD}&tld=${TLD}&flag=${DIRECTADMIN_ZSK_FLAG}&protocol=3&alg=${DIRECTADMIN_ZSK_ALGORITHM}&pubkey=${ZSK_ENC}"
    update_happened=true
fi

if [ "$NEEDS_KSK" = true ]; then
    KSK_ENC=$(urlencode "$DIRECTADMIN_KSK_PUBKEY")
    echo "Adding KSK to OXXA (flag=$DIRECTADMIN_KSK_FLAG alg=$DIRECTADMIN_KSK_ALGORITHM)"
    oxxa_call "command=dnssec_add&sld=${SLD}&tld=${TLD}&flag=${DIRECTADMIN_KSK_FLAG}&protocol=3&alg=${DIRECTADMIN_KSK_ALGORITHM}&pubkey=${KSK_ENC}"
    update_happened=true
fi

#------------------------------------------------
# REPORT STATUS
#------------------------------------------------
if [ "$update_happened" = true ]; then
    message="DNSSEC keys updated at OXXA for domain $DOMAIN."
    echo "$message"
    encoded_message=$(echo -e "$message" | sed ':a;N;$!ba;s/\n/%0A/g')
    send_notification "$RESELLER" "DNSSEC Update Completed for domain $DOMAIN" "$encoded_message"
    write_status "$DOMAIN" "ok" "$OWNER" "$RESELLER" "DNSSEC keys updated at OXXA"
else
    echo "No update needed. OXXA DNSSEC keys are up to date."
    write_status "$DOMAIN" "ok" "$OWNER" "$RESELLER" "DNSSEC keys are already in sync"
fi

echo "///////////////////////////////////////////////"
echo "END OF DNSSEC SYNC FOR $DOMAIN"
echo "//////////////////////////$(date)//////////////////////////"
exit 0

#!/bin/bash
# ============================================================
# Diagnose the remaining 403s in collection01.
#
# Answers three questions in one run:
#   1. Which ResourceAccessControl rule guards the failing URLs.
#   2. Which scopes the token app can actually obtain.
#   3. Whether the failing calls succeed under admin Basic auth
#      (i.e. scope gap vs. service-layer refusal).
#
# Creates a throwaway app + API resource and deletes them again.
# ============================================================

set -uo pipefail

SERVER_URL="${SERVER_URL:-localhost:9443}"; SERVER_URL="${SERVER_URL%/}"
TENANT="${TENANT_DOMAIN:-carbon.super}"
IS_HOME="${IS_HOME:-/home/wso2admin/wso2is-7.3.0}"

BASE="https://${SERVER_URL}/t/${TENANT}/api/server/v1"
TOKEN_URL="https://${SERVER_URL}/t/${TENANT}/oauth2/token"
AUTH=$(printf '%s' "admin:admin" | base64 | tr -d '\n')

TMP=$(mktemp -d); trap 'cleanup' EXIT

api()  { curl -sk -H "Authorization: Basic $AUTH" "$@"; }
rule() { printf '\n========== %s ==========\n' "$1"; }

PROBE_APP=""; PROBE_API=""
cleanup() {
    [[ -n "$PROBE_APP" ]] && api -o /dev/null -X DELETE "${BASE}/applications/${PROBE_APP}"
    [[ -n "$PROBE_API" ]] && api -o /dev/null -X DELETE "${BASE}/api-resources/${PROBE_API}"
    rm -rf "$TMP"
}

# --- 1. What the server says guards these URLs -------------------------------
rule "ResourceAccessControl rules for /applications"
IDENTITY_XML="${IS_HOME}/repository/conf/identity/identity.xml"
if [[ -f "$IDENTITY_XML" ]]; then
    grep -A4 '<Resource context=.*applications' "$IDENTITY_XML" \
        | grep -E 'Resource context|<Scopes>' | sed 's/^[[:space:]]*//'
else
    echo "NOT FOUND: $IDENTITY_XML  (set IS_HOME=...)"
fi

# --- 2. Token app credentials ------------------------------------------------
rule "Token app"
APP_ID=$(api "${BASE}/applications?filter=name+eq+E2E-Test-Suite-Token" | jq -r '.applications[0].id')
[[ "$APP_ID" == "null" || -z "$APP_ID" ]] && { echo "E2E-Test-Suite-Token not found. Run setup first."; exit 1; }
OIDC=$(api "${BASE}/applications/${APP_ID}/inbound-protocols/oidc")
CID=$(jq -r '.clientId'     <<<"$OIDC")
CS=$( jq -r '.clientSecret' <<<"$OIDC")
echo "appId=${APP_ID}"
echo "clientId=${CID}"
[[ -z "$CS" || "$CS" == "null" ]] && { echo "clientSecret not returned - cannot mint tokens."; exit 1; }

tok() {
    local resp granted
    resp=$(curl -sk -u "${CID}:${CS}" -d grant_type=client_credentials \
                --data-urlencode "scope=$1" "$TOKEN_URL")
    granted=$(jq -r '.scope // "<NONE>"' <<<"$resp")
    printf '  %-45s -> %s\n' "$1" "$granted" >&2
    jq -r '.access_token // empty' <<<"$resp"
}

# --- 3. Which scopes are actually grantable ----------------------------------
rule "Scopes the token app can obtain"
for s in internal_role_mgt_view internal_role_mgt_create internal_role_mgt_update \
         internal_application_mgt_view internal_application_mgt_update \
         internal_application_mgt_create; do
    tok "$s" >/dev/null
done

# --- 4. Throwaway probe targets ----------------------------------------------
rule "Creating throwaway probe app + API resource"
api -o /dev/null -X POST "${BASE}/applications" -H 'Content-Type: application/json' \
    --data-raw '{"name":"E2E-Probe-App","templateId":"custom-application-oidc",
      "associatedRoles":{"allowedAudience":"APPLICATION","roles":[]},
      "inboundProtocolConfiguration":{"oidc":{"grantTypes":["client_credentials"]}}}'
PROBE_APP=$(api "${BASE}/applications?filter=name+eq+E2E-Probe-App" | jq -r '.applications[0].id')

PROBE_API=$(api -X POST "${BASE}/api-resources" -H 'Content-Type: application/json' \
    --data-raw '{"name":"E2E Probe API","identifier":"e2e_probe_api","description":"probe",
      "requiresAuthorization":true,
      "scopes":[{"name":"probe:write","displayName":"Probe Write","description":"probe"}]}' \
    | jq -r '.id // empty')
echo "probeApp=${PROBE_APP}  probeApi=${PROBE_API}"
[[ -z "$PROBE_APP" || -z "$PROBE_API" ]] && { echo "Could not create probe targets."; exit 1; }

show() {  # $1 = label, rest = curl args
    local label="$1"; shift
    local code
    code=$(curl -sk -o "$TMP/out" -w '%{http_code}' "$@")
    printf '  %-28s HTTP %s   %s\n' "$label" "$code" "$(head -c 160 "$TMP/out" | tr -d '\n')"
}

# --- 5. authorized-apis ------------------------------------------------------
rule "POST /applications/{id}/authorized-apis"
BODY=$(printf '{"id":"%s","policyIdentifier":"RBAC","scopes":["probe:write"]}' "$PROBE_API")
T_UPD=$(tok internal_application_mgt_update)
URL="${BASE}/applications/${PROBE_APP}/authorized-apis"
show "bearer(mgt_update)" -X POST "$URL" -H "Authorization: Bearer $T_UPD" -H 'Content-Type: application/json' -d "$BODY"
show "basic(admin)"       -X POST "$URL" -H "Authorization: Basic $AUTH"   -H 'Content-Type: application/json' -d "$BODY"

# --- 6. regenerate-secret ----------------------------------------------------
rule "POST /applications/{id}/inbound-protocols/oidc/regenerate-secret"
T_CRE=$(tok internal_application_mgt_create)
T_BOTH=$(tok "internal_application_mgt_create internal_application_mgt_update")
URL="${BASE}/applications/${PROBE_APP}/inbound-protocols/oidc/regenerate-secret"
show "bearer(mgt_update)" -X POST "$URL" -H "Authorization: Bearer $T_UPD"
show "bearer(mgt_create)" -X POST "$URL" -H "Authorization: Bearer $T_CRE"
show "bearer(create+update)" -X POST "$URL" -H "Authorization: Bearer $T_BOTH"
show "basic(admin)"       -X POST "$URL" -H "Authorization: Basic $AUTH"

# --- 7. SCIM role create -----------------------------------------------------
rule "POST /scim2/v2/Roles"
T_ROLE=$(tok internal_role_mgt_create)
RURL="https://${SERVER_URL}/t/${TENANT}/scim2/v2/Roles"
RBODY=$(printf '{"schemas":["urn:ietf:params:scim:schemas:extension:2.0:Role"],"displayName":"e2e_probe_role","audience":{"value":"%s","type":"application"}}' "$PROBE_APP")
show "bearer(role_create)" -X POST "$RURL" -H "Authorization: Bearer $T_ROLE" -H 'Content-Type: application/scim+json' -d "$RBODY"
show "basic(admin)"        -X POST "$RURL" -H "Authorization: Basic $AUTH"    -H 'Content-Type: application/scim+json' -d "$RBODY"

# Remove the probe role if either call actually created it.
ROLE_ID=$(curl -sk -H "Authorization: Basic $AUTH" -H 'Content-Type: application/scim+json' \
    -X POST "https://${SERVER_URL}/t/${TENANT}/scim2/v2/Roles/.search" \
    --data-raw '{"schemas":["urn:ietf:params:scim:api:messages:2.0:SearchRequest"],"startIndex":1,"filter":"displayName eq e2e_probe_role"}' \
    | jq -r '.Resources[0].id // empty')
if [[ -n "$ROLE_ID" ]]; then
    curl -sk -o /dev/null -H "Authorization: Basic $AUTH" \
        -X DELETE "https://${SERVER_URL}/t/${TENANT}/scim2/v2/Roles/${ROLE_ID}"
    echo "Removed probe role ${ROLE_ID}."
fi

echo
echo "Done. Probe app / API resource / role removed."

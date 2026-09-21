#!/bin/bash
# ============================================================
# Why does "Create Role" 403 when a minimal role creation works?
#
# The collection's body also assigns users, groups and permissions.
# This isolates which part of the body needs which scope.
#
# Creates a throwaway app, user, group and roles; removes them all.
# ============================================================

set -uo pipefail

SERVER_URL="${SERVER_URL:-localhost:9443}"; SERVER_URL="${SERVER_URL%/}"
TENANT="${TENANT_DOMAIN:-carbon.super}"

BASE="https://${SERVER_URL}/t/${TENANT}/api/server/v1"
SCIM="https://${SERVER_URL}/t/${TENANT}/scim2"
TOKEN_URL="https://${SERVER_URL}/t/${TENANT}/oauth2/token"
AUTH=$(printf '%s' "admin:admin" | base64 | tr -d '\n')

TMP=$(mktemp -d)
APP=""; USR=""; GRP=""; ROLES=()

api()  { curl -sk -H "Authorization: Basic $AUTH" "$@"; }
rule() { printf '\n========== %s ==========\n' "$1"; }

cleanup() {
    for r in "${ROLES[@]:-}"; do
        [[ -n "$r" ]] && api -o /dev/null -X DELETE "${SCIM}/v2/Roles/${r}"
    done
    [[ -n "$GRP" ]] && api -o /dev/null -X DELETE "${SCIM}/Groups/${GRP}"
    [[ -n "$USR" ]] && api -o /dev/null -X DELETE "${SCIM}/Users/${USR}"
    [[ -n "$APP" ]] && api -o /dev/null -X DELETE "${BASE}/applications/${APP}"
    rm -rf "$TMP"
}
trap cleanup EXIT

rule "Token app"
APP_ID=$(api "${BASE}/applications?filter=name+eq+E2E-Test-Suite-Token" | jq -r '.applications[0].id')
OIDC=$(api "${BASE}/applications/${APP_ID}/inbound-protocols/oidc")
CID=$(jq -r '.clientId' <<<"$OIDC"); CS=$(jq -r '.clientSecret' <<<"$OIDC")
echo "clientId=${CID}"

tok() {
    curl -sk -u "${CID}:${CS}" -d grant_type=client_credentials \
         --data-urlencode "scope=$1" "$TOKEN_URL" | jq -r '.access_token // empty'
}

rule "Creating throwaway app / user / group"
api -o /dev/null -X POST "${BASE}/applications" -H 'Content-Type: application/json' \
    --data-raw '{"name":"E2E-Role-Probe-App","templateId":"custom-application-oidc",
      "associatedRoles":{"allowedAudience":"APPLICATION","roles":[]},
      "inboundProtocolConfiguration":{"oidc":{"grantTypes":["client_credentials"]}}}'
APP=$(api "${BASE}/applications?filter=name+eq+E2E-Role-Probe-App" | jq -r '.applications[0].id')

USR=$(api -X POST "${SCIM}/Users" -H 'Content-Type: application/scim+json' \
    --data-raw '{"schemas":[],"userName":"e2e_probe_user","password":"MyPa33w@rd",
      "name":{"givenName":"Probe","familyName":"User"}}' | jq -r '.id // empty')

GRP=$(api -X POST "${SCIM}/Groups" -H 'Content-Type: application/scim+json' \
    --data-raw "$(printf '{"schemas":["urn:ietf:params:scim:schemas:core:2.0:Group"],"displayName":"e2e_probe_group","members":[{"value":"%s","display":"e2e_probe_user"}]}' "$USR")" \
    | jq -r '.id // empty')
echo "app=${APP}  user=${USR}  group=${GRP}"
[[ -z "$APP" || -z "$USR" || -z "$GRP" ]] && { echo "Could not create probe fixtures."; exit 1; }

attempt() {  # $1=label  $2=token(or BASIC)  $3=displayName  $4=body
    local code auth
    if [[ "$2" == "BASIC" ]]; then auth="Basic $AUTH"; else auth="Bearer $2"; fi
    code=$(curl -sk -o "$TMP/out" -w '%{http_code}' -X POST "${SCIM}/v2/Roles" \
           -H "Authorization: $auth" -H 'Content-Type: application/scim+json' -d "$4")
    printf '  %-42s HTTP %s   %s\n' "$1" "$code" "$(jq -r '.detail // .displayName // "?"' "$TMP/out" 2>/dev/null | head -c 120)"
    local id; id=$(jq -r '.id // empty' "$TMP/out" 2>/dev/null)
    [[ -n "$id" ]] && ROLES+=("$id")
}

body() {  # $1 = displayName, $2 = "full" | "minimal" | "users" | "groups"
    local extra=""
    case "$2" in
      full)    extra=$(printf ',"users":[{"value":"%s"}],"groups":[{"value":"%s"}],"permissions":[]' "$USR" "$GRP") ;;
      users)   extra=$(printf ',"users":[{"value":"%s"}]' "$USR") ;;
      groups)  extra=$(printf ',"groups":[{"value":"%s"}]' "$GRP") ;;
      minimal) extra="" ;;
    esac
    printf '{"schemas":["urn:ietf:params:scim:schemas:extension:2.0:Role"],"displayName":"%s","audience":{"value":"%s","type":"application"}%s}' \
        "$1" "$APP" "$extra"
}

T_CREATE=$(tok internal_role_mgt_create)
T_WIDE=$(tok "internal_role_mgt_create internal_user_mgt_view internal_group_mgt_view")
T_WIDER=$(tok "internal_role_mgt_create internal_role_mgt_update internal_user_mgt_view internal_group_mgt_view internal_user_mgt_list")

rule "Which part of the body triggers the 403"
attempt "role_create        + minimal body" "$T_CREATE" p1 "$(body e2e_pr_1 minimal)"
attempt "role_create        + users"        "$T_CREATE" p2 "$(body e2e_pr_2 users)"
attempt "role_create        + groups"       "$T_CREATE" p3 "$(body e2e_pr_3 groups)"
attempt "role_create        + full body"    "$T_CREATE" p4 "$(body e2e_pr_4 full)"

rule "Does a wider scope set fix the full body"
attempt "role_create+user/group_view"       "$T_WIDE"  p5 "$(body e2e_pr_5 full)"
attempt "role_create+update+view+list"      "$T_WIDER" p6 "$(body e2e_pr_6 full)"
attempt "basic(admin)"                      "BASIC"    p7 "$(body e2e_pr_7 full)"

echo
echo "Done. Probe fixtures removed."

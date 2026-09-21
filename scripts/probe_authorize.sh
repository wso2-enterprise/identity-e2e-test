#!/bin/bash
# ============================================================
# The POST to authorized-apis returns 200 but stores zero scopes.
# This finds the call that actually attaches them.
#
# Established already:
#   - policyIdentifier must be 'RBAC' for management API resources
#     ('No Policy' -> APP-60512; anything else -> APP-60511)
#   - POST {id, policyIdentifier, scopes:[names]} -> 200, 0 scopes stored
#
# Cleans up after itself.
#   SERVER_URL=localhost:9443 ./scripts/probe_authorize.sh
# ============================================================

SERVER_URL="${SERVER_URL:-localhost:9443}"; SERVER_URL="${SERVER_URL%/}"
TENANT_DOMAIN="${TENANT_DOMAIN:-carbon.super}"
USERNAME="${IS_USERNAME:-admin}"; PASSWORD="${IS_PASSWORD:-admin}"
BASE="https://${SERVER_URL}/t/${TENANT_DOMAIN}"
AUTH=$(printf '%s' "${USERNAME}:${PASSWORD}" | base64 | tr -d '\n')
GET=(curl --silent --insecure -H "Authorization: Basic ${AUTH}" -H 'Accept: application/json')

app_id=$("${GET[@]}" --get "${BASE}/api/server/v1/applications" \
    --data-urlencode "filter=name eq E2E-Test-Suite-Token" | jq -r '.applications[0].id // empty')
[[ -z "$app_id" ]] && { echo "E2E-Test-Suite-Token not found."; exit 1; }
ASSIGN="${BASE}/api/server/v1/applications/${app_id}/authorized-apis"

RID="d30db941-5915-4f01-837f-856850c8947f"   # Offline User Onboard API
SCOPE="internal_offline_invite"
echo "app:      $app_id"
echo "resource: $RID  scope: $SCOPE"

stored_count() {
    "${GET[@]}" "$ASSIGN" | jq -r --arg id "$RID" \
        '[.[]? | select(.id==$id) | .scopes | length] | first // "not-authorized"'
}
show_entry() {
    echo "  entry now: $("${GET[@]}" "$ASSIGN" | jq -c --arg id "$RID" '.[]? | select(.id==$id)' | head -c 400)"
}
cleanup() {
    curl --silent --insecure -o /dev/null -X DELETE "${ASSIGN}/${RID}" -H "Authorization: Basic ${AUTH}"
}
call() {
    local method="$1" url="$2" payload="$3" resp code
    resp=$(curl --silent --insecure --write-out '\n%{http_code}' -X "$method" "$url" \
        -H "Authorization: Basic ${AUTH}" -H 'Content-Type: application/json' --data-raw "$payload")
    code="${resp##*$'\n'}"
    echo "  $method -> HTTP $code  $(echo "${resp%$'\n'*}" | head -c 300)"
}

echo
echo "=== A. POST then PATCH addedScopes ==="
cleanup
call POST "$ASSIGN" "$(jq -n --arg id "$RID" '{id:$id, policyIdentifier:"RBAC", scopes:[]}')"
echo "  scopes after POST: $(stored_count)"
call PATCH "${ASSIGN}/${RID}" "$(jq -n --arg s "$SCOPE" '{addedScopes:[$s], removedScopes:[]}')"
echo "  scopes after PATCH: $(stored_count)"
show_entry

echo
echo "=== B. POST with scopes as objects ==="
cleanup
call POST "$ASSIGN" "$(jq -n --arg id "$RID" --arg s "$SCOPE" \
    '{id:$id, policyIdentifier:"RBAC", scopes:[{name:$s}]}')"
echo "  scopes stored: $(stored_count)"

echo
echo "=== C. Does a token now carry the scope? ==="
cleanup
call POST "$ASSIGN" "$(jq -n --arg id "$RID" '{id:$id, policyIdentifier:"RBAC", scopes:[]}')"
call PATCH "${ASSIGN}/${RID}" "$(jq -n --arg s "$SCOPE" '{addedScopes:[$s], removedScopes:[]}')"
echo "  scopes stored: $(stored_count)"
oidc=$("${GET[@]}" "${BASE}/api/server/v1/applications/${app_id}/inbound-protocols/oidc")
cid=$(echo "$oidc" | jq -r '.clientId'); csec=$(echo "$oidc" | jq -r '.clientSecret')
echo "  token scope: $(curl --silent --insecure -X POST "${BASE}/oauth2/token" \
    -u "${cid}:${csec}" -d 'grant_type=client_credentials' -d "scope=${SCOPE}" \
    | jq -r '.scope // "(empty)"')"

echo
echo "=== D. Roles associated with the application ==="
echo "  $("${GET[@]}" "${BASE}/api/server/v1/applications/${app_id}" | jq -c '.associatedRoles' | head -c 300)"

cleanup
echo
echo "(cleaned up)"

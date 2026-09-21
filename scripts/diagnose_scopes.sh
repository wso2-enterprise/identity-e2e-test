#!/bin/bash
# ============================================================
# Reports why the E2E token carries no scopes.
# Read-only: lists state, changes nothing.
#   SERVER_URL=localhost:9443 ./scripts/diagnose_scopes.sh
# ============================================================

SERVER_URL="${SERVER_URL:-localhost:9443}"; SERVER_URL="${SERVER_URL%/}"
TENANT_DOMAIN="${TENANT_DOMAIN:-carbon.super}"
USERNAME="${IS_USERNAME:-admin}"; PASSWORD="${IS_PASSWORD:-admin}"
BASE="https://${SERVER_URL}/t/${TENANT_DOMAIN}"
AUTH=$(printf '%s' "${USERNAME}:${PASSWORD}" | base64 | tr -d '\n')
GET=(curl --silent --insecure -H "Authorization: Basic ${AUTH}" -H 'Accept: application/json')

echo "=== 1. Token application ==="
app_id=$("${GET[@]}" --get "${BASE}/api/server/v1/applications" \
    --data-urlencode "filter=name eq E2E-Test-Suite-Token" | jq -r '.applications[0].id // empty')
[[ -z "$app_id" ]] && { echo "E2E-Test-Suite-Token not found. Run create_and_assign_api_resources.sh first."; exit 1; }
echo "app id: $app_id"

creds=$("${GET[@]}" "${BASE}/api/server/v1/applications/${app_id}/inbound-protocols/oidc")
cid=$(echo "$creds" | jq -r '.clientId'); csec=$(echo "$creds" | jq -r '.clientSecret')
echo "grant types: $(echo "$creds" | jq -c '.grantTypes')"

echo
echo "=== 2. APIs authorized to it ==="
authz=$("${GET[@]}" "${BASE}/api/server/v1/applications/${app_id}/authorized-apis")
echo "count: $(echo "$authz" | jq 'if type=="array" then length else 0 end')"
echo "$authz" | jq -r 'if type=="array" then .[] | "  \(.displayName // .id)  policy=\(.policyId // "?")  scopes=\(.authorizedScopes|length)" else "  (unexpected response) \(.)" end' 2>/dev/null | head -20

echo
echo "=== 3. Is internal_application_mgt_view granted anywhere? ==="
echo "$authz" | jq -r '[.[]?.authorizedScopes[]?.name] | map(select(test("^internal_"))) | "internal_* scopes granted: \(length)"' 2>/dev/null

echo
echo "=== 4. What the token actually comes back with ==="
tok=$(curl --silent --insecure -X POST "${BASE}/oauth2/token" \
    -u "${cid}:${csec}" \
    -d 'grant_type=client_credentials' \
    -d 'scope=internal_application_mgt_view internal_user_mgt_view')
echo "$tok" | jq '{scope, token_type, expires_in}' 2>/dev/null || echo "$tok"
echo -n "granted scope field: "
echo "$tok" | jq -r '.scope // "(absent -- this is the problem)"'

echo
echo "=== 5. API resource inventory (what setup can see) ==="
res=$("${GET[@]}" "${BASE}/api/server/v1/api-resources?limit=100")
echo "returned by default listing: $(echo "$res" | jq '.apiResources | length')"
echo "by type:"
echo "$res" | jq -r '.apiResources | group_by(.type)[] | "  \(.[0].type): \(length)"'
echo "does the default listing contain the Management API resources?"
echo "$res" | jq -r '.apiResources[] | select(.name|test("Management|Application|User";"i")) | "  \(.name) [\(.type)]"' | head -10

echo
echo "=== 6. Total across all types ==="
for t in SYSTEM TENANT ORGANIZATION BUSINESS CONSOLE_FEATURE; do
    n=$("${GET[@]}" --get "${BASE}/api/server/v1/api-resources" \
        --data-urlencode "filter=type eq ${t}" --data-urlencode "limit=100" \
        | jq '.apiResources | length' 2>/dev/null)
    echo "  type=${t}: ${n:-error}"
done

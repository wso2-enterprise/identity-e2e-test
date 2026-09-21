#!/bin/bash

# Check if server URL is provided as an environment variable
SERVER_URL=${SERVER_URL:-"localhost:9443"}

# Remove trailing slash if present
SERVER_URL=${SERVER_URL%/}
echo "Using WSO2 Identity Server at: ${SERVER_URL}"

# Base URLs
BASE_URL_API_RESOURCES="https://${SERVER_URL}/t/carbon.super/api/server/v1/api-resources"
BASE_URL_CREATE_APP="https://${SERVER_URL}/t/carbon.super/api/server/v1/applications"
BASE_URL_GET_APP_ID="https://${SERVER_URL}/t/carbon.super/api/server/v1/applications?filter=name+eq+E2E-Test-Suite-Token"
BASE_URL_ASSIGN_APIS="https://${SERVER_URL}/t/carbon.super/api/server/v1/applications/%s/authorized-apis"  # Placeholder for app ID

# Admin credentials
USERNAME='admin'
PASSWORD='admin'

# Create the Authorization header.
# NOTE: printf, not echo -- echo appends a newline, which lands inside the
# base64 payload and makes the server see the password as "admin\n". Every
# request then 401s, the API resources never get authorized, and the suite
# fails later with a wall of confusing 403s.
AUTH=$(printf '%s' "$USERNAME:$PASSWORD" | base64 | tr -d '\n')

# Fail loudly right here if those credentials do not work, rather than
# limping on and leaving the application with no authorized scopes.
preflight_auth() {
    local code
    code=$(curl --silent --insecure --output /dev/null --write-out '%{http_code}' \
        "https://${SERVER_URL}/t/carbon.super/api/server/v1/applications?limit=1" \
        -H "Authorization: Basic $AUTH" -H 'Accept: application/json')

    if [[ "$code" != "200" ]]; then
        echo "ERROR: admin credentials rejected by ${SERVER_URL} (HTTP ${code})."
        echo "       Check USERNAME/PASSWORD at the top of this script."
        exit 1
    fi
    echo "Admin credentials verified against ${SERVER_URL}."
}

# Output file to store all API resources
OUTPUT_FILE="api_resources.json"

# Clear the output file before starting
> "$OUTPUT_FILE"

# Function to create the application
create_application() {
    echo "Creating application 'E2E-Test-Suite-Token'..."

    create_app_response=$(curl --silent --insecure --location "$BASE_URL_CREATE_APP" \
        --header "Authorization: Basic $AUTH" \
        --header 'Content-Type: application/json' \
        --data-raw '{
            "name": "E2E-Test-Suite-Token",
            "advancedConfigurations": {
                "skipLogoutConsent": true,
                "skipLoginConsent": true
            },
            "templateId": "custom-application-oidc",
            "associatedRoles": {
                "allowedAudience": "APPLICATION",
                "roles": []
            },
            "inboundProtocolConfiguration": {
                "oidc": {
                    "grantTypes": ["client_credentials"],
                    "isFAPIApplication": false
                }
            }
        }')

    echo "Response from application creation:"
    echo "$create_app_response"
}

# Function to get the application ID
get_application_id() {
    echo "Fetching the application ID for 'E2E-Test-Suite-Token'..."

    get_app_response=$(curl --silent --insecure --location "$BASE_URL_GET_APP_ID" \
        --header "Authorization: Basic $AUTH" \
        --header 'Accept: application/json')

    # Parse the application ID from the response
    app_id=$(echo "$get_app_response" | jq -r '.applications[0].id')

    if [[ "$app_id" == "null" || -z "$app_id" ]]; then
        echo "Failed to find the application ID."
        exit 1
    else
        echo "Application ID: $app_id"
        echo "$app_id" > app_id.txt  # Save the app ID for further use
    fi
}

# Which API resource types carry the management-API scopes the suite needs.
# CONSOLE_FEATURE / CONSOLE_ORG_FEATURE are Console UI features, not APIs.
API_RESOURCE_TYPES="${API_RESOURCE_TYPES:-SYSTEM TENANT ORGANIZATION}"

# Drop whatever is currently authorized before re-authorizing. Re-POSTing an
# already-authorized API is rejected, so without this a re-run silently keeps
# what the last run left behind -- which is how the app ended up with 10
# entries pinned at policy=RBAC and zero scopes.
reset_authorized_apis() {
    local app_id="$1"
    local url ids count=0
    url=$(printf "$BASE_URL_ASSIGN_APIS" "$app_id")

    ids=$(curl --silent --insecure "$url" \
            -H "Authorization: Basic $AUTH" -H 'Accept: application/json' \
          | jq -r 'if type=="array" then .[].id else empty end' 2>/dev/null)

    for id in $ids; do
        curl --silent --insecure --output /dev/null -X DELETE "${url}/${id}" \
            -H "Authorization: Basic $AUTH"
        count=$((count + 1))
    done
    echo "Cleared ${count} previously authorized API resource(s)."
}

# Scopes hang off the resource's /scopes sub-resource. The resource detail that
# the old code read returns an empty scopes array, which is why every previous
# authorization was created carrying no scopes at all.
resource_scope_names() {
    local resource_id="$1"
    curl --silent --insecure "${BASE_URL_API_RESOURCES}/${resource_id}/scopes" \
        -H "Authorization: Basic $AUTH" -H 'Accept: application/json' \
    | jq -c 'if type=="array" then [.[].name]
             elif type=="object" and has("scopes") then [.scopes[].name]
             else [] end' 2>/dev/null
}

# Walk every page of every relevant type. The old code followed the "next"
# link by handing curl a relative href, so it never got past the first page of
# 10 -- out of roughly 170 resources.
authorize_api_resources() {
    local app_id="$1"
    local assign_url policy page after next_href resource_id scopes body code
    local authorized=0 skipped=0 failed=0 duplicates=0 preauthorized=0
    assign_url=$(printf "$BASE_URL_ASSIGN_APIS" "$app_id")
    policy="${POLICY_IDENTIFIER:-RBAC}"

    # A resource can appear under more than one type filter, and POSTing it
    # twice returns 409 "API resource already authorized". Track what has been
    # handled so the second sighting is skipped rather than counted as failed.
    local -A seen=()

    echo "Authorizing API resources (types: ${API_RESOURCE_TYPES}; policy: ${policy})..."

    for type in $API_RESOURCE_TYPES; do
        after=""
        while : ; do
            local -a q=(--data-urlencode "filter=type eq ${type}" --data-urlencode "limit=100")
            [[ -n "$after" ]] && q+=(--data-urlencode "after=${after}")

            page=$(curl --silent --insecure --get "${BASE_URL_API_RESOURCES}" "${q[@]}" \
                -H "Authorization: Basic $AUTH" -H 'Accept: application/json')

            if ! echo "$page" | jq -e '.apiResources' >/dev/null 2>&1; then
                echo "  WARNING: could not list type ${type}. Skipping."
                break
            fi

            while read -r resource_id; do
                [[ -z "$resource_id" || "$resource_id" == "null" ]] && continue

                if [[ -n "${seen[$resource_id]:-}" ]]; then
                    duplicates=$((duplicates + 1))
                    continue
                fi
                seen[$resource_id]=1

                scopes=$(resource_scope_names "$resource_id")
                if [[ -z "$scopes" || "$scopes" == "[]" ]]; then
                    skipped=$((skipped + 1))
                    continue
                fi

                # Two calls are needed. POST registers the API resource but
                # ignores any scopes in its body; PATCH addedScopes is what
                # actually attaches them (they then read back under
                # "authorizedScopes", not "scopes").
                body=$(jq -n --arg id "$resource_id" --arg p "$policy" \
                        '{id: $id, policyIdentifier: $p, scopes: []}')

                # Keep the response body: a bare status code says nothing about
                # WHY the server refused the payload.
                local resp
                resp=$(curl --silent --insecure --write-out '\n%{http_code}' \
                    -X POST "$assign_url" -H "Authorization: Basic $AUTH" \
                    -H 'Content-Type: application/json' --data-raw "$body")
                code="${resp##*$'\n'}"
                local err="${resp%$'\n'*}"

                # 409 APP-60509 means the resource is already attached -- some
                # resources get authorized implicitly as a side effect of
                # authorizing another. That is not a failure, but its scopes
                # still need attaching, so fall through to the PATCH.
                if [[ "$code" == "409" ]]; then
                    preauthorized=$((preauthorized + 1))
                    code=200
                fi

                if [[ "$code" =~ ^2 ]]; then
                    local patch_body patch_resp patch_code
                    patch_body=$(jq -n --argjson s "$scopes" \
                        '{addedScopes: $s, removedScopes: []}')
                    patch_resp=$(curl --silent --insecure --write-out '\n%{http_code}' \
                        -X PATCH "${assign_url}/${resource_id}" \
                        -H "Authorization: Basic $AUTH" \
                        -H 'Content-Type: application/json' --data-raw "$patch_body")
                    patch_code="${patch_resp##*$'\n'}"
                    if ! [[ "$patch_code" =~ ^2 ]]; then
                        code="$patch_code"
                        err="scope attach failed: ${patch_resp%$'\n'*}"
                    fi
                fi

                if [[ "$code" =~ ^2 ]]; then
                    authorized=$((authorized + 1))
                    echo "$body" >> "$OUTPUT_FILE"
                else
                    failed=$((failed + 1))
                    # Print the server's reason for the first few only; beyond
                    # that the cause is the same and the noise is unhelpful.
                    if [[ $failed -le 3 ]]; then
                        echo "  WARNING: ${resource_id} not authorized (HTTP ${code})"
                        echo "    sent:  $(echo "$body" | head -c 300)"
                        echo "    error: $(echo "$err" | head -c 400)"
                    elif [[ $failed -eq 4 ]]; then
                        echo "  (further authorization failures suppressed)"
                    fi
                fi
            done < <(echo "$page" | jq -r '.apiResources[].id')

            next_href=$(echo "$page" | jq -r '.links[]? | select(.rel=="next") | .href // empty')
            [[ -z "$next_href" ]] && break
            after=$(sed -n 's/.*[?&]after=\([^&]*\).*/\1/p' <<<"$next_href")
            [[ -z "$after" ]] && break
        done
    done

    echo "Authorized ${authorized} API resource(s) (${preauthorized} were already attached); ${skipped} had no scopes; ${duplicates} listed under more than one type; ${failed} failed."
}

# Step 0: Verify admin credentials before doing anything else
preflight_auth

# Step 1: Create the application
create_application

# Step 2: Get the application ID
get_application_id

# Step 3: Clear stale authorizations, then authorize every relevant resource
reset_authorized_apis "$app_id"
authorize_api_resources "$app_id"

# Step 4: Assign the fetched API resources to the application
if [[ -f app_id.txt ]]; then
    app_id=$(<app_id.txt)  # Read the application ID from the saved file
    # assign_api_resources "$app_id"
else
    echo "Application ID file not found. Cannot assign API resources."
    exit 1
fi

# Step 5: Confirm the application ended up with authorized APIs AND that a
# real token actually carries scopes. The count alone is not enough -- the
# previous failure mode was 10 authorized APIs all holding zero scopes, which
# still issues a token, just an empty one that 403s on every call.
verify_url=$(printf "$BASE_URL_ASSIGN_APIS" "$app_id")
authorized_json=$(curl --silent --insecure "$verify_url" \
    -H "Authorization: Basic $AUTH" -H 'Accept: application/json')

authorized_count=$(echo "$authorized_json" | jq -r 'if type=="array" then length else 0 end' 2>/dev/null)
scope_total=$(echo "$authorized_json" | jq -r '[.[]?.authorizedScopes[]?] | length' 2>/dev/null)

if [[ -z "$authorized_count" || "$authorized_count" == "0" ]]; then
    echo "ERROR: application $app_id has no authorized API resources."
    exit 1
fi

if [[ -z "$scope_total" || "$scope_total" == "0" ]]; then
    echo "ERROR: $authorized_count API resource(s) authorized, but they carry 0 scopes."
    echo "       Tokens would be issued empty and every request would 403."
    exit 1
fi

# End-to-end check: mint a token the way the collections do and confirm the
# server puts something in the scope field.
oidc=$(curl --silent --insecure \
    "https://${SERVER_URL}/t/carbon.super/api/server/v1/applications/${app_id}/inbound-protocols/oidc" \
    -H "Authorization: Basic $AUTH" -H 'Accept: application/json')
client_id=$(echo "$oidc" | jq -r '.clientId')
client_secret=$(echo "$oidc" | jq -r '.clientSecret')

granted=$(curl --silent --insecure -X POST "https://${SERVER_URL}/t/carbon.super/oauth2/token" \
    -u "${client_id}:${client_secret}" \
    -d 'grant_type=client_credentials' \
    -d 'scope=internal_application_mgt_view' \
    | jq -r '.scope // empty')

if [[ -z "$granted" ]]; then
    echo "ERROR: token request returned no scope despite ${scope_total} scope(s) being authorized."
    echo "       Valid policy literals are 'RBAC' and 'No Policy'; management"
    echo "       API resources accept RBAC only."
    exit 1
fi

echo "Verified: ${authorized_count} API resource(s), ${scope_total} scope(s) authorized."
echo "Verified: token issued with scope -> ${granted}"
echo "API resources have been assigned to the application."

#!/bin/bash

# ============================================================
# WSO2 Identity Server - E2E test artifact cleanup
#
# The collections create resources under fixed, hardcoded names and delete
# them again in their teardown steps. A run that dies partway leaves those
# behind, and the next run's create steps then fail with 409 Conflict --
# failures that look like server faults but are just leftovers.
#
# This removes them so every run starts from a known state. It is idempotent:
# anything already absent is skipped, and no failure here aborts the caller.
#
# Usage:  SERVER_URL=localhost:9443 ./scripts/cleanup_test_artifacts.sh
# ============================================================

SERVER_URL="${SERVER_URL:-localhost:9443}"
SERVER_URL="${SERVER_URL%/}"
TENANT_DOMAIN="${TENANT_DOMAIN:-carbon.super}"
USERNAME="${IS_USERNAME:-admin}"
PASSWORD="${IS_PASSWORD:-admin}"

BASE="https://${SERVER_URL}/t/${TENANT_DOMAIN}"
AUTH=$(printf '%s' "${USERNAME}:${PASSWORD}" | base64 | tr -d '\n')

REMOVED=0
SKIPPED=0

say() { echo "  $*"; }

# Resolve a resource by name via a filtered list, then DELETE it by id.
#   $1 list path   $2 jq path to the id   $3 filter attribute   $4 name   $5 delete path prefix
delete_by_name() {
    local list_path="$1" id_path="$2" attr="$3" name="$4" del_path="$5"
    local id

    id=$(curl --silent --insecure --get "${BASE}/${list_path}" \
            --data-urlencode "filter=${attr} eq ${name}" \
            -H "Authorization: Basic ${AUTH}" -H 'Accept: application/json' \
        | jq -r "${id_path} // empty" 2>/dev/null)

    if [[ -z "$id" || "$id" == "null" ]]; then
        SKIPPED=$((SKIPPED + 1))
        return 0
    fi

    local code
    code=$(curl --silent --insecure --output /dev/null --write-out '%{http_code}' \
        -X DELETE "${BASE}/${del_path}/${id}" \
        -H "Authorization: Basic ${AUTH}")

    if [[ "$code" =~ ^2 ]]; then
        say "removed ${name} (${id})"
        REMOVED=$((REMOVED + 1))
    else
        say "WARNING: could not remove ${name} (HTTP ${code}) -- continuing"
    fi
}

# DELETE a resource addressed directly by its name.
delete_at_path() {
    local label="$1" path="$2"
    local code
    code=$(curl --silent --insecure --output /dev/null --write-out '%{http_code}' \
        -X DELETE "${BASE}/${path}" -H "Authorization: Basic ${AUTH}")

    case "$code" in
        2*)     say "removed ${label}";        REMOVED=$((REMOVED + 1)) ;;
        404)    SKIPPED=$((SKIPPED + 1)) ;;
        *)      say "WARNING: could not remove ${label} (HTTP ${code}) -- continuing" ;;
    esac
}

# DELETE every SCIM role sharing a displayName. Unlike delete_by_name this does
# not stop at the first match: two roles may share a name when their audiences
# differ. collection01 leaves "loginRole" on the "New Application" audience and
# collection02 leaves one on E2E-Test-Suite-Token, which this script preserves.
#
# Resolution goes through POST /scim2/v2/Roles/.search, the lookup the
# collections themselves use, rather than a filter on GET. The
# select(.displayName == $name) guard is load-bearing: if the server ever
# ignores the filter and answers with the whole role list, an unguarded
# .Resources[].id would delete every role in the tenant, "everyone" and the
# admin roles included. Never take the ids on trust -- match the name here.
delete_roles_by_name() {
    local name="$1" ids id code
    ids=$(curl --silent --insecure -X POST "${BASE}/scim2/v2/Roles/.search" \
            -H "Authorization: Basic ${AUTH}" \
            -H 'Content-Type: application/scim+json' \
            --data-raw "{\"schemas\":[\"urn:ietf:params:scim:api:messages:2.0:SearchRequest\"],\"startIndex\":1,\"filter\":\"displayName eq ${name}\"}" \
        | jq -r --arg name "$name" '.Resources[]? | select(.displayName == $name) | .id' 2>/dev/null)

    if [[ -z "$ids" ]]; then
        SKIPPED=$((SKIPPED + 1))
        return 0
    fi

    while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        code=$(curl --silent --insecure --output /dev/null --write-out '%{http_code}' \
            -X DELETE "${BASE}/scim2/v2/Roles/${id}" \
            -H "Authorization: Basic ${AUTH}")
        if [[ "$code" =~ ^2 ]]; then
            say "removed role ${name} (${id})"
            REMOVED=$((REMOVED + 1))
        else
            say "WARNING: could not remove role ${name} (HTTP ${code}) -- continuing"
        fi
    done <<< "$ids"
}

echo "Cleaning up E2E test artifacts on ${SERVER_URL} (tenant: ${TENANT_DOMAIN})..."

# Verify credentials first; without them every call below is a silent no-op.
code=$(curl --silent --insecure --output /dev/null --write-out '%{http_code}' \
    "${BASE}/api/server/v1/applications?limit=1" -H "Authorization: Basic ${AUTH}")
if [[ "$code" != "200" ]]; then
    echo "ERROR: admin credentials rejected by ${SERVER_URL} (HTTP ${code}). Skipping cleanup."
    exit 1
fi

# --- Applications -------------------------------------------------------
# E2E-Test-Suite-Token is deliberately NOT in this list: it is the
# client_credentials app the collections mint their tokens with.
for app in "Application_Passive_STS" "Application_SAML" "New Application" \
           "OIDC Protocol Template" "cas" "isInternalApp" "pickup"; do
    delete_by_name "api/server/v1/applications" ".applications[0].id" "name" "$app" \
                   "api/server/v1/applications"
done

# --- Organizations ------------------------------------------------------
for org in "ABC Builders" "Test Organization" "XYZ Builders"; do
    delete_by_name "api/server/v1/organizations" ".organizations[0].id" "name" "$org" \
                   "api/server/v1/organizations"
done

# --- SCIM 2.0 users -----------------------------------------------------
for user in "Malcome" "kim" "PRIMARY/MainDomainUser01"; do
    delete_by_name "scim2/Users" ".Resources[0].id" "userName" "$user" "scim2/Users"
done

# --- SCIM 2.0 groups ----------------------------------------------------
for group in "Organizor" "manager"; do
    delete_by_name "scim2/Groups" ".Resources[0].id" "displayName" "$group" "scim2/Groups"
done

# --- SCIM 2.0 roles -----------------------------------------------------
# Neither collection deletes the roles it creates. collection01 creates
# "organizer_role" and renames it to "loginRole"; collection02 creates its
# own "loginRole" against the E2E-Test-Suite-Token application, which this
# script deliberately keeps. Both outlive the run, so the next run's create
# returns 409 Conflict.
for role in "loginRole" "organizer_role"; do
    delete_roles_by_name "$role"
done

# --- Identity providers -------------------------------------------------
for idp in "Enterprise IDP" "google"; do
    delete_by_name "api/server/v1/identity-providers" ".identityProviders[0].id" "name" "$idp" \
                   "api/server/v1/identity-providers"
done

# --- Resources addressed by name directly -------------------------------
delete_at_path "OIDC scope Scope1"          "api/server/v1/oidc/scopes/Scope1"
delete_at_path "OAuth2 scope NewScope"      "api/identity/oauth2/v1.0/scopes/name/NewScope"
delete_at_path "script library networkUtils.js" "api/server/v1/script-libraries/networkUtils.js"

# --- Secondary userstore ------------------------------------------------
# Userstore deletion can be refused while the store is still in use; a
# warning here is not fatal.
store_id=$(curl --silent --insecure "${BASE}/api/server/v1/userstores" \
    -H "Authorization: Basic ${AUTH}" -H 'Accept: application/json' \
    | jq -r '.[]? | select(.name=="MyUserStore") | .id' 2>/dev/null | head -1)
if [[ -n "$store_id" ]]; then
    delete_at_path "userstore MyUserStore" "api/server/v1/userstores/${store_id}"
else
    SKIPPED=$((SKIPPED + 1))
fi

echo "Cleanup finished: ${REMOVED} removed, ${SKIPPED} already absent."
exit 0

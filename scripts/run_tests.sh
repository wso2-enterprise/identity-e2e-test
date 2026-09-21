#!/bin/bash

# ============================================================
# WSO2 Identity Server - Postman Collection Test Runner
# Runs the E2E test suite against a WSO2 IS Docker container
# ============================================================

set -uo pipefail

# -------------------------------------------------------
# Configuration — override via environment variables
# -------------------------------------------------------
IS_HOST="${IS_HOST:-localhost}"
IS_PORT="${IS_PORT:-9443}"
IS_USERNAME="${IS_USERNAME:-admin}"
IS_PASSWORD="${IS_PASSWORD:-admin}"
TENANT_DOMAIN="${TENANT_DOMAIN:-carbon.super}"
DELAY_BEFORE_TESTS="${DELAY_BEFORE_TESTS:-5}"   # seconds to wait for IS to be ready

SERVER_URL="${IS_HOST}:${IS_PORT}"
TOKEN_URL="https://${SERVER_URL}/t/${TENANT_DOMAIN}/oauth2/token"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(dirname "$SCRIPT_DIR")}"
COLLECTION_DIR="${COLLECTION_DIR:-${REPO_ROOT}/Postman}"

REPORT_DIR="${REPO_ROOT}/newman-reports"
mkdir -p "$REPORT_DIR"

# Collections are rewritten into this directory before they run, so that the
# <WSO2_SERVER_URL> placeholders baked into their collection variables point at
# the server under test. See prepare_collection().
PREPARED_DIR="$(mktemp -d)"
trap 'rm -rf "$PREPARED_DIR"' EXIT

# -------------------------------------------------------
# Helper functions
# -------------------------------------------------------
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail() { echo "[ERROR] $*" >&2; exit 1; }

install_prerequisites() {
    log "Checking and installing prerequisites..."

    # --- Node.js / npm ---
    if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
        log "Node.js/npm not found. Installing via package manager..."
        if command -v brew >/dev/null 2>&1; then
            brew install node
        elif command -v apt-get >/dev/null 2>&1; then
            sudo apt-get update -qq && sudo apt-get install -y nodejs npm
        elif command -v yum >/dev/null 2>&1; then
            sudo yum install -y nodejs npm
        else
            fail "Cannot install Node.js automatically. Please install Node.js (https://nodejs.org) and re-run."
        fi
    else
        log "Node.js $(node --version) / npm $(npm --version) already installed. Skipping."
    fi

    # --- curl ---
    if ! command -v curl >/dev/null 2>&1; then
        log "curl not found. Installing..."
        if command -v brew >/dev/null 2>&1; then
            brew install curl
        elif command -v apt-get >/dev/null 2>&1; then
            sudo apt-get install -y curl
        elif command -v yum >/dev/null 2>&1; then
            sudo yum install -y curl
        else
            fail "Cannot install curl automatically. Please install curl and re-run."
        fi
    else
        log "curl $(curl --version | head -1) already installed. Skipping."
    fi

    # --- jq ---
    if ! command -v jq >/dev/null 2>&1; then
        log "jq not found. Installing..."
        if command -v brew >/dev/null 2>&1; then
            brew install jq
        elif command -v apt-get >/dev/null 2>&1; then
            sudo apt-get install -y jq
        elif command -v yum >/dev/null 2>&1; then
            sudo yum install -y jq
        else
            fail "Cannot install jq automatically. Please install jq (https://stedolan.github.io/jq/) and re-run."
        fi
    else
        log "jq $(jq --version) already installed. Skipping."
    fi

    # --- Configure a user-local npm prefix to avoid permission issues ---
    NPM_GLOBAL_PREFIX="${HOME}/.npm-global"
    mkdir -p "${NPM_GLOBAL_PREFIX}"
    npm config set prefix "${NPM_GLOBAL_PREFIX}"
    NPM_GLOBAL_BIN="${NPM_GLOBAL_PREFIX}/bin"
    export PATH="${NPM_GLOBAL_BIN}:${PATH}"
    log "npm global prefix set to: ${NPM_GLOBAL_PREFIX}"

    # --- newman ---
    if ! command -v newman >/dev/null 2>&1; then
        log "newman not found. Installing into ${NPM_GLOBAL_PREFIX}..."
        npm install -g newman
    else
        log "newman $(newman --version) already installed. Skipping."
    fi

    # --- newman-reporter-htmlextra ---
    if ! npm list -g newman-reporter-htmlextra --depth=0 >/dev/null 2>&1; then
        log "newman-reporter-htmlextra not found. Installing into ${NPM_GLOBAL_PREFIX}..."
        npm install -g newman-reporter-htmlextra
    else
        log "newman-reporter-htmlextra already installed. Skipping."
    fi

    # Final check — fail early with a clear message if newman is still not found
    command -v newman >/dev/null 2>&1 || \
        fail "newman still not found after installation. Ensure '${NPM_GLOBAL_BIN}' is on your PATH."

    log "All prerequisites satisfied."
}

wait_for_is() {
    log "Waiting for WSO2 Identity Server at ${SERVER_URL} to be ready..."
    local max_attempts=30
    local attempt=0
    until curl --silent --insecure --output /dev/null \
               --write-out "%{http_code}" \
               "https://${SERVER_URL}/carbon/admin/login.jsp" | grep -qE "^[23]"; do
        attempt=$((attempt + 1))
        if [[ $attempt -ge $max_attempts ]]; then
            fail "WSO2 IS did not become ready after ${max_attempts} attempts. Aborting."
        fi
        log "  Not ready yet (attempt ${attempt}/${max_attempts}). Retrying in 10s..."
        sleep 10
    done
    log "WSO2 Identity Server is ready."
    sleep "$DELAY_BEFORE_TESTS"
}

# The collections carry "<WSO2_SERVER_URL>" in their collection-scope variables.
# Requests interpolate {{serverUrl}}, which --env-var can override, but the
# pre-request scripts read pm.collectionVariables.get("token_url") directly and
# the collection scope is never touched by --env-var. Substitute the real host
# into a throwaway copy instead.
prepare_collection() {
    local src="$1" dst="$2"
    sed -e "s|<WSO2_SERVER_URL>|${SERVER_URL}|g" \
        -e "s|https://${SERVER_URL}/t/carbon.super/oauth2/token|${TOKEN_URL}|g" \
        "$src" > "$dst"

    if grep -q "<WSO2_SERVER_URL>" "$dst"; then
        fail "Failed to substitute <WSO2_SERVER_URL> in $(basename "$src")."
    fi
}

run_collection() {
    local collection_file="$1"
    local collection_name
    collection_name="$(basename "$collection_file" .json)"

    local prepared="${PREPARED_DIR}/$(basename "$collection_file")"
    prepare_collection "$collection_file" "$prepared"
    local report_html="${REPORT_DIR}/${collection_name}-report.html"
    local report_json="${REPORT_DIR}/${collection_name}-results.json"

    log "Running collection: ${collection_name}"

    local rc=0
    # The prepared copy lives in a temp dir, so relative formdata file paths
    # (files/networkUtils.js) have to resolve against the real collection dir.
    newman run "$prepared" \
        --insecure \
        --working-dir "${COLLECTION_DIR}" \
        --timeout-request 30000 \
        --env-var "serverUrl=${SERVER_URL}" \
        --env-var "tenantDomain=${TENANT_DOMAIN}" \
        --env-var "token_url=${TOKEN_URL}" \
        --env-var "username=${IS_USERNAME}" \
        --env-var "password=${IS_PASSWORD}" \
        --reporters cli,htmlextra,json \
        --reporter-htmlextra-export "$report_html" \
        --reporter-json-export "$report_json" \
        --color on || rc=$?

    if [[ $rc -ne 0 ]]; then
        log "Collection '${collection_name}' had test failures (exit code: ${rc}). Check report: ${report_html}"
        return 1
    fi

    log "Collection '${collection_name}' finished successfully."
}

# -------------------------------------------------------
# Main
# -------------------------------------------------------
log "============================================================"
log " WSO2 Identity Server E2E Test Runner"
log "============================================================"
log "  Server   : https://${SERVER_URL}"
log "  Tenant   : ${TENANT_DOMAIN}"
log "  Username : ${IS_USERNAME}"
log "  Reports  : ${REPORT_DIR}"
log "============================================================"

install_prerequisites

wait_for_is

# Remove artifacts left behind by an earlier run. The collections create
# resources under fixed names, so leftovers make the next run's create steps
# fail with 409. Set SKIP_CLEANUP=1 to keep them.
if [[ "${SKIP_CLEANUP:-0}" == "1" ]]; then
    log "SKIP_CLEANUP=1 set. Leaving existing test artifacts in place."
elif [[ -f "${SCRIPT_DIR}/cleanup_test_artifacts.sh" ]]; then
    log "Cleaning up artifacts from previous runs..."
    SERVER_URL="${SERVER_URL}" TENANT_DOMAIN="${TENANT_DOMAIN}" \
        IS_USERNAME="${IS_USERNAME}" IS_PASSWORD="${IS_PASSWORD}" \
        bash "${SCRIPT_DIR}/cleanup_test_artifacts.sh" \
        || log "WARNING: Cleanup reported problems. Continuing anyway."
else
    log "WARNING: Cleanup script not found at ${SCRIPT_DIR}/cleanup_test_artifacts.sh. Skipping."
fi

# Run the setup script (creates the token app and authorizes the API resources
# whose scopes every request in the collections depends on). A failure here is
# fatal: without those scopes the tokens are issued but carry no permissions,
# and the whole suite fails with 403s that look like server faults.
if [[ -f "${SCRIPT_DIR}/create_and_assign_api_resources.sh" ]]; then
    log "Running setup: create_and_assign_api_resources.sh..."
    if ! SERVER_URL="${SERVER_URL}" bash "${SCRIPT_DIR}/create_and_assign_api_resources.sh"; then
        fail "Setup failed. The test app would have no authorized scopes, so every request would return 403. Aborting."
    fi
    log "Setup completed."
else
    fail "Setup script not found at ${SCRIPT_DIR}/create_and_assign_api_resources.sh. The suite cannot authenticate without it."
fi

# Run collections
FAILED_COLLECTIONS=()

for collection in \
    "${COLLECTION_DIR}/collection01.json" \
    "${COLLECTION_DIR}/collection02.json"; do

    if [[ ! -f "$collection" ]]; then
        log "WARNING: Collection file not found: ${collection}. Skipping."
        continue
    fi

    if ! run_collection "$collection"; then
        FAILED_COLLECTIONS+=("$(basename "$collection")")
    fi
    log "Continuing to next collection (if any)..."
done

# Summary
log "============================================================"
if [[ ${#FAILED_COLLECTIONS[@]} -eq 0 ]]; then
    log " All collections passed successfully!"
    log " HTML reports: ${REPORT_DIR}"
    log "============================================================"
    exit 0
else
    log " The following collections had failures:"
    for c in "${FAILED_COLLECTIONS[@]}"; do
        log "   - ${c}"
    done
    log " HTML reports: ${REPORT_DIR}"
    log "============================================================"
    exit 1
fi

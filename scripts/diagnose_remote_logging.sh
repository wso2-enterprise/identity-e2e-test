#!/bin/bash
# ============================================================
# Pin down the CNF-65008 failure on the remote logging reset.
#
# collection01 runs, in order:
#     #265 PUT    /configs/remote-logging            (global update, ARRAY body)
#     #266 GET    /configs/remote-logging
#     #267 GET    /configs/remote-logging/audit
#     #268 PUT    /configs/remote-logging/audit      (per-type update)
#     #269 DELETE /configs/remote-logging/audit      (per-type reset)  -> 204
#     #270 DELETE /configs/remote-logging            (global reset)    -> 500 CNF-65008
#
# An earlier run of this script established, against a server whose
# GET /configs/remote-logging returned []:
#     global  DELETE -> 500     (three times, non-idempotent is not the issue)
#     audit   DELETE -> 500
# i.e. with NO config present, BOTH resets fail. That matches the suite:
# #269 removes the only config, so #270 has nothing left to reset.
#
# The one case that run could not test is the reset with a config PRESENT,
# because the state was empty throughout and the per-type PUT was malformed
# (it carried "logType", which this endpoint takes from the path -> UE-10000).
# The bodies below are copied from the collection.
#
#   Probe E: create, confirm present, then GLOBAL reset      <- the decisive one
#   Probe F: create, then the suite's order  (per-type, then global)
#   Probe G: create, then the swapped order  (global, then per-type)
#
# Only touches remote logging config, which the suite already resets.
# ============================================================

set -uo pipefail

SERVER_URL="${SERVER_URL:-localhost:9443}"; SERVER_URL="${SERVER_URL%/}"
TENANT="${TENANT_DOMAIN:-carbon.super}"
LOG_TYPE="${LOG_TYPE:-audit}"

BASE="https://${SERVER_URL}/t/${TENANT}/api/server/v1/configs/remote-logging"
AUTH=$(printf '%s' "${IS_USERNAME:-admin}:${IS_PASSWORD:-admin}" | base64 | tr -d '\n')

# Body of collection01 #265 -- a JSON ARRAY, with logType in the object.
GLOBAL_BODY='[{"remoteUrl":"https://test.remote.server.com/api/log","connectTimeoutMillis":"5000","verifyHostname":true,"logType":"AUDIT","username":"admin","password":"admin","keystoreLocation":"https://keystorelocation","keystorePassword":"keYstore198","truststoreLocation":"https://truststorelocation","truststorePassword":"trUst342"}]'

# Body of collection01 #268 -- a single object, NO logType (it is the path).
TYPE_BODY='{"remoteUrl":"https://test.remote.server.com/api/log","connectTimeoutMillis":"5000","verifyHostname":true,"username":"admin","password":"admin","keystoreLocation":"https://keystorelocation","keystorePassword":"KeyStore890","truststoreLocation":"https://truststorelocation","truststorePassword":"TrustStore947"}'

rule() { printf '\n========== %s ==========\n' "$1"; }

# call METHOD URL [body] -> prints status + body
call() {
    local method="$1" url="$2" body="${3:-}" out code
    if [[ -n "$body" ]]; then
        out=$(curl -sk -w '\n%{http_code}' -X "$method" "$url" \
                -H "Authorization: Basic ${AUTH}" \
                -H 'Content-Type: application/json' -d "$body")
    else
        out=$(curl -sk -w '\n%{http_code}' -X "$method" "$url" \
                -H "Authorization: Basic ${AUTH}" -H 'Accept: application/json')
    fi
    code=$(printf '%s' "$out" | tail -1)
    printf '  %-6s %-58s -> %s\n' "$method" "${url#https://${SERVER_URL}}" "$code"
    local payload
    payload=$(printf '%s' "$out" | sed '$d')
    [[ -n "${payload//[[:space:]]/}" ]] && printf '%s\n' "$payload" | cut -c1-200 | sed 's/^/         /'
    return 0
}

echo "Remote logging reset diagnosis on ${SERVER_URL} (tenant: ${TENANT}, logType: ${LOG_TYPE})"

rule "baseline state"
call GET "${BASE}"

rule "Probe E: create a config, confirm it is there, then GLOBAL reset"
call PUT "${BASE}" "${GLOBAL_BODY}"
call GET "${BASE}"
call DELETE "${BASE}"
call GET "${BASE}"

rule "Probe F: create, then the suite's order -- per-type reset, then global reset"
call PUT "${BASE}" "${GLOBAL_BODY}"
call PUT "${BASE}/${LOG_TYPE}" "${TYPE_BODY}"
call DELETE "${BASE}/${LOG_TYPE}"
call GET "${BASE}"
call DELETE "${BASE}"

rule "Probe G: create, then the swapped order -- global reset, then per-type reset"
call PUT "${BASE}" "${GLOBAL_BODY}"
call DELETE "${BASE}"
call GET "${BASE}"
call DELETE "${BASE}/${LOG_TYPE}"

rule "final state"
call GET "${BASE}"

cat <<'NOTE'

Result (recorded 2026-09-18, IS 7.3.0, carbon.super)
----------------------------------------------------
  DELETE /configs/remote-logging          -> 500 CNF-65008, ALWAYS.
      config absent  (probes A, B, D): 500
      config present (probes E, G):    500
      and it still does the work -- the GET straight after returns [].

  DELETE /configs/remote-logging/{type}   -> depends on state.
      config present (probe F): 204
      config absent  (probes C, G): 500 CNF-65008

So the global reset is broken outright, not merely order-dependent.
Probe G settles it: the global reset 500s even as the FIRST reset, with the
config freshly written. Swapping collection01 #269 and #270 does not help --
it only moves the 500 onto the per-type request, which then has nothing left.
Nothing the collection can do; #270's assertion is left failing on purpose.

Two defects to report:
  1. The global reset returns 500 although it succeeds. Should be 204.
  2. The per-type reset is not idempotent: 204 with a config, 500 without.
     Should be 204 or 404.
NOTE

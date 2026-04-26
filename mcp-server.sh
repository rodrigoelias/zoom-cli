#!/usr/bin/env bash
#
# mcp-server.sh — MCP (Model Context Protocol) server for zoom-cli
#
# Exposes Zoom meeting data as read-only tools over JSON-RPC/stdio.
# Tools: zoom_list, zoom_view, initialize_session
#
# Usage:  ./mcp-server.sh   (reads JSON-RPC from stdin, writes to stdout)

set -uo pipefail
# NOTE: no -e (errexit) — a long-running server must not die on individual errors

umask 077  # credential temp files must not be world-readable

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Dependency check ──────────────────────────────────────────────────
for bin in jq curl; do
  command -v "$bin" >/dev/null 2>&1 || { echo "Missing required binary: $bin" >&2; exit 1; }
done

# ─── MCP mode setup ───────────────────────────────────────────────────
MCP_MODE=1
_MCP_COOKIES=""
_MCP_CSRF=""

# Source zoom-cli.sh (loads functions, skips command dispatch via main guard)
source "${SCRIPT_DIR}/zoom-cli.sh"

# Disable errexit inherited from zoom-cli.sh's set -euo pipefail
set +e

# Strip debug output that could corrupt the JSON-RPC stdout channel
unset ZOOM_DEBUG

# ─── Function overrides ───────────────────────────────────────────────

# In-memory credential getters (replace file-backed versions)
get_cookies() {
  if [[ -z "$_MCP_COOKIES" ]]; then
    err "No session. Call initialize_session to authenticate."
    return 1
  fi
  printf '%s' "$_MCP_COOKIES"
}

get_csrf() {
  if [[ -z "$_MCP_CSRF" ]]; then
    err "No CSRF token. Call initialize_session to authenticate."
    return 1
  fi
  printf '%s' "$_MCP_CSRF"
}

# MCP server handles re-auth itself via initialize_session tool
do_reauth() {
  return 1
}

# Suppress human-readable output — must not reach stdout
log()  { echo "[mcp] $*" >&2; }
warn() { echo "[mcp:warn] $*" >&2; }
err()  { echo "[mcp:err] $*" >&2; }
dbg()  { :; }

# Neuterize dangerous functions (defense in depth)
cmd_create() { return 1; }
cmd_delete() { return 1; }
cmd_update() { return 1; }
cmd_raw()    { return 1; }

# ─── Signal handling ──────────────────────────────────────────────────
_shutdown=0

cleanup() {
  _shutdown=1
  jobs -p 2>/dev/null | while read -r pid; do kill "$pid" 2>/dev/null; done
  wait 2>/dev/null
  exit 0
}

trap cleanup EXIT TERM INT
trap 'echo "SIGPIPE: client disconnected" >&2; exit 0' PIPE

# ─── JSON-RPC helpers ─────────────────────────────────────────────────

send_response() {
  printf '%s\n' "$1" || { echo "write failed, shutting down" >&2; exit 0; }
}

send_result() {
  local id="$1" result="$2"
  send_response "$(jq -cn --argjson id "$id" --argjson result "$result" \
    '{"jsonrpc":"2.0","id":$id,"result":$result}')"
}

send_error() {
  local id="$1" code="$2" message="$3"
  send_response "$(jq -cn --argjson id "$id" --arg code "$code" --arg msg "$message" \
    '{"jsonrpc":"2.0","id":($id),"error":{"code":($code|tonumber),"message":$msg}}')"
}

send_tool_result() {
  local id="$1" json="$2"
  send_result "$id" "$(jq -cn --arg text "$json" \
    '{"content":[{"type":"text","text":$text}],"isError":false}')"
}

send_tool_error() {
  local id="$1" code="$2" message="$3" retryable="${4:-false}"
  local error_json
  error_json=$(jq -cn --arg code "$code" --arg msg "$message" --argjson retry "$retryable" \
    '{"ok":false,"error":{"code":$code,"message":$msg,"retryable":$retry}}')
  send_result "$id" "$(jq -cn --arg text "$error_json" \
    '{"content":[{"type":"text","text":$text}],"isError":true}')"
}

# ─── MCP protocol handlers ───────────────────────────────────────────

handle_initialize() {
  local id="$1"
  send_result "$id" '{
    "protocolVersion":"2025-11-25",
    "capabilities":{"tools":{}},
    "serverInfo":{"name":"zoom-cli-mcp","version":"1.0.0"}
  }'
}

handle_tools_list() {
  local id="$1"
  send_result "$id" '{
    "tools":[
      {
        "name":"zoom_list",
        "description":"List Zoom meetings with optional date range filtering and pagination. Returns upcoming meetings by default, grouped by date. Use listType=previous for past meetings. startDate and endDate must both be provided or both omitted.",
        "inputSchema":{
          "type":"object",
          "properties":{
            "listType":{"type":"string","enum":["upcoming","previous"],"default":"upcoming","description":"Whether to list upcoming or past meetings."},
            "page":{"type":"integer","minimum":1,"default":1,"description":"Page number for pagination."},
            "pageSize":{"type":"integer","minimum":1,"maximum":50,"default":50,"description":"Number of results per page."},
            "startDate":{"type":"string","pattern":"^\\d{4}-\\d{2}-\\d{2}$","description":"Start of date range (YYYY-MM-DD). Optional."},
            "endDate":{"type":"string","pattern":"^\\d{4}-\\d{2}-\\d{2}$","description":"End of date range (YYYY-MM-DD). Optional."}
          },
          "required":[],
          "additionalProperties":false
        }
      },
      {
        "name":"zoom_view",
        "description":"Retrieve details for a single Zoom meeting including topic, time, duration, timezone, passcode, join URL, and invitees. Accepts a numeric meeting ID.",
        "inputSchema":{
          "type":"object",
          "properties":{
            "meetingId":{"type":"string","pattern":"^[0-9]+$","description":"Numeric meeting ID (e.g. 94244974137)."}
          },
          "required":["meetingId"],
          "additionalProperties":false
        }
      },
      {
        "name":"initialize_session",
        "description":"Authenticate with Zoom via browser SSO. Opens a visible Chromium window for the user to complete SSO/MFA login. This call blocks until login completes (up to 2 minutes). Call this when you receive an AUTH_EXPIRED error or before first use.",
        "inputSchema":{
          "type":"object",
          "properties":{},
          "required":[],
          "additionalProperties":false
        }
      }
    ]
  }'
}

handle_tools_call() {
  local id="$1" line="$2"

  local tool_name
  tool_name=$(printf '%s' "$line" | jq -r '.params.name // empty' 2>/dev/null) || true

  case "$tool_name" in
    zoom_list)          tool_zoom_list "$id" "$line" ;;
    zoom_view)          tool_zoom_view "$id" "$line" ;;
    initialize_session) tool_initialize_session "$id" "$line" ;;
    *)
      send_tool_error "$id" "BAD_INPUT" "Unknown tool: ${tool_name:-<empty>}" false
      ;;
  esac
}

# ─── Tool handlers ────────────────────────────────────────────────────

tool_zoom_list() {
  local id="$1" line="$2"

  # Parse all arguments in one jq call
  local list_type page page_size start_date end_date
  read -r list_type page page_size start_date end_date < <(printf '%s' "$line" | jq -r \
    '[(.params.arguments.listType // "upcoming"),
      (.params.arguments.page // 1 | tostring),
      (.params.arguments.pageSize // 50 | tostring),
      (.params.arguments.startDate // ""),
      (.params.arguments.endDate // "")] | @tsv' 2>/dev/null) || true

  # Build form params
  local params=("listType=${list_type}" "page=${page}" "pageSize=${page_size}" "isShowPAC=false")
  if [[ -n "$start_date" && -n "$end_date" ]]; then
    params+=("dateDuration=${start_date},${end_date}")
  fi

  # Call Zoom API
  local response
  response=$(zoom_post "/rest/meeting/list" "${params[@]}" 2>/dev/null) || true

  if [[ -z "$response" ]]; then
    send_tool_error "$id" "INTERNAL_ERROR" "Empty response from Zoom API." false
    return
  fi

  # Check auth expiry
  if is_auth_expired "$response"; then
    send_tool_error "$id" "AUTH_EXPIRED" "Session expired. Call the initialize_session tool to re-authenticate." false
    return
  fi

  # Check API-level error
  local status
  status=$(printf '%s' "$response" | jq -r '.status // false' 2>/dev/null) || true
  if [[ "$status" != "true" ]]; then
    local error_msg
    error_msg=$(printf '%s' "$response" | jq -r '.errorMessage // "Unknown API error"' 2>/dev/null) || true
    send_tool_error "$id" "ZOOM_API_ERROR" "$error_msg" false
    return
  fi

  # Transform response to contract format
  local result
  result=$(printf '%s' "$response" | jq --argjson page "$page" --argjson pageSize "$page_size" '
    .result as $r |
    ($r.totalRecords // 0) as $total |
    {
      ok: true,
      data: {
        totalRecords: $total,
        page: $page,
        pageSize: $pageSize,
        hasMore: (($page * $pageSize) < $total),
        meetings: [
          ($r.meetings // [])[] | {
            date: .time,
            items: [
              (.list // [])[] | {
                meetingId: (.number | tostring),
                meetingIdFormatted: (.numberF // null),
                topic: .topic,
                timeRange: (.schTimeF // null),
                duration: (.duration // null),
                isRecurring: ((.type // 0) == 8),
                occurrenceInfo: (if (.occurrenceTip // "") == "" then null else .occurrenceTip end)
              }
            ]
          }
        ]
      }
    }
  ' 2>/dev/null) || true

  if [[ -z "$result" ]]; then
    send_tool_error "$id" "INTERNAL_ERROR" "Failed to transform Zoom API response." false
    return
  fi

  send_tool_result "$id" "$result"
}

tool_zoom_view() {
  local id="$1" line="$2"

  # Parse and validate meeting ID
  local meeting_id
  meeting_id=$(printf '%s' "$line" | jq -r '.params.arguments.meetingId // empty' 2>/dev/null) || true

  if [[ -z "$meeting_id" ]]; then
    send_tool_error "$id" "BAD_INPUT" "meetingId is required." false
    return
  fi

  if [[ ! "$meeting_id" =~ ^[0-9]{1,20}$ ]]; then
    send_tool_error "$id" "BAD_INPUT" "meetingId must be numeric (got: ${meeting_id:0:50})." false
    return
  fi

  # Call Zoom API
  local response
  response=$(zoom_post "/rest/meeting/view" "number=${meeting_id}" 2>/dev/null) || true

  if [[ -z "$response" ]]; then
    send_tool_error "$id" "INTERNAL_ERROR" "Empty response from Zoom API." false
    return
  fi

  # Check auth expiry
  if is_auth_expired "$response"; then
    send_tool_error "$id" "AUTH_EXPIRED" "Session expired. Call the initialize_session tool to re-authenticate." false
    return
  fi

  # Check API-level error
  local status
  status=$(printf '%s' "$response" | jq -r '.status // false' 2>/dev/null) || true
  if [[ "$status" != "true" ]]; then
    local error_msg
    error_msg=$(printf '%s' "$response" | jq -r '.errorMessage // "Unknown API error"' 2>/dev/null) || true
    send_tool_error "$id" "ZOOM_API_ERROR" "$error_msg" false
    return
  fi

  # Transform response with val() unwrapper
  local result
  result=$(printf '%s' "$response" | jq --arg mid "$meeting_id" '
    def val: if type == "object" and has("value") then .value else . end;
    .result as $r |
    ($r.meeting // {}) as $m |
    {
      ok: true,
      data: {
        topic: ($m.topic | val),
        meetingId: $mid,
        startDate: ($m.startDate | val // null),
        startTime: ($m.startTime | val // null),
        startTimePeriod: ($m.startTime2 | val // null),
        duration: ($m.duration | val // null),
        timezone: ($m.timezone | val // null),
        isRecurring: ($m.recurring | val // false),
        recurrenceType: (try ($m.recurring.childParams.recurring.value.type // null) catch null),
        passcode: (try ($m.passcode.childParams.meetingPasscode | val) catch null),
        joinUrl: ($r.joinUrl // $r.join_url // null),
        invitees: [try (($m.invitee | val // [])[] | .email // .displayName // empty) catch empty]
      }
    }
  ' 2>/dev/null) || true

  if [[ -z "$result" ]]; then
    send_tool_error "$id" "INTERNAL_ERROR" "Failed to transform Zoom API response." false
    return
  fi

  send_tool_result "$id" "$result"
}

tool_initialize_session() {
  local id="$1" line="$2"

  # If session already active, return immediately
  if [[ -n "$_MCP_COOKIES" ]]; then
    send_tool_result "$id" '{"ok":true,"data":{"status":"already_active"}}'
    return
  fi

  # Launch browser SSO
  log "Launching browser for SSO login..."
  node "${SCRIPT_DIR}/grab-cookies.mjs" >&2 2>&1 || true

  # Read cookies from disk, then clean up
  if [[ -f "${SCRIPT_DIR}/.raw_cookies" ]]; then
    _MCP_COOKIES=$(cat "${SCRIPT_DIR}/.raw_cookies")
    rm -f "${SCRIPT_DIR}/.raw_cookies"
  fi
  rm -f "${SCRIPT_DIR}/cookies.txt"

  if [[ -z "$_MCP_COOKIES" ]]; then
    send_tool_error "$id" "INIT_FAILED" "Browser SSO did not produce cookies. Login may have timed out or been cancelled." false
    return
  fi

  # Refresh CSRF token using in-memory cookies
  # We need to do this manually since cmd_refresh_csrf writes to files
  local csrf_response
  csrf_response=$(curl -sS -X POST \
    --max-time "$CURL_TIMEOUT" \
    -H "Cookie: ${_MCP_COOKIES}" \
    -H "FETCH-CSRF-TOKEN: 1" \
    -H "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36" \
    -H "Referer: ${ZOOM_BASE}/meeting" \
    "${ZOOM_BASE}/csrf_js" 2>&1) || true

  local csrf_token
  csrf_token=$(echo "$csrf_response" | grep -oE 'ZOOM-CSRFTOKEN:(.+)' | cut -d: -f2 | tr -d '[:space:]' || true)

  if [[ -n "$csrf_token" && "$csrf_token" != "null" ]]; then
    _MCP_CSRF="$csrf_token"
    # Inject CSRF token into cookie string
    _MCP_COOKIES=$(echo "$_MCP_COOKIES" | sed 's/ZOOM-CSRFTOKEN=[^;]*; *//g')
    _MCP_COOKIES="ZOOM-CSRFTOKEN=${csrf_token}; ${_MCP_COOKIES}"
    log "Session initialized successfully"
  else
    _MCP_COOKIES=""
    send_tool_error "$id" "INIT_FAILED" "CSRF token refresh failed after SSO login." false
    return
  fi

  # Clean up any remaining disk artifacts
  rm -f "${SCRIPT_DIR}/.csrf_token"

  send_tool_result "$id" '{"ok":true,"data":{"status":"session_ready"}}'
}

# ─── Main loop ────────────────────────────────────────────────────────

main() {
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ $_shutdown -eq 1 ]] && break
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ ${#line} -gt 1048576 ]] && { send_error "null" "-32700" "Request too large"; continue; }

    # Extract method and id in one jq call
    local method id
    if ! read -r method id < <(printf '%s' "$line" | jq -r '[(.method // "null"), ((.id // "null") | tostring)] | @tsv' 2>/dev/null) || [[ -z "$method" ]]; then
      send_error "null" "-32700" "Parse error"
      continue
    fi

    case "$method" in
      initialize)                handle_initialize "$id" ;;
      notifications/initialized) ;;  # notification — no response
      notifications/*)           ;;  # other notifications — no response
      tools/list)                handle_tools_list "$id" ;;
      tools/call)                handle_tools_call "$id" "$line" ;;
      ping)                      send_result "$id" '{}' ;;
      null)                      send_error "null" "-32700" "Parse error" ;;
      *)                         send_error "$id" "-32601" "Method not found" ;;
    esac
  done
}

main

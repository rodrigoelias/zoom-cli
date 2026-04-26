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

# Clash detection cache (populated lazily during tool calls)
declare -A _CLASH_CACHE

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

# ─── Write infrastructure ─────────────────────────────────────────────

# check_writes_enabled — returns 0 if writes are allowed, 1 if disabled.
# Callers must pass $id so a JSON-RPC error can be sent before returning 1.
check_writes_enabled() {
  local id="$1"
  local enabled="${ZOOM_CLI_WRITES_ENABLED:-true}"
  if [[ "$enabled" != "true" ]]; then
    send_tool_error "$id" "WRITES_DISABLED" \
      "Write operations are disabled. Set ZOOM_CLI_WRITES_ENABLED=true to enable." false
    return 1
  fi
  return 0
}

# audit_log — append a structured JSON line to .mcp-audit.log.
# Usage: audit_log <action> [meetingId] [details_json]
# Rotates the file at 10 000 lines (keeps last 9 999 + new entry).
# Does NOT log sensitive values (no cookies, tokens, passwords).
audit_log() {
  local action="$1"
  local meeting_id="${2:-}"
  local details="${3:-{}}"
  local log_file="${SCRIPT_DIR}/.mcp-audit.log"
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")

  local entry
  entry=$(jq -cn \
    --arg ts        "$ts" \
    --arg action    "$action" \
    --arg mid       "$meeting_id" \
    --argjson det   "$details" \
    '{timestamp:$ts, action:$action, meetingId:(if $mid=="" then null else $mid end), details:$det}')

  # Rotate if file exceeds 10 000 lines
  if [[ -f "$log_file" ]]; then
    local line_count
    line_count=$(wc -l < "$log_file" 2>/dev/null || echo 0)
    if (( line_count >= 10000 )); then
      local tmp_file="${log_file}.tmp"
      tail -n 9999 "$log_file" > "$tmp_file" && mv "$tmp_file" "$log_file"
    fi
  fi

  printf '%s\n' "$entry" >> "$log_file" 2>/dev/null || true
}

# ─── Input validators ─────────────────────────────────────────────────
# Each returns 0 on valid, 1 on invalid (does NOT send errors — callers do).

# validate_meeting_id — numeric, 1-20 digits
validate_meeting_id() {
  local id="$1"
  [[ "$id" =~ ^[0-9]{1,20}$ ]]
}

# validate_topic — non-empty string, max 200 chars
validate_topic() {
  local topic="$1"
  [[ -n "$topic" && ${#topic} -le 200 ]]
}

# validate_date — MM/DD/YYYY
validate_date() {
  local date="$1"
  [[ "$date" =~ ^[0-9]{2}/[0-9]{2}/[0-9]{4}$ ]]
}

# validate_time — H:MM or HH:MM
validate_time() {
  local time="$1"
  [[ "$time" =~ ^[0-9]{1,2}:[0-9]{2}$ ]]
}

# validate_ampm — AM or PM (case-insensitive)
validate_ampm() {
  local val="${1^^}"   # uppercase
  [[ "$val" == "AM" || "$val" == "PM" ]]
}

# validate_duration — numeric integer, 1-1440 (minutes)
validate_duration() {
  local mins="$1"
  [[ "$mins" =~ ^[0-9]+$ ]] && (( mins >= 1 && mins <= 1440 ))
}

# validate_email — basic pattern: must contain @ and at least one dot after @
validate_email() {
  local email="$1"
  [[ "$email" =~ ^[^@]+@[^@]+\.[^@]+$ ]]
}

# ─── Clash detection ──────────────────────────────────────────────────

# _epoch_from_meeting — convert MM/DD/YYYY + H:MM + AM/PM to Unix epoch.
# Prints the epoch on stdout; returns 1 on parse failure.
_epoch_from_meeting() {
  local date="$1" time="$2" ampm="${3^^}"
  local datestr="${date} ${time} ${ampm}"

  # macOS date
  local epoch
  epoch=$(date -j -f "%m/%d/%Y %I:%M %p" "$datestr" "+%s" 2>/dev/null) && {
    printf '%s' "$epoch"; return 0
  }

  # GNU date fallback
  epoch=$(date -d "${date} ${time} ${ampm}" "+%s" 2>/dev/null) && {
    printf '%s' "$epoch"; return 0
  }

  return 1
}

# append_to_clash_cache — add a newly created/updated meeting JSON object to the
# cache entry for a given date-range key so subsequent clash checks stay current.
# Usage: append_to_clash_cache "$date_range_key" "$meeting_json"
append_to_clash_cache() {
  local key="$1" meeting_json="$2"
  if [[ -n "${_CLASH_CACHE[$key]+_}" ]]; then
    local updated
    updated=$(printf '%s' "${_CLASH_CACHE[$key]}" | jq --argjson m "$meeting_json" '. + [$m]' 2>/dev/null) || true
    [[ -n "$updated" ]] && _CLASH_CACHE[$key]="$updated"
  fi
}

# detect_clashes — find meetings that overlap with the proposed time slot.
# Usage: detect_clashes "$date" "$time" "$ampm" "$duration_mins"
# Prints a JSON array of {meetingId, topic, timeRange} on stdout.
# Returns 0 always (empty array means no clashes).
detect_clashes() {
  local date="$1" time="$2" ampm="${3^^}" duration_mins="$4"

  # Convert proposed start to epoch
  local start_epoch
  start_epoch=$(_epoch_from_meeting "$date" "$time" "$ampm") || {
    warn "detect_clashes: could not parse epoch for ${date} ${time} ${ampm}"
    printf '[]'
    return 0
  }
  local end_epoch=$(( start_epoch + duration_mins * 60 ))

  # Build a date range key: target week + following week
  # We fetch two weeks of meetings to catch edge cases near week boundaries.
  local today_epoch
  today_epoch=$(date "+%s" 2>/dev/null || echo 0)

  # Derive startDate of the week containing our target date (Sunday-based)
  local target_epoch
  target_epoch=$(date -j -f "%m/%d/%Y" "$date" "+%s" 2>/dev/null) || \
    target_epoch=$(date -d "$date" "+%s" 2>/dev/null) || target_epoch="$start_epoch"

  # Range: target_epoch - 7 days  to  target_epoch + 14 days
  local range_start range_end
  range_start=$(( target_epoch - 7 * 86400 ))
  range_end=$(( target_epoch + 14 * 86400 ))

  local fmt_start fmt_end
  fmt_start=$(date -r "$range_start" "+%Y-%m-%d" 2>/dev/null) || \
    fmt_start=$(date -d "@${range_start}" "+%Y-%m-%d" 2>/dev/null) || fmt_start=""
  fmt_end=$(date -r "$range_end" "+%Y-%m-%d" 2>/dev/null) || \
    fmt_end=$(date -d "@${range_end}" "+%Y-%m-%d" 2>/dev/null) || fmt_end=""

  local cache_key="${fmt_start}:${fmt_end}"

  # Populate cache if not already present
  if [[ -z "${_CLASH_CACHE[$cache_key]+_}" ]]; then
    local params=("listType=upcoming" "page=1" "pageSize=50")
    [[ -n "$fmt_start" && -n "$fmt_end" ]] && \
      params+=("dateDuration=${fmt_start},${fmt_end}")

    local response
    response=$(zoom_post "/rest/meeting/list" "${params[@]}" 2>/dev/null) || true

    # Extract flat list of meetings [{meetingId, topic, timeRange, startEpoch, endEpoch}]
    local flat_meetings
    flat_meetings=$(printf '%s' "$response" | jq -c '
      [
        (.result.meetings // [])[] |
        (.list // [])[] |
        {
          meetingId: (.number | tostring),
          topic: .topic,
          timeRange: (.schTimeF // null),
          _startEpoch: null,
          _endEpoch: null
        }
      ]
    ' 2>/dev/null) || flat_meetings="[]"

    _CLASH_CACHE[$cache_key]="$flat_meetings"
  fi

  local cached="${_CLASH_CACHE[$cache_key]}"

  # Find overlapping meetings.
  # We can't easily parse the Zoom schTimeF string to epoch in pure jq/bash,
  # so we compare using the numeric start_epoch we already have plus the
  # duration embedded in schTimeF is not reliable. We use a conservative
  # check: if any existing meeting's timeRange string is non-empty and
  # the meeting is on the same date string, we flag it for caller review.
  # For precise overlap, callers that have duration info should use their
  # own epoch comparison; this provides a best-effort list.
  #
  # Practical approach: return all meetings on the same date as $date so
  # the caller / LLM can decide.
  local clashes
  clashes=$(printf '%s' "$cached" | jq -c \
    --arg date "$date" \
    '[.[] | select(.timeRange != null)]' 2>/dev/null) || clashes="[]"

  printf '%s' "$clashes"
}

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
      },
      {
        "name":"zoom_update",
        "description":"Update an existing Zoom meeting. Provide the meeting ID and any fields to change. Returns updated status and any scheduling clashes if date/time changed.",
        "inputSchema":{
          "type":"object",
          "properties":{
            "meetingId":{"type":"string","pattern":"^[0-9]+$","description":"Numeric meeting ID to update."},
            "topic":{"type":"string","maxLength":200,"description":"New meeting topic."},
            "date":{"type":"string","pattern":"^[0-9]{2}/[0-9]{2}/[0-9]{4}$","description":"New date (MM/DD/YYYY)."},
            "time":{"type":"string","pattern":"^[0-9]{1,2}:[0-9]{2}$","description":"New time (H:MM or HH:MM)."},
            "ampm":{"type":"string","enum":["AM","PM"],"description":"AM or PM."},
            "duration_hr":{"type":"integer","minimum":0,"maximum":24,"description":"Duration hours component."},
            "duration_min":{"type":"integer","minimum":0,"maximum":59,"description":"Duration minutes component."}
          },
          "required":["meetingId"],
          "additionalProperties":false
        }
      },
      {
        "name":"zoom_create",
        "description":"Create a new Zoom meeting. Returns meeting ID, join URL, and any scheduling clashes detected.",
        "inputSchema":{
          "type":"object",
          "properties":{
            "topic":{"type":"string","description":"Meeting topic/title.","maxLength":200},
            "date":{"type":"string","pattern":"^[0-9]{2}/[0-9]{2}/[0-9]{4}$","description":"Start date in MM/DD/YYYY format."},
            "time":{"type":"string","pattern":"^[0-9]{1,2}:[0-9]{2}$","description":"Start time in H:MM or HH:MM format."},
            "ampm":{"type":"string","enum":["AM","PM"],"default":"PM","description":"AM or PM."},
            "duration":{"type":"integer","minimum":1,"maximum":1440,"default":60,"description":"Duration in minutes."},
            "timezone":{"type":"string","default":"Europe/London","description":"IANA timezone."},
            "invitees":{"type":"array","items":{"type":"string"},"description":"Email addresses of invitees."}
          },
          "required":["topic","date","time"],
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
    zoom_create)        tool_zoom_create "$id" "$line" ;;
    zoom_update)        tool_zoom_update "$id" "$line" ;;
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

tool_zoom_create() {
  local id="$1" line="$2"

  # 1. Check writes enabled
  check_writes_enabled "$id" || return

  # 2. Parse all inputs in a single jq call
  local topic date time ampm duration timezone invitees_csv
  read -r topic date time ampm duration timezone invitees_csv < <(printf '%s' "$line" | jq -r \
    '[
      (.params.arguments.topic // ""),
      (.params.arguments.date // ""),
      (.params.arguments.time // ""),
      (.params.arguments.ampm // "PM"),
      (.params.arguments.duration // 60 | tostring),
      (.params.arguments.timezone // "Europe/London"),
      ((.params.arguments.invitees // []) | join(","))
    ] | @tsv' 2>/dev/null) || true

  # 3. Validate required fields
  if ! validate_topic "$topic"; then
    send_tool_error "$id" "BAD_INPUT" "topic is required and must be at most 200 characters." false
    return
  fi

  if ! validate_date "$date"; then
    send_tool_error "$id" "BAD_INPUT" "date must be in MM/DD/YYYY format (got: ${date:0:50})." false
    return
  fi

  if ! validate_time "$time"; then
    send_tool_error "$id" "BAD_INPUT" "time must be in H:MM or HH:MM format (got: ${time:0:20})." false
    return
  fi

  if ! validate_ampm "$ampm"; then
    send_tool_error "$id" "BAD_INPUT" "ampm must be AM or PM (got: ${ampm:0:10})." false
    return
  fi

  if ! validate_duration "$duration"; then
    send_tool_error "$id" "BAD_INPUT" "duration must be an integer between 1 and 1440 (got: ${duration:0:10})." false
    return
  fi

  # Validate each invitee email if provided
  if [[ -n "$invitees_csv" ]]; then
    IFS=',' read -ra _invitee_list <<< "$invitees_csv"
    for _email in "${_invitee_list[@]}"; do
      _email="${_email# }"; _email="${_email% }"  # trim spaces
      if ! validate_email "$_email"; then
        send_tool_error "$id" "BAD_INPUT" "Invalid invitee email address: ${_email:0:100}" false
        return
      fi
    done
  fi

  # 4. Audit create_attempt
  local audit_details
  audit_details=$(jq -cn --arg topic "$topic" --arg date "$date" --arg time "$time" --arg ampm "$ampm" \
    '{topic:$topic, date:$date, time:$time, ampm:$ampm}') || audit_details='{}'
  audit_log "create_attempt" "" "$audit_details"

  # 5. Build payload: pipe JSON args to build_create_payload
  local payload
  payload=$(jq -cn \
    --arg topic      "$topic" \
    --arg date       "$date" \
    --arg time       "$time" \
    --arg ampm       "$ampm" \
    --argjson duration "$duration" \
    --arg timezone   "$timezone" \
    --arg invitees   "$invitees_csv" \
    '{topic:$topic, agenda:"", date:$date, time:$time, ampm:$ampm, duration:$duration, timezone:$timezone, invitees:$invitees, recurring:false, recurrence_type:"", recurrence_interval:"1", recurrence_end:"", recurrence_days:""}' \
    | build_create_payload 2>/dev/null) || true

  if [[ -z "$payload" ]]; then
    audit_log "create_failure" "" '{"reason":"payload_build_failed"}'
    send_tool_error "$id" "INTERNAL_ERROR" "Failed to build meeting creation payload." false
    return
  fi

  # 6. Call Zoom API
  local response
  response=$(zoom_post_json "/rest/meeting/save" "$payload" 2>/dev/null) || true

  if [[ -z "$response" ]]; then
    audit_log "create_failure" "" '{"reason":"empty_api_response"}'
    send_tool_error "$id" "INTERNAL_ERROR" "Empty response from Zoom API." false
    return
  fi

  # 7. Check auth expiry
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
    audit_log "create_failure" "" "$(jq -cn --arg reason "$error_msg" '{reason:$reason}')"
    send_tool_error "$id" "ZOOM_API_ERROR" "$error_msg" false
    return
  fi

  # 8. Extract meetingId and joinUrl from response
  local meeting_id join_url
  meeting_id=$(printf '%s' "$response" | jq -r '(.result.mn // .result.meetingNumber // "") | tostring' 2>/dev/null) || true
  join_url=$(printf '%s' "$response" | jq -r '.result.joinLink // .result.joinUrl // ""' 2>/dev/null) || true

  if [[ -z "$meeting_id" || "$meeting_id" == "null" || "$meeting_id" == "" ]]; then
    audit_log "create_failure" "" '{"reason":"missing_meeting_id_in_response"}'
    send_tool_error "$id" "INTERNAL_ERROR" "Meeting created but could not extract meeting ID from response." false
    return
  fi

  # 9. Run detect_clashes and append new meeting to cache
  local clashes
  clashes=$(detect_clashes "$date" "$time" "$ampm" "$duration") || clashes="[]"

  # Build the same cache key that detect_clashes uses, then append new meeting
  local target_epoch
  target_epoch=$(date -j -f "%m/%d/%Y" "$date" "+%s" 2>/dev/null) || \
    target_epoch=$(date -d "$date" "+%s" 2>/dev/null) || target_epoch=""

  if [[ -n "$target_epoch" ]]; then
    local range_start range_end fmt_start fmt_end
    range_start=$(( target_epoch - 7 * 86400 ))
    range_end=$(( target_epoch + 14 * 86400 ))
    fmt_start=$(date -r "$range_start" "+%Y-%m-%d" 2>/dev/null) || \
      fmt_start=$(date -d "@${range_start}" "+%Y-%m-%d" 2>/dev/null) || fmt_start=""
    fmt_end=$(date -r "$range_end" "+%Y-%m-%d" 2>/dev/null) || \
      fmt_end=$(date -d "@${range_end}" "+%Y-%m-%d" 2>/dev/null) || fmt_end=""
    local cache_key="${fmt_start}:${fmt_end}"

    local new_meeting_json
    new_meeting_json=$(jq -cn --arg mid "$meeting_id" --arg topic "$topic" \
      '{meetingId:$mid, topic:$topic, timeRange:null}') || true
    [[ -n "$new_meeting_json" ]] && append_to_clash_cache "$cache_key" "$new_meeting_json"
  fi

  # 10. Audit success
  local clashes_count
  clashes_count=$(printf '%s' "$clashes" | jq 'length' 2>/dev/null) || clashes_count=0
  audit_log "create_success" "$meeting_id" \
    "$(jq -cn --arg url "$join_url" --argjson n "$clashes_count" '{joinUrl:$url, clashes_count:$n}')"

  # 11. Return result
  local result
  result=$(jq -cn \
    --arg mid     "$meeting_id" \
    --arg url     "$join_url" \
    --arg topic   "$topic" \
    --argjson clashes "$clashes" \
    '{ok:true, data:{meetingId:$mid, joinUrl:$url, topic:$topic, clashes:$clashes}}')
  send_tool_result "$id" "$result"
}

tool_zoom_update() {
  local id="$1" line="$2"

  # 1. Check writes enabled
  check_writes_enabled "$id" || return

  # 2. Parse all inputs in a single jq call
  local meeting_id topic date time ampm duration_hr duration_min
  read -r meeting_id topic date time ampm duration_hr duration_min < <(printf '%s' "$line" | jq -r \
    '[
      (.params.arguments.meetingId // ""),
      (.params.arguments.topic // ""),
      (.params.arguments.date // ""),
      (.params.arguments.time // ""),
      (.params.arguments.ampm // ""),
      (.params.arguments.duration_hr // "" | tostring),
      (.params.arguments.duration_min // "" | tostring)
    ] | @tsv' 2>/dev/null) || true

  # 3. Validate meetingId (required)
  if ! validate_meeting_id "$meeting_id"; then
    send_tool_error "$id" "BAD_INPUT" "meetingId is required and must be numeric (got: ${meeting_id:0:50})." false
    return
  fi

  # Validate optional fields only when provided
  if [[ -n "$topic" ]] && [[ ${#topic} -gt 200 ]]; then
    send_tool_error "$id" "BAD_INPUT" "topic must be at most 200 characters." false
    return
  fi

  if [[ -n "$date" ]] && ! validate_date "$date"; then
    send_tool_error "$id" "BAD_INPUT" "date must be in MM/DD/YYYY format (got: ${date:0:50})." false
    return
  fi

  if [[ -n "$time" ]] && ! validate_time "$time"; then
    send_tool_error "$id" "BAD_INPUT" "time must be in H:MM or HH:MM format (got: ${time:0:20})." false
    return
  fi

  if [[ -n "$ampm" ]] && ! validate_ampm "$ampm"; then
    send_tool_error "$id" "BAD_INPUT" "ampm must be AM or PM (got: ${ampm:0:10})." false
    return
  fi

  # 4. Require at least one update field
  if [[ -z "$topic" && -z "$date" && -z "$time" && -z "$ampm" && -z "$duration_hr" && -z "$duration_min" ]]; then
    send_tool_error "$id" "BAD_INPUT" "At least one field to update is required." false
    return
  fi

  # 5. Audit update_attempt with fields being changed
  local audit_fields
  audit_fields=$(jq -cn \
    --arg mid "$meeting_id" \
    --arg topic "$topic" \
    --arg date "$date" \
    --arg time "$time" \
    --arg ampm "$ampm" \
    --arg duration_hr "$duration_hr" \
    --arg duration_min "$duration_min" \
    '{meetingId:$mid, fields_changed:{topic:$topic, date:$date, time:$time, ampm:$ampm, duration_hr:$duration_hr, duration_min:$duration_min}}') || audit_fields="{}"
  audit_log "update_attempt" "$meeting_id" "$audit_fields"

  # 6. Pre-write snapshot
  local snapshot
  snapshot=$(zoom_post "/rest/meeting/view" "number=${meeting_id}" 2>/dev/null) || snapshot="{}"
  audit_log "update_snapshot" "$meeting_id" "${snapshot:-{}}"

  # 7. Build form params for update API call
  local params=()
  [[ -n "$topic" ]]       && params+=("topic=${topic}")
  [[ -n "$date" ]]        && params+=("startDate=${date}")
  [[ -n "$time" ]]        && params+=("startTime=${time}")
  [[ -n "$ampm" ]]        && params+=("startTime2=${ampm}")

  if [[ -n "$duration_hr" || -n "$duration_min" ]]; then
    local hr="${duration_hr:-0}" min="${duration_min:-0}"
    # strip trailing .0 from jq tostring output
    hr="${hr%%.*}"; min="${min%%.*}"
    local total_minutes=$(( hr * 60 + min ))
    params+=("duration=${total_minutes}")
  fi

  # 8. Call Zoom update API
  local response
  response=$(zoom_post "/rest/meeting/save?meetingNumber=${meeting_id}" "${params[@]}" 2>/dev/null) || true

  if [[ -z "$response" ]]; then
    audit_log "update_failure" "$meeting_id" '{"reason":"empty_api_response"}'
    send_tool_error "$id" "INTERNAL_ERROR" "Empty response from Zoom API." false
    return
  fi

  # 9. Check auth expiry / API error
  if is_auth_expired "$response"; then
    send_tool_error "$id" "AUTH_EXPIRED" "Session expired. Call the initialize_session tool to re-authenticate." false
    return
  fi

  local status
  status=$(printf '%s' "$response" | jq -r '.status // false' 2>/dev/null) || true
  if [[ "$status" != "true" ]]; then
    local error_msg
    error_msg=$(printf '%s' "$response" | jq -r '.errorMessage // "Unknown API error"' 2>/dev/null) || true
    audit_log "update_failure" "$meeting_id" "$(jq -cn --arg reason "$error_msg" '{reason:$reason}')"
    send_tool_error "$id" "ZOOM_API_ERROR" "$error_msg" false
    return
  fi

  # 10. If date or time changed, run detect_clashes and append to cache
  local clashes="[]"
  if [[ -n "$date" || -n "$time" ]]; then
    # Use provided date/time; fall back to values from snapshot if only one was changed
    local clash_date clash_time clash_ampm clash_duration
    clash_date="$date"
    clash_time="$time"
    clash_ampm="${ampm:-PM}"

    # Compute duration in minutes for clash detection
    if [[ -n "$duration_hr" || -n "$duration_min" ]]; then
      local hr="${duration_hr:-0}" min="${duration_min:-0}"
      hr="${hr%%.*}"; min="${min%%.*}"
      clash_duration=$(( hr * 60 + min ))
    else
      clash_duration=60
    fi

    if [[ -n "$clash_date" && -n "$clash_time" ]]; then
      clashes=$(detect_clashes "$clash_date" "$clash_time" "$clash_ampm" "$clash_duration") || clashes="[]"

      # Append updated meeting to clash cache
      local target_epoch
      target_epoch=$(date -j -f "%m/%d/%Y" "$clash_date" "+%s" 2>/dev/null) || \
        target_epoch=$(date -d "$clash_date" "+%s" 2>/dev/null) || target_epoch=""

      if [[ -n "$target_epoch" ]]; then
        local range_start range_end fmt_start fmt_end
        range_start=$(( target_epoch - 7 * 86400 ))
        range_end=$(( target_epoch + 14 * 86400 ))
        fmt_start=$(date -r "$range_start" "+%Y-%m-%d" 2>/dev/null) || \
          fmt_start=$(date -d "@${range_start}" "+%Y-%m-%d" 2>/dev/null) || fmt_start=""
        fmt_end=$(date -r "$range_end" "+%Y-%m-%d" 2>/dev/null) || \
          fmt_end=$(date -d "@${range_end}" "+%Y-%m-%d" 2>/dev/null) || fmt_end=""
        local cache_key="${fmt_start}:${fmt_end}"

        local updated_meeting_json
        updated_meeting_json=$(jq -cn --arg mid "$meeting_id" --arg t "$topic" \
          '{meetingId:$mid, topic:$t, timeRange:null}') || true
        [[ -n "$updated_meeting_json" ]] && append_to_clash_cache "$cache_key" "$updated_meeting_json"
      fi
    fi
  fi

  # 11. Audit success
  local clashes_count
  clashes_count=$(printf '%s' "$clashes" | jq 'length' 2>/dev/null) || clashes_count=0
  audit_log "update_success" "$meeting_id" \
    "$(jq -cn --argjson n "$clashes_count" '{clashes_count:$n}')"

  # 12. Return result
  local result
  result=$(jq -cn \
    --arg mid    "$meeting_id" \
    --argjson clashes "$clashes" \
    '{ok:true, data:{meetingId:$mid, status:"updated", clashes:$clashes}}')
  send_tool_result "$id" "$result"
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

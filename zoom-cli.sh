#!/usr/bin/env bash
#
# zoom-cli.sh — Manage Zoom meetings from the terminal
# Mimics the browser using session cookies from your Zoom web login.
#
# Setup:
#   1. Sign into https://skyscanner.zoom.us in your browser
#   2. Open DevTools (F12) → Console → run:  copy(document.cookie)
#   3. Run:  ./zoom-cli.sh set-cookies "<paste>"
#   4. Run:  ./zoom-cli.sh refresh-csrf
#   5. Done: ./zoom-cli.sh list

set -euo pipefail

# Re-entrancy guard: prevent double-sourcing
[[ -n "${_ZOOM_CLI_LOADED:-}" ]] && return 0 2>/dev/null || true
_ZOOM_CLI_LOADED=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAW_COOKIE_FILE="${SCRIPT_DIR}/.raw_cookies"
CSRF_FILE="${SCRIPT_DIR}/.csrf_token"
ZOOM_BASE="https://skyscanner.zoom.us"
CURL_TIMEOUT=15

# ─── Colors ───────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; }
dbg()  { [[ "${ZOOM_DEBUG:-0}" == "1" ]] && echo -e "${YELLOW}[dbg]${NC} $*" >&2 || true; }

# ─── Cookie management (raw string, not Netscape format) ─────────────

get_cookies() {
  if [[ ! -f "$RAW_COOKIE_FILE" ]]; then
    err "No cookies. Run:  $0 set-cookies \"<cookie_string>\"  or  $0 import-cookies"
    return 1
  fi
  cat "$RAW_COOKIE_FILE"
}

# Convert Netscape-format cookies.txt → raw cookie string
cmd_import_cookies() {
  local src="${1:-${SCRIPT_DIR}/cookies.txt}"
  if [[ ! -f "$src" ]]; then
    err "Cookie file not found: ${src}"
    return 1
  fi
  local raw
  raw=$(awk '!/^#/ && NF >= 7 { printf "%s=%s; ", $6, $7 }' "$src" | sed 's/; $//')
  if [[ -z "$raw" ]]; then
    err "No cookies parsed from ${src}"
    return 1
  fi
  printf '%s' "$raw" > "$RAW_COOKIE_FILE"
  local count
  count=$(echo "$raw" | tr ';' '\n' | wc -l | tr -d ' ')
  log "Imported ${count} cookies from ${src} → ${RAW_COOKIE_FILE}"
}

cmd_set_cookies() {
  local raw="$1"
  # Strip leading/trailing whitespace and quotes
  raw="${raw#\"}"
  raw="${raw%\"}"
  raw="$(echo "$raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  printf '%s' "$raw" > "$RAW_COOKIE_FILE"
  local count
  count=$(echo "$raw" | tr ';' '\n' | wc -l | tr -d ' ')
  log "Saved ${count} cookies to ${RAW_COOKIE_FILE}"
}

# ─── CSRF ─────────────────────────────────────────────────────────────

cmd_refresh_csrf() {
  log "Fetching CSRF token from ${ZOOM_BASE}/csrf_js ..."
  local cookies response csrf_token
  cookies="$(get_cookies)"

  # The browser's csrf_js script does a POST with FETCH-CSRF-TOKEN:1 header.
  # The server responds with plain text: "ZOOM-CSRFTOKEN:<value>"
  response=$(curl -sS -X POST \
    --max-time "$CURL_TIMEOUT" \
    -H "Cookie: ${cookies}" \
    -H "FETCH-CSRF-TOKEN: 1" \
    -H "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36" \
    -H "Referer: ${ZOOM_BASE}/meeting" \
    "${ZOOM_BASE}/csrf_js" 2>&1) || {
      err "curl failed (exit $?). Check your network / VPN."
      return 1
    }

  dbg "csrf_js response: ${response}"

  # Response format is "ZOOM-CSRFTOKEN:<token_value>"
  csrf_token=$(echo "$response" | grep -oE 'ZOOM-CSRFTOKEN:(.+)' | cut -d: -f2 || true)

  # Fallback: try splitting on colon in case the name differs
  if [[ -z "$csrf_token" ]]; then
    csrf_token=$(echo "$response" | cut -d: -f2 || true)
  fi

  csrf_token=$(echo "$csrf_token" | tr -d '[:space:]')

  if [[ -n "$csrf_token" && "$csrf_token" != "null" ]]; then
    printf '%s' "$csrf_token" > "$CSRF_FILE"
    log "CSRF token: ${csrf_token}"

    # Also inject/update it in the cookie string
    local updated_cookies
    updated_cookies=$(echo "$(get_cookies)" | sed 's/ZOOM-CSRFTOKEN=[^;]*; *//g')
    printf '%s' "ZOOM-CSRFTOKEN=${csrf_token}; ${updated_cookies}" > "$RAW_COOKIE_FILE"
    log "Cookie jar updated with CSRF token."
  else
    err "Could not extract CSRF token."
    err "Raw response: ${response:0:500}"
    return 1
  fi
}

get_csrf() {
  if [[ -f "$CSRF_FILE" ]]; then
    cat "$CSRF_FILE"
  else
    err "No CSRF token. Run:  $0 refresh-csrf"
    return 1
  fi
}

# ─── curl wrappers ────────────────────────────────────────────────────

# Detect if a response indicates an expired/invalid session
# Returns 0 (true) if auth has expired, 1 (false) if OK
is_auth_expired() {
  local body="$1"
  # Check for known auth failure patterns
  case "$body" in
    *'"errorCode":201'*|*'"User not login"'*|*'"User not login."'*)
      return 0 ;;
    *'login.microsoftonline.com'*|*'SAMLRequest'*)
      return 0 ;;
    *'<title>Error - Zoom</title>'*)
      return 0 ;;
  esac
  return 1
}

# Re-authenticate: launch browser login + CSRF refresh
do_reauth() {
  warn "Session expired — re-authenticating..."
  if [[ -t 0 && -t 1 ]]; then
    # Interactive terminal: launch browser
    node "${SCRIPT_DIR}/grab-cookies.mjs" || { err "Re-login failed."; return 1; }
    if [[ -f "$RAW_COOKIE_FILE" ]]; then
      cmd_refresh_csrf
    fi
    return 0
  else
    err "Session expired and not running interactively. Run: $0 login"
    return 1
  fi
}

# Run a zoom_get/zoom_post call, auto-reauth on session expiry, retry once.
# Usage:  result=$(zoom_authed zoom_post "/rest/meeting/list" "listType=upcoming" ...)
zoom_authed() {
  local fn="$1"; shift
  local result
  result=$("$fn" "$@")

  if is_auth_expired "$result"; then
    do_reauth || return 1
    # Retry the original call with fresh cookies
    result=$("$fn" "$@")
    if is_auth_expired "$result"; then
      err "Still not authenticated after re-login."
      return 1
    fi
  fi
  printf '%s' "$result"
}

# GET request, returns body
zoom_get() {
  local path="$1"
  local cookies csrf
  cookies="$(get_cookies)"
  csrf="$(get_csrf)"

  curl -sSL --max-time "$CURL_TIMEOUT" \
    -H "Cookie: ${cookies}" \
    -H "zoom-csrftoken: ${csrf}" \
    -H "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36" \
    -H "Referer: ${ZOOM_BASE}/meeting" \
    -H "Accept: application/json, text/plain, */*" \
    -H "x-requested-with: XMLHttpRequest, OWASP CSRFGuard Project" \
    "${ZOOM_BASE}${path}"
}

# POST form-encoded, returns body.  Pass params as separate args: "key=val" "key2=val2"
zoom_post() {
  local path="$1"; shift
  local cookies csrf
  cookies="$(get_cookies)"
  csrf="$(get_csrf)"

  local curl_args=(
    -sSL --max-time "$CURL_TIMEOUT"
    -X POST
    -H "Cookie: ${cookies}"
    -H "zoom-csrftoken: ${csrf}"
    -H "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36"
    -H "Referer: ${ZOOM_BASE}/meeting/schedule"
    -H "Origin: ${ZOOM_BASE}"
    -H "Content-Type: application/x-www-form-urlencoded"
    -H "Accept: application/json, text/plain, */*"
    -H "x-requested-with: XMLHttpRequest, OWASP CSRFGuard Project"
  )

  for param in "$@"; do
    curl_args+=(--data-urlencode "$param")
  done

  curl "${curl_args[@]}" "${ZOOM_BASE}${path}"
}

# POST that follows redirects and returns final URL (for meeting creation)
zoom_post_follow() {
  local path="$1"; shift
  local cookies csrf
  cookies="$(get_cookies)"
  csrf="$(get_csrf)"

  local curl_args=(
    -sSL --max-time "$CURL_TIMEOUT"
    -X POST
    -w '\n__FINAL_URL__=%{url_effective}'
    -H "Cookie: ${cookies}"
    -H "zoom-csrftoken: ${csrf}"
    -H "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36"
    -H "Referer: ${ZOOM_BASE}/meeting/schedule"
    -H "Origin: ${ZOOM_BASE}"
    -H "Content-Type: application/x-www-form-urlencoded"
    -H "Accept: application/json, text/plain, */*"
    -H "x-requested-with: XMLHttpRequest, OWASP CSRFGuard Project"
  )

  for param in "$@"; do
    curl_args+=(--data-urlencode "$param")
  done

  curl "${curl_args[@]}" "${ZOOM_BASE}${path}"
}

# POST JSON body, returns body
zoom_post_json() {
  local path="$1" json_body="$2"
  local cookies csrf
  cookies="$(get_cookies)"
  csrf="$(get_csrf)"

  curl -sSL --max-time "$CURL_TIMEOUT" \
    -X POST \
    -H "Cookie: ${cookies}" \
    -H "zoom-csrftoken: ${csrf}" \
    -H "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36" \
    -H "Referer: ${ZOOM_BASE}/meeting/schedule" \
    -H "Origin: ${ZOOM_BASE}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/plain, */*" \
    -H "x-requested-with: XMLHttpRequest, OWASP CSRFGuard Project" \
    -d "$json_body" \
    "${ZOOM_BASE}${path}"
}

# ─── list ─────────────────────────────────────────────────────────────

cmd_list() {
  log "Fetching upcoming meetings..."
  local response
  local today end_date
  today=$(date '+%Y-%m-%d')
  end_date=$(date -v+3m '+%Y-%m-%d' 2>/dev/null || date -d '+3 months' '+%Y-%m-%d' 2>/dev/null || echo "")

  local params=(
    "listType=upcoming"
    "page=1"
    "pageSize=50"
    "isShowPAC=false"
  )
  [[ -n "$end_date" ]] && params+=("dateDuration=${today},${end_date}")

  response=$(zoom_authed zoom_post "/rest/meeting/list" "${params[@]}")

  dbg "list response: ${response:0:500}"

  # Check if response is valid JSON with status=true
  if ! echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('status')" 2>/dev/null; then
    err "Failed to fetch meetings."
    err "Response: ${response:0:500}"
    return 1
  fi

  echo ""
  echo "$response" | python3 -c "
import sys, json
from datetime import datetime

data = json.load(sys.stdin)
result = data.get('result', {})
meetings = result.get('meetings', [])
total = result.get('totalRecords', 0)

CYAN = '\033[0;36m'
GREEN = '\033[0;32m'
YELLOW = '\033[1;33m'
DIM = '\033[2m'
NC = '\033[0m'

print(f'{CYAN}Upcoming Meetings ({total} total):{NC}')
print('─' * 70)

if not meetings:
    print('  No upcoming meetings.')
    sys.exit(0)

for group in meetings:
    date_label = group.get('time', '')
    items = group.get('list', [])
    print(f'\n  {YELLOW}{date_label}{NC}')
    for m in items:
        mid = m.get('number', '?')
        mid_f = m.get('numberF', mid)
        topic = m.get('topic', '(no topic)')
        time_range = m.get('schTimeF', '')
        duration = m.get('duration', 0)
        recurring = '🔄' if m.get('type') == 8 else '  '
        occ = m.get('occurrenceTip', '')
        occ_str = f' {DIM}({occ}){NC}' if occ else ''

        print(f'    {recurring} {GREEN}{mid_f}{NC}  {topic}')
        print(f'       {time_range}  ({duration} min){occ_str}')

print()
"
}

# ─── view ─────────────────────────────────────────────────────────────

cmd_view() {
  local meeting_id="$1"
  log "Fetching meeting ${meeting_id}..."

  local response
  response=$(zoom_authed zoom_post "/rest/meeting/view" "number=${meeting_id}")

  dbg "view response: ${response:0:500}"

  if ! echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('status')" 2>/dev/null; then
    err "Failed to fetch meeting ${meeting_id}."
    err "Response: ${response:0:500}"
    return 1
  fi

  echo ""
  echo "$response" | python3 -c "
import sys, json

data = json.load(sys.stdin)
result = data.get('result', {})
mtg = result.get('meeting', result)

CYAN = '\033[0;36m'
GREEN = '\033[0;32m'
DIM = '\033[2m'
NC = '\033[0m'

def val(obj):
    if isinstance(obj, dict) and 'value' in obj:
        return obj['value']
    return obj

topic      = val(mtg.get('topic', 'N/A'))
start_date = val(mtg.get('startDate', 'N/A'))
start_time = val(mtg.get('startTime', ''))
ampm       = val(mtg.get('startTime2', ''))
duration   = val(mtg.get('duration', 'N/A'))
timezone   = val(mtg.get('timezone', 'N/A'))
recurring  = val(mtg.get('recurring', False))

print(f'{CYAN}Meeting Details:{NC}')
print('─' * 50)
print(f'  Topic:     {GREEN}{topic}{NC}')
print(f'  Meeting #: ${meeting_id}')
print(f'  When:      {start_date} {start_time} {ampm}')
print(f'  Duration:  {duration} min')
print(f'  Timezone:  {timezone}')

# Passcode
passcode_obj = mtg.get('passcode', {})
if isinstance(passcode_obj, dict):
    cp = passcode_obj.get('childParams') or {}
    pw = val(cp.get('meetingPasscode', {}))
    if pw:
        print(f'  Passcode:  {pw}')

# Join URL — might be in result directly
join_url = result.get('joinUrl') or result.get('join_url')
if join_url:
    print(f'  Join URL:  {join_url}')

# Invitees
invitee_obj = mtg.get('invitee', {})
invitees = val(invitee_obj) if isinstance(invitee_obj, dict) else invitee_obj
if isinstance(invitees, list) and invitees:
    emails = [i.get('email', i.get('displayName', '?')) for i in invitees]
    print(f'  Invitees:  {\", \".join(emails)}')

# Recurrence
if recurring:
    rec_obj = mtg.get('recurring', {})
    cp = rec_obj.get('childParams') or {} if isinstance(rec_obj, dict) else {}
    rec_data = val(cp.get('recurring', {}))
    if isinstance(rec_data, dict):
        rtype = rec_data.get('type', '?')
        print(f'  Recurring: {rtype}')

print()
"
}

# ─── create ───────────────────────────────────────────────────────────

cmd_create() {
  local topic="My Meeting"
  local when="" time_val="" ampm="PM" duration="60"
  local timezone="Europe/London"
  local agenda=""
  local recurring=false
  local recurrence_type="" recurrence_interval="1" recurrence_end=""
  local recurrence_days=""
  local invitees=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --topic|-t)              topic="$2"; shift 2;;
      --agenda|--desc)         agenda="$2"; shift 2;;
      --date|-d)               when="$2"; shift 2;;
      --time)                  time_val="$2"; shift 2;;
      --ampm)                  ampm="$2"; shift 2;;
      --duration)              duration="$2"; shift 2;;
      --timezone|-tz)          timezone="$2"; shift 2;;
      --recurring|-r)          recurring=true; shift;;
      --recurrence-type)       recurrence_type="$2"; shift 2;;  # DAILY, WEEKLY, MONTHLY
      --recurrence-interval)   recurrence_interval="$2"; shift 2;;
      --recurrence-end)        recurrence_end="$2"; shift 2;;
      --recurrence-days)       recurrence_days="$2"; shift 2;;  # comma-sep: MO,TU,WE,TH,FR,SA,SU
      --invite|-i)             invitees="${invitees:+${invitees},}$2"; shift 2;;
      --help|-h)
        cat << 'EOF'
Usage: zoom-cli.sh create [options]

Options:
  --topic, -t            Meeting topic (default: "My Meeting")
  --agenda, --desc       Meeting description/agenda
  --date, -d             Start date MM/DD/YYYY (default: today)
  --time                 Time H:MM (default: next round hour)
  --ampm                 AM or PM (default: PM)
  --duration             Duration in minutes (default: 60)
  --timezone, -tz        Timezone (default: Europe/London)
  --invite, -i           Invitee email (repeat for multiple)
  --recurring, -r        Enable recurrence
  --recurrence-type      DAILY, WEEKLY, or MONTHLY
  --recurrence-interval  Every N periods (default: 1)
  --recurrence-days      Day(s) of week: MO,TU,WE,TH,FR,SA,SU
  --recurrence-end       End date MM/DD/YYYY

Examples:
  ./zoom-cli.sh create -t "Standup" -d 03/28/2026 --time 9:00 --ampm AM --duration 30
  ./zoom-cli.sh create -t "Weekly" --recurring --recurrence-type WEEKLY --recurrence-days SA --time 10:00 --ampm AM
  ./zoom-cli.sh create -t "Sync" -i alice@example.com -i bob@example.com
EOF
        return 0;;
      *) err "Unknown option: $1"; exit 1;;
    esac
  done

  [[ -z "$when" ]] && when=$(date '+%m/%d/%Y')
  if [[ -z "$time_val" ]]; then
    local h=$(( $(date '+%-H') + 1 ))
    if   (( h > 12 )); then time_val="$(( h - 12 )):00"; ampm="PM"
    elif (( h == 12 )); then time_val="12:00"; ampm="PM"
    else time_val="${h}:00"; ampm="AM"; fi
  fi

  log "Creating meeting..."
  echo -e "  Topic:    ${GREEN}${topic}${NC}"
  echo -e "  When:     ${when} ${time_val} ${ampm}"
  echo -e "  Duration: ${duration} min"
  echo -e "  Timezone: ${timezone}"
  [[ -n "$invitees" ]] && echo -e "  Invitees: ${CYAN}${invitees}${NC}"
  [[ "$recurring" == true ]] && echo -e "  Recurring: ${YELLOW}${recurrence_type:-DAILY} every ${recurrence_interval}${NC}"

  local template_file="${SCRIPT_DIR}/meeting-template.json"
  if [[ ! -f "$template_file" ]]; then
    err "Missing meeting-template.json"
    exit 1
  fi

  # Build JSON payload: load template, override with user values
  local json_body
  json_body=$(python3 -c "
import json, sys, copy

with open('${template_file}') as f:
    p = json.load(f)

topic      = '''${topic}'''
agenda     = '''${agenda}'''
when       = '${when}'
time_val   = '${time_val}'
ampm       = '${ampm}'
duration   = int('${duration}')
timezone   = '${timezone}'
recurring  = '${recurring}' == 'true'
rec_type   = '${recurrence_type}' or 'DAILY'
rec_interval = '${recurrence_interval}' or '1'
rec_end    = '${recurrence_end}'
rec_days   = '${recurrence_days}'
invitee_str = '${invitees}'

# Override basic fields
p['topic']['value'] = topic
p['agenda']['value'] = agenda
p['startDate']['value'] = when
p['startTime']['value'] = time_val
p['startTime2']['value'] = ampm
p['duration']['value'] = duration
p['timezone']['value'] = timezone

# Invitees
if invitee_str:
    emails = [e.strip() for e in invitee_str.split(',') if e.strip()]
    p['invitee']['value'] = [
        {'custom': True, 'displayName': email, 'email': email, 'uniqueKey': email, 'isEmail': True}
        for email in emails
    ]

# Recurrence
if recurring:
    # Map day abbreviations to Zoom's numeric format: SU=1,MO=2,...,SA=7
    day_map = {'SU':'1','MO':'2','TU':'3','WE':'4','TH':'5','FR':'6','SA':'7'}

    rec_values = [{'type': 'INTERVAL', 'value': rec_interval}]
    day_list = []
    if rec_days:
        for day in rec_days.split(','):
            d = day.strip().upper()
            num = day_map.get(d, d)  # accept both SA and 7
            rec_values.append({'type': 'BYDAY', 'value': num})
            day_list.append(num)

    # Build start/end time strings
    start_str = f'{when} {time_val}'
    if not rec_end:
        # Default: 3 months from start date
        from datetime import datetime, timedelta
        try:
            dt = datetime.strptime(when, '%m/%d/%Y')
            # ~3 months
            end_dt = dt + timedelta(days=90)
            rec_end = end_dt.strftime('%m/%d/%Y')
        except:
            rec_end = when  # fallback
    end_str = rec_end + ' 23:59'

    p['recurring'] = {
        'value': True,
        'childParams': {
            'meetingEventEnabled': {'show': True, 'value': True, 'disabled': False, 'childParams': None, 'dataOptions': None},
            'recurring': {
                'show': True,
                'value': {
                    'type': rec_type,
                    'endType': 'END_DATETIME',
                    'timezone': timezone,
                    'currentUserId': p.get('scheduleFor', {}).get('value'),
                    'recurrenceValues': rec_values,
                    'startTime': start_str,
                    'endTime': end_str,
                },
                'disabled': False, 'childParams': None, 'dataOptions': None,
            },
            'maxRecurrences': {'show': True, 'value': {'maxDaily': 365, 'maxWeekly': 110, 'maxMonthly': 60}, 'disabled': False, 'childParams': None, 'dataOptions': None},
            'canScheduleNoEndType': {'show': True, 'value': True, 'disabled': False, 'childParams': None, 'dataOptions': None},
        },
    }
    p['recurringType'] = {'value': rec_type}
    p['recurringRepeat'] = {'value': rec_interval}
    p['recurringOccurs'] = {'value': day_list if day_list else ''}
    p['recurringEndDate'] = {'value': {'type': 'END_DATETIME', 'activeDate': rec_end, 'activedescendant': '7'}}
else:
    # Not recurring — keep recurring block from template (API requires it)
    pass

print(json.dumps(p))
") || { err "Failed to build JSON payload"; return 1; }

  dbg "create payload: ${json_body:0:500}"

  local response
  response=$(zoom_authed zoom_post_json "/rest/meeting/save" "$json_body")

  dbg "create response: ${response:0:500}"

  # Parse response
  local new_id="" join_link=""
  eval "$(echo "$response" | python3 -c "
import sys, json, shlex
try:
    d = json.load(sys.stdin)
    if d.get('status'):
        r = d.get('result', {})
        mid = str(r.get('mn') or r.get('meetingNumber') or r.get('number') or '')
        link = str(r.get('joinLink') or r.get('joinUrl') or '')
        print(f'new_id={shlex.quote(mid)}')
        print(f'join_link={shlex.quote(link)}')
    else:
        em = d.get('errorMessage', 'Unknown error')
        print('new_id=\"\"')
        print('join_link=\"\"')
        print(f'# API error: {em}', file=sys.stderr)
except Exception as e:
    print('new_id=\"\"')
    print('join_link=\"\"')
    print(f'# Parse error: {e}', file=sys.stderr)
" 2>&2)"

  if [[ -n "$new_id" && "$new_id" != "None" && "$new_id" != " " ]]; then
    echo ""
    log "Meeting created!  ID: ${new_id}"
    [[ -n "$join_link" ]] && log "Join URL: ${join_link}"
    cmd_view "$new_id"
  else
    err "Could not create meeting."
    err "Response: ${response:0:500}"
  fi
}

# ─── delete ───────────────────────────────────────────────────────────

cmd_delete() {
  local meeting_id="$1"
  log "Deleting meeting ${meeting_id}..."

  local response
  response=$(zoom_authed zoom_post "/meeting/delete" "id=${meeting_id}" "sendMail=false" "mailBody=")

  if echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if d.get('status') else 1)" 2>/dev/null; then
    log "Meeting ${meeting_id} deleted."
  else
    err "Delete may have failed. Response:"
    echo "$response" | python3 -m json.tool 2>/dev/null || echo "${response:0:500}"
  fi
}

# ─── update ───────────────────────────────────────────────────────────

cmd_update() {
  local meeting_id="$1"; shift
  local topic="" when="" time_val="" ampm="" duration_hr="" duration_min=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --topic|-t)       topic="$2"; shift 2;;
      --date|-d)        when="$2"; shift 2;;
      --time)           time_val="$2"; shift 2;;
      --ampm)           ampm="$2"; shift 2;;
      --duration)       duration_hr="$2"; shift 2;;
      --duration-min)   duration_min="$2"; shift 2;;
      *) err "Unknown option: $1"; exit 1;;
    esac
  done

  local params=()
  [[ -n "$topic" ]]       && params+=("topic=${topic}")
  [[ -n "$when" ]]        && params+=("when=${when}")
  [[ -n "$time_val" ]]    && params+=("time=${time_val}")
  [[ -n "$ampm" ]]        && params+=("ampm=${ampm}")
  [[ -n "$duration_hr" ]] && params+=("duration_hr=${duration_hr}")
  [[ -n "$duration_min" ]] && params+=("duration_min=${duration_min}")

  if [[ ${#params[@]} -eq 0 ]]; then
    err "Nothing to update. Use --topic, --date, --time, etc."
    exit 1
  fi

  log "Updating meeting ${meeting_id}..."
  local response
  response=$(zoom_authed zoom_post "/rest/meeting/save?meetingNumber=${meeting_id}" "${params[@]}")

  if echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if d.get('status') else 1)" 2>/dev/null; then
    log "Meeting ${meeting_id} updated."
    cmd_view "$meeting_id"
  else
    err "Update may have failed. Response:"
    echo "$response" | python3 -m json.tool 2>/dev/null || echo "${response:0:500}"
  fi
}

# ─── debug ────────────────────────────────────────────────────────────

cmd_raw() {
  # Raw curl for debugging:  ./zoom-cli.sh raw GET /meeting
  local method="$1" path="$2"
  shift 2
  if [[ "$method" == "GET" ]]; then
    zoom_get "$path"
  else
    zoom_post "$path" "$@"
  fi
}

# ─── main ─────────────────────────────────────────────────────────────

# Main guard: skip dispatch when sourced by another script
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then

case "${1:-help}" in
  set-cookies)
    [[ -z "${2:-}" ]] && { err "Usage: $0 set-cookies \"<cookie_string>\""; exit 1; }
    cmd_set_cookies "$2"
    ;;
  import-cookies)
    cmd_import_cookies "${2:-}"
    ;;
  login|auth|grab-cookies)
    log "Launching browser for SSO login..."
    node "${SCRIPT_DIR}/grab-cookies.mjs"
    if [[ -f "$RAW_COOKIE_FILE" ]]; then
      cmd_refresh_csrf
    fi
    ;;
  refresh-csrf)     cmd_refresh_csrf ;;
  list|ls)          cmd_list ;;
  view|show|get)
    [[ -z "${2:-}" ]] && { err "Usage: $0 view <meeting_id>"; exit 1; }
    cmd_view "$2" ;;
  create|new|schedule)
    shift; cmd_create "$@" ;;
  update|edit)
    [[ -z "${2:-}" ]] && { err "Usage: $0 update <meeting_id> [options]"; exit 1; }
    shift; cmd_update "$@" ;;
  delete|rm|remove)
    [[ -z "${2:-}" ]] && { err "Usage: $0 delete <meeting_id>"; exit 1; }
    cmd_delete "$2" ;;
  raw)
    shift; cmd_raw "$@" ;;
  help|--help|-h)
    echo ""
    echo -e "${CYAN}zoom-cli.sh${NC} — Manage Zoom meetings from the terminal"
    echo ""
    echo "Commands:"
    echo "  login                 Open browser, do SSO, capture cookies automatically"
    echo "  set-cookies \"<str>\"   Import cookies from browser (raw string)"
    echo "  import-cookies [file]  Import from Netscape cookies.txt"
    echo "  refresh-csrf          Get CSRF token (run after set/import-cookies)"
    echo "  list                  List upcoming meetings"
    echo "  view <id>             View meeting details"
    echo "  create [options]      Schedule a meeting (--help for opts)"
    echo "  update <id> [opts]    Update a meeting"
    echo "  delete <id>           Delete a meeting"
    echo "  raw GET|POST <path>   Raw request for debugging"
    echo ""
    echo "Setup (easy):"
    echo "  1. ./zoom-cli.sh login      (opens browser, captures cookies + CSRF)"
    echo "  2. ./zoom-cli.sh list"
    echo ""
    echo "Setup (manual):"
    echo "  1. Sign into ${ZOOM_BASE} in Chrome"
    echo "  2. DevTools Console →  copy(document.cookie)"
    echo "  3. ./zoom-cli.sh set-cookies \"<paste>\""
    echo "  4. ./zoom-cli.sh refresh-csrf"
    echo "  5. ./zoom-cli.sh list"
    echo ""
    echo "Env: ZOOM_DEBUG=1 for verbose output"
    echo ""
    ;;
  *) err "Unknown: $1 — try '$0 help'"; exit 1 ;;
esac

fi  # end main guard

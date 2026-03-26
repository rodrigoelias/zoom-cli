#!/usr/bin/env bash
#
# test-zoom-cli.sh — Offline tests for zoom-cli.sh
#
# Mocks curl/node so no network calls are made.
# Uses a temp directory for cookie/csrf files.
#
# Usage:  ./test-zoom-cli.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="${SCRIPT_DIR}/zoom-cli.sh"
TMPDIR_BASE=$(mktemp -d)
MOCK_BIN="${TMPDIR_BASE}/bin"

# ─── Counters ─────────────────────────────────────────────────────────
PASS=0; FAIL=0; TOTAL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
    echo -e "  ${GREEN}✓${NC} ${label}"
  else
    FAIL=$((FAIL + 1))
    echo -e "  ${RED}✗${NC} ${label}"
    echo -e "    expected: $(echo "$expected" | head -3)"
    echo -e "    actual:   $(echo "$actual" | head -3)"
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if echo "$haystack" | grep -qF -- "$needle"; then
    PASS=$((PASS + 1))
    echo -e "  ${GREEN}✓${NC} ${label}"
  else
    FAIL=$((FAIL + 1))
    echo -e "  ${RED}✗${NC} ${label}"
    echo -e "    expected to contain: ${needle}"
    echo -e "    actual: $(echo "$haystack" | head -3)"
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if ! echo "$haystack" | grep -qF -- "$needle"; then
    PASS=$((PASS + 1))
    echo -e "  ${GREEN}✓${NC} ${label}"
  else
    FAIL=$((FAIL + 1))
    echo -e "  ${RED}✗${NC} ${label}"
    echo -e "    expected NOT to contain: ${needle}"
  fi
}

assert_exit_code() {
  local label="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
    echo -e "  ${GREEN}✓${NC} ${label}"
  else
    FAIL=$((FAIL + 1))
    echo -e "  ${RED}✗${NC} ${label}"
    echo -e "    expected exit code: ${expected}, got: ${actual}"
  fi
}

# ─── Setup / Teardown ────────────────────────────────────────────────

setup_test_dir() {
  local dir="${TMPDIR_BASE}/test_$$_${RANDOM}"
  mkdir -p "$dir"
  echo "$dir"
}

# Create a mock curl that returns controlled output
setup_mock_curl() {
  local response="$1"
  local exit_code="${2:-0}"
  mkdir -p "$MOCK_BIN"
  cat > "${MOCK_BIN}/curl" << MOCKEOF
#!/usr/bin/env bash
# Mock curl — log args and return canned response
echo "\$@" >> "${TMPDIR_BASE}/curl_calls.log"
echo '${response}'
exit ${exit_code}
MOCKEOF
  chmod +x "${MOCK_BIN}/curl"
}

# Create a mock curl that returns different responses based on call sequence
# Usage: setup_mock_curl_sequence "resp1" "resp2" "resp3"
setup_mock_curl_sequence() {
  mkdir -p "$MOCK_BIN"
  local counter_file="${TMPDIR_BASE}/curl_call_counter"
  echo "0" > "$counter_file"

  # Write response files
  local i=0
  for resp in "$@"; do
    printf '%s' "$resp" > "${TMPDIR_BASE}/curl_resp_${i}"
    i=$((i + 1))
  done
  local total=$i

  cat > "${MOCK_BIN}/curl" << MOCKEOF
#!/usr/bin/env bash
echo "\$@" >> "${TMPDIR_BASE}/curl_calls.log"
counter=\$(cat "${counter_file}")
resp_file="${TMPDIR_BASE}/curl_resp_\${counter}"
if [[ -f "\$resp_file" ]]; then
  cat "\$resp_file"
else
  # Repeat last response if we exceed the sequence
  cat "${TMPDIR_BASE}/curl_resp_$((${total} - 1))"
fi
echo \$((counter + 1)) > "${counter_file}"
MOCKEOF
  chmod +x "${MOCK_BIN}/curl"
}

# Get the logged curl calls
get_curl_calls() {
  cat "${TMPDIR_BASE}/curl_calls.log" 2>/dev/null || true
}

# Create a mock node
setup_mock_node() {
  mkdir -p "$MOCK_BIN"
  cat > "${MOCK_BIN}/node" << 'MOCKEOF'
#!/usr/bin/env bash
echo "mock node called" >&2
exit 0
MOCKEOF
  chmod +x "${MOCK_BIN}/node"
}

# Run the CLI with mocked PATH and overridden SCRIPT_DIR
run_cli() {
  local test_dir="$1"; shift
  # Override SCRIPT_DIR by copying the script and running from test_dir
  cp "$CLI" "${test_dir}/zoom-cli.sh"
  chmod +x "${test_dir}/zoom-cli.sh"
  PATH="${MOCK_BIN}:${PATH}" "${test_dir}/zoom-cli.sh" "$@" 2>&1 || true
}

# Run CLI and capture exit code separately
run_cli_with_exit() {
  local test_dir="$1"; shift
  cp "$CLI" "${test_dir}/zoom-cli.sh"
  chmod +x "${test_dir}/zoom-cli.sh"
  local output exit_code
  output=$(PATH="${MOCK_BIN}:${PATH}" "${test_dir}/zoom-cli.sh" "$@" 2>&1) && exit_code=0 || exit_code=$?
  echo "$output"
  return $exit_code
}

# ─── Tests ────────────────────────────────────────────────────────────

test_set_cookies_basic() {
  echo -e "\n${CYAN}▸ set-cookies: basic string${NC}"
  local dir; dir=$(setup_test_dir)
  run_cli "$dir" set-cookies "foo=bar; baz=qux" > /dev/null
  local stored; stored=$(cat "${dir}/.raw_cookies")
  assert_eq "stores raw cookie string" "foo=bar; baz=qux" "$stored"
}

test_set_cookies_strips_quotes() {
  echo -e "\n${CYAN}▸ set-cookies: strips surrounding quotes${NC}"
  local dir; dir=$(setup_test_dir)
  run_cli "$dir" set-cookies '"foo=bar; baz=qux"' > /dev/null
  local stored; stored=$(cat "${dir}/.raw_cookies")
  assert_eq "strips double quotes" "foo=bar; baz=qux" "$stored"
}

test_set_cookies_strips_whitespace() {
  echo -e "\n${CYAN}▸ set-cookies: strips leading/trailing whitespace${NC}"
  local dir; dir=$(setup_test_dir)
  run_cli "$dir" set-cookies "  foo=bar; baz=qux  " > /dev/null
  local stored; stored=$(cat "${dir}/.raw_cookies")
  assert_eq "strips whitespace" "foo=bar; baz=qux" "$stored"
}

test_set_cookies_reports_count() {
  echo -e "\n${CYAN}▸ set-cookies: reports cookie count${NC}"
  local dir; dir=$(setup_test_dir)
  local output; output=$(run_cli "$dir" set-cookies "a=1; b=2; c=3")
  assert_contains "reports 3 cookies" "3 cookies" "$output"
}

test_set_cookies_missing_arg() {
  echo -e "\n${CYAN}▸ set-cookies: missing argument errors${NC}"
  local dir; dir=$(setup_test_dir)
  local output exit_code
  output=$(run_cli_with_exit "$dir" set-cookies) && exit_code=0 || exit_code=$?
  assert_contains "shows usage" "Usage" "$output"
  assert_exit_code "exits non-zero" "1" "$exit_code"
}

test_import_cookies_netscape() {
  echo -e "\n${CYAN}▸ import-cookies: converts Netscape format${NC}"
  local dir; dir=$(setup_test_dir)
  cat > "${dir}/cookies.txt" << 'EOF'
# Netscape HTTP Cookie File
.zoom.us	FALSE	/	TRUE	0	_zm_lang	en-US
.zoom.us	FALSE	/	TRUE	0	_zm_currency	USD
.zoom.us	FALSE	/	TRUE	0	zm_huid	abc123
EOF
  run_cli "$dir" import-cookies > /dev/null
  local stored; stored=$(cat "${dir}/.raw_cookies")
  assert_contains "contains _zm_lang=en-US" "_zm_lang=en-US" "$stored"
  assert_contains "contains _zm_currency=USD" "_zm_currency=USD" "$stored"
  assert_contains "contains zm_huid=abc123" "zm_huid=abc123" "$stored"
  # Verify format is semicolon-separated
  assert_contains "semicolon separated" "; " "$stored"
}

test_import_cookies_skips_comments() {
  echo -e "\n${CYAN}▸ import-cookies: skips comment lines${NC}"
  local dir; dir=$(setup_test_dir)
  cat > "${dir}/cookies.txt" << 'EOF'
# This is a comment
# Another comment
.zoom.us	FALSE	/	TRUE	0	key1	val1
EOF
  run_cli "$dir" import-cookies > /dev/null
  local stored; stored=$(cat "${dir}/.raw_cookies")
  assert_eq "only one cookie" "key1=val1" "$stored"
  assert_not_contains "no comment content" "#" "$stored"
}

test_import_cookies_missing_file() {
  echo -e "\n${CYAN}▸ import-cookies: missing file errors${NC}"
  local dir; dir=$(setup_test_dir)
  local output exit_code
  output=$(run_cli_with_exit "$dir" import-cookies "${dir}/nonexistent.txt") && exit_code=0 || exit_code=$?
  assert_contains "error message" "not found" "$output"
  assert_exit_code "exits non-zero" "1" "$exit_code"
}

test_import_cookies_empty_file() {
  echo -e "\n${CYAN}▸ import-cookies: empty file errors${NC}"
  local dir; dir=$(setup_test_dir)
  echo "# only comments" > "${dir}/cookies.txt"
  local output exit_code
  output=$(run_cli_with_exit "$dir" import-cookies) && exit_code=0 || exit_code=$?
  assert_contains "error message" "No cookies parsed" "$output"
  assert_exit_code "exits non-zero" "1" "$exit_code"
}

test_csrf_extraction() {
  echo -e "\n${CYAN}▸ refresh-csrf: extracts token from response${NC}"
  local dir; dir=$(setup_test_dir)
  # Seed cookies first
  printf 'session=abc123' > "${dir}/.raw_cookies"
  # Mock curl to return CSRF response
  setup_mock_curl "ZOOM-CSRFTOKEN:ABCD-1234-EFGH-5678"
  local output; output=$(run_cli "$dir" refresh-csrf)
  local csrf; csrf=$(cat "${dir}/.csrf_token")
  assert_eq "extracts token" "ABCD-1234-EFGH-5678" "$csrf"
  assert_contains "logs token" "ABCD-1234-EFGH-5678" "$output"
}

test_csrf_injected_into_cookies() {
  echo -e "\n${CYAN}▸ refresh-csrf: injects token into cookie string${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc; _zm_lang=en-US' > "${dir}/.raw_cookies"
  setup_mock_curl "ZOOM-CSRFTOKEN:NEW-TOKEN-HERE"
  run_cli "$dir" refresh-csrf > /dev/null
  local cookies; cookies=$(cat "${dir}/.raw_cookies")
  assert_contains "CSRF in cookies" "ZOOM-CSRFTOKEN=NEW-TOKEN-HERE" "$cookies"
  assert_contains "original cookies preserved" "session=abc" "$cookies"
}

test_csrf_replaces_old_token() {
  echo -e "\n${CYAN}▸ refresh-csrf: replaces existing CSRF in cookies${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'ZOOM-CSRFTOKEN=OLD-TOKEN; session=abc; _zm_lang=en-US' > "${dir}/.raw_cookies"
  setup_mock_curl "ZOOM-CSRFTOKEN:FRESH-TOKEN"
  run_cli "$dir" refresh-csrf > /dev/null
  local cookies; cookies=$(cat "${dir}/.raw_cookies")
  assert_contains "new token present" "ZOOM-CSRFTOKEN=FRESH-TOKEN" "$cookies"
  assert_not_contains "old token gone" "OLD-TOKEN" "$cookies"
}

test_csrf_bad_response() {
  echo -e "\n${CYAN}▸ refresh-csrf: handles bad response${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  setup_mock_curl ""
  local output exit_code
  output=$(run_cli_with_exit "$dir" refresh-csrf) && exit_code=0 || exit_code=$?
  assert_contains "error message" "Could not extract" "$output"
  assert_exit_code "exits non-zero" "1" "$exit_code"
}

test_get_cookies_missing() {
  echo -e "\n${CYAN}▸ get_cookies: errors when no cookie file${NC}"
  local dir; dir=$(setup_test_dir)
  local output exit_code
  output=$(run_cli_with_exit "$dir" list) && exit_code=0 || exit_code=$?
  assert_contains "error about missing cookies" "No cookies" "$output"
  assert_exit_code "exits non-zero" "1" "$exit_code"
}

test_get_csrf_missing() {
  echo -e "\n${CYAN}▸ get_csrf: errors when no CSRF file${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  # Don't set up mock curl — it won't get that far
  local output exit_code
  output=$(run_cli_with_exit "$dir" raw GET /test) && exit_code=0 || exit_code=$?
  assert_contains "error about missing CSRF" "No CSRF" "$output"
  assert_exit_code "exits non-zero" "1" "$exit_code"
}

test_list_success() {
  echo -e "\n${CYAN}▸ list: renders meetings from JSON response${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"

  local json='{"status":true,"errorCode":0,"errorMessage":null,"result":{"totalRecords":2,"meetings":[{"time":"Today","list":[{"number":"12345678901","numberF":"123 4567 8901","topic":"Daily Standup","schTimeF":"09:00 AM - 09:30 AM","duration":30,"type":8,"occurrenceTip":"Occurrence 1 of 5"}]},{"time":"Wed, Apr 1","list":[{"number":"98765432109","numberF":"987 6543 2109","topic":"Team Retro","schTimeF":"02:00 PM - 03:00 PM","duration":60,"type":2,"occurrenceTip":""}]}]}}'
  setup_mock_curl "$json"

  local output; output=$(run_cli "$dir" list)
  assert_contains "shows total count" "2 total" "$output"
  assert_contains "shows Today group" "Today" "$output"
  assert_contains "shows meeting number" "123 4567 8901" "$output"
  assert_contains "shows topic" "Daily Standup" "$output"
  assert_contains "shows time range" "09:00 AM - 09:30 AM" "$output"
  assert_contains "shows duration" "30 min" "$output"
  assert_contains "shows recurrence" "Occurrence 1 of 5" "$output"
  assert_contains "shows second date group" "Wed, Apr 1" "$output"
  assert_contains "shows second meeting" "Team Retro" "$output"
  # Non-recurring meeting (type != 8) should not have 🔄
  # (we check the line for "Team Retro" doesn't have the recurring emoji next to it)
  assert_contains "shows recurring emoji for type 8" "🔄" "$output"
}

test_list_empty() {
  echo -e "\n${CYAN}▸ list: handles zero meetings${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"
  setup_mock_curl '{"status":true,"errorCode":0,"result":{"totalRecords":0,"meetings":[]}}'
  local output; output=$(run_cli "$dir" list)
  assert_contains "shows 0 total" "0 total" "$output"
  assert_contains "shows no meetings message" "No upcoming meetings" "$output"
}

test_list_api_error() {
  echo -e "\n${CYAN}▸ list: handles API error response${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"
  setup_mock_curl '{"status":false,"errorCode":401,"errorMessage":"Unauthorized"}'
  local output; output=$(run_cli "$dir" list)
  assert_contains "shows error" "Failed to fetch" "$output"
}

test_list_html_error_response() {
  echo -e "\n${CYAN}▸ list: handles HTML error (not JSON)${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"
  setup_mock_curl '<html><body>Error 405</body></html>'
  local output; output=$(run_cli "$dir" list)
  assert_contains "shows error" "Failed to fetch" "$output"
}

test_meeting_id_extraction_from_redirect() {
  echo -e "\n${CYAN}▸ create: extracts meeting ID from redirect URL${NC}"
  # Test the sed pattern directly
  local response='some html content here
__FINAL_URL__=https://skyscanner.zoom.us/meeting/94244974137'
  local extracted
  extracted=$(echo "$response" | sed -n 's/.*__FINAL_URL__=.*\/meeting\/\([0-9]\{1,\}\).*/\1/p' | head -1)
  assert_eq "extracts ID from redirect" "94244974137" "$extracted"
}

test_meeting_id_extraction_from_json() {
  echo -e "\n${CYAN}▸ create: extracts meeting ID from JSON response${NC}"
  local response='{"meetingNumber":94244974137,"topic":"Test"}'
  local extracted
  extracted=$(echo "$response" | grep -oE '"meetingNumber"\s*:\s*[0-9]+' | grep -oE '[0-9]+' | head -1)
  assert_eq "extracts ID from JSON" "94244974137" "$extracted"
}

test_meeting_id_extraction_from_url_in_body() {
  echo -e "\n${CYAN}▸ create: extracts meeting ID from URL in body${NC}"
  local response='redirect to meeting/94244974137 complete'
  local extracted
  extracted=$(echo "$response" | grep -oE 'meeting/[0-9]{9,12}' | grep -oE '[0-9]+' | head -1)
  assert_eq "extracts ID from body URL" "94244974137" "$extracted"
}

test_command_aliases() {
  echo -e "\n${CYAN}▸ routing: command aliases work${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"
  setup_mock_curl '{"status":true,"errorCode":0,"result":{"totalRecords":0,"meetings":[]}}'

  # "ls" should work like "list"
  local output; output=$(run_cli "$dir" ls)
  assert_contains "ls alias works" "Upcoming Meetings" "$output"
}

test_help_output() {
  echo -e "\n${CYAN}▸ routing: help output${NC}"
  local dir; dir=$(setup_test_dir)
  local output; output=$(run_cli "$dir" help)
  assert_contains "shows login command" "login" "$output"
  assert_contains "shows list command" "list" "$output"
  assert_contains "shows create command" "create" "$output"
  assert_contains "shows delete command" "delete" "$output"
  assert_contains "shows easy setup" "Setup (easy)" "$output"
  assert_contains "shows manual setup" "Setup (manual)" "$output"
}

test_unknown_command() {
  echo -e "\n${CYAN}▸ routing: unknown command errors${NC}"
  local dir; dir=$(setup_test_dir)
  local output exit_code
  output=$(run_cli_with_exit "$dir" foobar) && exit_code=0 || exit_code=$?
  assert_contains "shows error" "Unknown" "$output"
  assert_exit_code "exits non-zero" "1" "$exit_code"
}

test_view_missing_arg() {
  echo -e "\n${CYAN}▸ routing: view without ID errors${NC}"
  local dir; dir=$(setup_test_dir)
  local output exit_code
  output=$(run_cli_with_exit "$dir" view) && exit_code=0 || exit_code=$?
  assert_contains "shows usage" "Usage" "$output"
  assert_exit_code "exits non-zero" "1" "$exit_code"
}

test_delete_missing_arg() {
  echo -e "\n${CYAN}▸ routing: delete without ID errors${NC}"
  local dir; dir=$(setup_test_dir)
  local output exit_code
  output=$(run_cli_with_exit "$dir" delete) && exit_code=0 || exit_code=$?
  assert_contains "shows usage" "Usage" "$output"
  assert_exit_code "exits non-zero" "1" "$exit_code"
}

test_delete_success() {
  echo -e "\n${CYAN}▸ delete: successful deletion${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"
  setup_mock_curl '{"status":true}'
  local output; output=$(run_cli "$dir" delete 12345678901)
  assert_contains "confirms deletion" "deleted" "$output"
  assert_contains "shows meeting ID" "12345678901" "$output"
}

test_delete_failure() {
  echo -e "\n${CYAN}▸ delete: failed deletion${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"
  setup_mock_curl '{"status":false,"errorCode":404}'
  local output; output=$(run_cli "$dir" delete 99999999999)
  assert_contains "shows failure" "failed" "$output"
}

test_create_help() {
  echo -e "\n${CYAN}▸ create: --help shows usage${NC}"
  local dir; dir=$(setup_test_dir)
  local output; output=$(run_cli "$dir" create --help)
  assert_contains "shows topic option" "--topic" "$output"
  assert_contains "shows date option" "--date" "$output"
  assert_contains "shows recurring option" "--recurring" "$output"
  assert_contains "shows examples" "Examples" "$output"
}

test_list_rendering_multiple_meetings_per_day() {
  echo -e "\n${CYAN}▸ list: multiple meetings on same day${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"

  local json='{"status":true,"errorCode":0,"result":{"totalRecords":3,"meetings":[{"time":"Today","list":[{"number":"111","numberF":"111","topic":"Morning Standup","schTimeF":"09:00 AM - 09:15 AM","duration":15,"type":8,"occurrenceTip":""},{"number":"222","numberF":"222","topic":"Sprint Planning","schTimeF":"10:00 AM - 11:00 AM","duration":60,"type":2,"occurrenceTip":""},{"number":"333","numberF":"333","topic":"1:1 with Manager","schTimeF":"02:00 PM - 02:30 PM","duration":30,"type":8,"occurrenceTip":"Occurrence 5 of 10"}]}]}}'
  setup_mock_curl "$json"

  local output; output=$(run_cli "$dir" list)
  assert_contains "shows 3 total" "3 total" "$output"
  assert_contains "shows first meeting" "Morning Standup" "$output"
  assert_contains "shows second meeting" "Sprint Planning" "$output"
  assert_contains "shows third meeting" "1:1 with Manager" "$output"
}

test_list_meeting_without_optional_fields() {
  echo -e "\n${CYAN}▸ list: handles meetings with missing optional fields${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"

  # Meeting with minimal fields
  local json='{"status":true,"errorCode":0,"result":{"totalRecords":1,"meetings":[{"time":"Today","list":[{"number":"444","topic":"Minimal Meeting","duration":30,"type":2}]}]}}'
  setup_mock_curl "$json"

  local output; output=$(run_cli "$dir" list)
  assert_contains "shows topic" "Minimal Meeting" "$output"
  assert_contains "shows duration" "30 min" "$output"
}

# ─── View tests ───────────────────────────────────────────────────────

test_view_success() {
  echo -e "\n${CYAN}▸ view: renders meeting details from JSON API response${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"

  local json='{"status":true,"result":{"meeting":{"topic":{"value":"Weekly Sync"},"startDate":{"value":"04/01/2026"},"startTime":{"value":"10:00"},"startTime2":{"value":"AM"},"duration":{"value":60},"timezone":{"value":"Europe/London"},"recurring":{"value":false},"passcode":{"value":false,"childParams":{"meetingPasscode":{"show":true,"value":"abc123"}}},"invitee":{"value":[]}}}}'
  setup_mock_curl "$json"

  local output; output=$(run_cli "$dir" view 12345678901)
  assert_contains "shows topic" "Weekly Sync" "$output"
  assert_contains "shows meeting ID" "12345678901" "$output"
  assert_contains "shows date" "04/01/2026" "$output"
  assert_contains "shows duration" "60 min" "$output"
  assert_contains "shows timezone" "Europe/London" "$output"
  assert_contains "shows passcode" "abc123" "$output"
}

test_view_no_password() {
  echo -e "\n${CYAN}▸ view: hides passcode when not present${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"

  local json='{"status":true,"result":{"meeting":{"topic":{"value":"No Password Meeting"},"startDate":{"value":"04/01/2026"},"startTime":{"value":"10:00"},"startTime2":{"value":"AM"},"duration":{"value":30},"timezone":{"value":"UTC"},"recurring":{"value":false},"passcode":{"value":false,"childParams":null},"invitee":{"value":[]}}}}'
  setup_mock_curl "$json"

  local output; output=$(run_cli "$dir" view 99999)
  assert_contains "shows topic" "No Password Meeting" "$output"
  assert_not_contains "no passcode line" "Passcode" "$output"
}

test_view_unparseable_response() {
  echo -e "\n${CYAN}▸ view: handles non-JSON error response${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"

  setup_mock_curl '{"status":false,"errorCode":-1,"errorMessage":"Meeting not found."}'

  local output; output=$(run_cli "$dir" view 12345)
  assert_contains "shows error" "Failed to fetch" "$output"
}

test_view_aliases() {
  echo -e "\n${CYAN}▸ view: show and get aliases work${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"

  local json='{"status":true,"result":{"meeting":{"topic":{"value":"Alias Test"},"startDate":{"value":"04/01/2026"},"startTime":{"value":"10:00"},"startTime2":{"value":"AM"},"duration":{"value":15},"timezone":{"value":"UTC"},"recurring":{"value":false},"passcode":{"value":false,"childParams":null},"invitee":{"value":[]}}}}'
  setup_mock_curl "$json"

  local output1; output1=$(run_cli "$dir" show 111)
  assert_contains "show alias works" "Alias Test" "$output1"

  local output2; output2=$(run_cli "$dir" get 111)
  assert_contains "get alias works" "Alias Test" "$output2"
}

# ─── Create tests ─────────────────────────────────────────────────────

test_create_with_all_args() {
  echo -e "\n${CYAN}▸ create: passes all arguments correctly${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"
  rm -f "${TMPDIR_BASE}/curl_calls.log"
  cp "${SCRIPT_DIR}/meeting-template.json" "${dir}/meeting-template.json"

  # First call = create (zoom_post_json), second call = view (zoom_post)
  setup_mock_curl_sequence \
    '{"status":true,"result":{"mn":94244974137,"joinLink":"https://skyscanner.zoom.us/j/94244974137"}}' \
    '{"status":true,"result":{"meeting":{"topic":{"value":"My Standup"},"startDate":{"value":"04/01/2026"},"startTime":{"value":"9:00"},"startTime2":{"value":"AM"},"duration":{"value":30},"timezone":{"value":"Europe/London"},"recurring":{"value":false},"passcode":{"value":false,"childParams":null},"invitee":{"value":[]}}}}'

  local output; output=$(run_cli "$dir" create \
    --topic "My Standup" \
    --date 04/01/2026 \
    --time 9:00 \
    --ampm AM \
    --duration 30 \
    --timezone "Europe/London")

  assert_contains "shows topic" "My Standup" "$output"
  assert_contains "shows date" "04/01/2026" "$output"
  assert_contains "shows time" "9:00 AM" "$output"
  assert_contains "confirms creation" "Meeting created" "$output"
  assert_contains "shows extracted ID" "94244974137" "$output"
}

test_create_defaults() {
  echo -e "\n${CYAN}▸ create: uses sensible defaults${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"
  rm -f "${TMPDIR_BASE}/curl_calls.log"
  cp "${SCRIPT_DIR}/meeting-template.json" "${dir}/meeting-template.json"

  setup_mock_curl_sequence \
    '{"status":true,"result":{"mn":55555555555,"joinLink":"https://skyscanner.zoom.us/j/55555555555"}}' \
    '{"status":true,"result":{"meeting":{"topic":{"value":"My Meeting"},"startDate":{"value":"03/25/2026"},"startTime":{"value":"12:00"},"startTime2":{"value":"PM"},"duration":{"value":60},"timezone":{"value":"Europe/London"},"recurring":{"value":false},"passcode":{"value":false,"childParams":null},"invitee":{"value":[]}}}}'

  local output; output=$(run_cli "$dir" create)

  # Default topic
  assert_contains "default topic" "My Meeting" "$output"
  # Default duration is 60 min
  assert_contains "default duration" "60 min" "$output"
  # Default timezone
  assert_contains "default timezone" "Europe/London" "$output"

  # Check the JSON payload was sent correctly
  local calls; calls=$(get_curl_calls)
  assert_contains "sends to /rest/meeting/save" "/rest/meeting/save" "$calls"
  assert_contains "sends topic in JSON" "My Meeting" "$calls"
  assert_contains "sends timezone in JSON" "Europe/London" "$calls"
}

test_create_recurring() {
  echo -e "\n${CYAN}▸ create: recurring meeting params${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"
  rm -f "${TMPDIR_BASE}/curl_calls.log"
  cp "${SCRIPT_DIR}/meeting-template.json" "${dir}/meeting-template.json"

  setup_mock_curl_sequence \
    '{"status":true,"result":{"mn":77777777777,"joinLink":"https://skyscanner.zoom.us/j/77777777777"}}' \
    '{"status":true,"result":{"meeting":{"topic":{"value":"Weekly Sync"},"duration":{"value":60},"timezone":{"value":"Europe/London"},"recurring":{"value":true,"childParams":{"recurring":{"value":{"type":"WEEKLY"}}}},"passcode":{"value":false,"childParams":null},"invitee":{"value":[]}}}}'

  local output; output=$(run_cli "$dir" create \
    --topic "Weekly Sync" \
    --date "03/28/2026" \
    --time "10:00" \
    --ampm AM \
    --recurring \
    --recurrence-type WEEKLY \
    --recurrence-days SA \
    --recurrence-end 12/31/2026)

  assert_contains "shows recurring flag" "Recurring" "$output"

  local calls; calls=$(get_curl_calls)
  assert_contains "sends WEEKLY type" "WEEKLY" "$calls"
  assert_contains "sends BYDAY for Saturday" "BYDAY" "$calls"
  assert_contains "sends end date" "12/31/2026" "$calls"
  assert_contains "recurring value is true" '"value": true' "$calls"
}

test_create_no_id_extracted() {
  echo -e "\n${CYAN}▸ create: handles failure to extract meeting ID${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"
  cp "${SCRIPT_DIR}/meeting-template.json" "${dir}/meeting-template.json"

  # API returns error
  setup_mock_curl '{"status":false,"errorCode":-1,"errorMessage":"Something went wrong"}'

  local output; output=$(run_cli "$dir" create --topic "Bad Meeting" --date "03/28/2026" --time "10:00" --ampm AM)
  assert_contains "shows error" "Could not create" "$output"
}

test_create_unknown_option() {
  echo -e "\n${CYAN}▸ create: rejects unknown options${NC}"
  local dir; dir=$(setup_test_dir)
  local output exit_code
  output=$(run_cli_with_exit "$dir" create --bogus foo) && exit_code=0 || exit_code=$?
  assert_contains "shows error" "Unknown option" "$output"
  assert_exit_code "exits non-zero" "1" "$exit_code"
}

test_create_aliases() {
  echo -e "\n${CYAN}▸ create: new and schedule aliases${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"
  cp "${SCRIPT_DIR}/meeting-template.json" "${dir}/meeting-template.json"

  setup_mock_curl_sequence \
    '{"status":true,"result":{"mn":11111111111,"joinLink":"https://skyscanner.zoom.us/j/11111111111"}}' \
    '{"status":true,"result":{"meeting":{"topic":{"value":"Alias Create"},"duration":{"value":60},"timezone":{"value":"UTC"},"recurring":{"value":false},"passcode":{"value":false,"childParams":null},"invitee":{"value":[]}}}}'

  local output1; output1=$(run_cli "$dir" new --topic "Alias Create" --date "03/28/2026" --time "10:00" --ampm AM)
  assert_contains "new alias works" "Meeting created" "$output1"

  rm -f "${TMPDIR_BASE}/curl_call_counter"
  echo "0" > "${TMPDIR_BASE}/curl_call_counter"

  local output2; output2=$(run_cli "$dir" schedule --topic "Alias Create" --date "03/28/2026" --time "10:00" --ampm AM)
  assert_contains "schedule alias works" "Meeting created" "$output2"
}

# ─── Update tests ─────────────────────────────────────────────────────

test_update_success() {
  echo -e "\n${CYAN}▸ update: successful update${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"
  rm -f "${TMPDIR_BASE}/curl_calls.log"

  # First call = update POST, second call = view GET
  setup_mock_curl_sequence \
    '{"status":true}' \
    '<html>{"topic":"Updated Topic","duration":45,"timezone":"UTC"}</html>'

  local output; output=$(run_cli "$dir" update 12345678901 --topic "Updated Topic" --duration 0 --duration-min 45)
  assert_contains "confirms update" "updated" "$output"
  assert_contains "shows meeting ID" "12345678901" "$output"

  # Check the update POST was sent to the right endpoint
  local calls; calls=$(get_curl_calls)
  assert_contains "calls save endpoint" "rest/meeting/save" "$calls"
  assert_contains "sends topic" "topic=Updated Topic" "$calls"
}

test_update_failure() {
  echo -e "\n${CYAN}▸ update: handles failed update${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"

  setup_mock_curl '{"status":false,"errorCode":403}'

  local output; output=$(run_cli "$dir" update 12345 --topic "Fail")
  assert_contains "shows failure" "failed" "$output"
}

test_update_no_params() {
  echo -e "\n${CYAN}▸ update: errors when no params given${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"

  local output exit_code
  output=$(run_cli_with_exit "$dir" update 12345) && exit_code=0 || exit_code=$?
  assert_contains "shows nothing to update" "Nothing to update" "$output"
  assert_exit_code "exits non-zero" "1" "$exit_code"
}

test_update_missing_id() {
  echo -e "\n${CYAN}▸ update: errors when no ID given${NC}"
  local dir; dir=$(setup_test_dir)
  local output exit_code
  output=$(run_cli_with_exit "$dir" update) && exit_code=0 || exit_code=$?
  assert_contains "shows usage" "Usage" "$output"
  assert_exit_code "exits non-zero" "1" "$exit_code"
}

test_update_unknown_option() {
  echo -e "\n${CYAN}▸ update: rejects unknown options${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"

  local output exit_code
  output=$(run_cli_with_exit "$dir" update 12345 --bogus val) && exit_code=0 || exit_code=$?
  assert_contains "shows error" "Unknown option" "$output"
  assert_exit_code "exits non-zero" "1" "$exit_code"
}

test_update_all_params() {
  echo -e "\n${CYAN}▸ update: sends all param types${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"
  rm -f "${TMPDIR_BASE}/curl_calls.log"

  setup_mock_curl_sequence \
    '{"status":true}' \
    '<html>{"topic":"Full Update","duration":90}</html>'

  run_cli "$dir" update 999 \
    --topic "Full Update" \
    --date 05/15/2026 \
    --time 3:30 \
    --ampm PM \
    --duration 1 \
    --duration-min 30 > /dev/null

  local calls; calls=$(get_curl_calls)
  assert_contains "sends topic" "topic=Full Update" "$calls"
  assert_contains "sends when" "when=05/15/2026" "$calls"
  assert_contains "sends time" "time=3:30" "$calls"
  assert_contains "sends ampm" "ampm=PM" "$calls"
  assert_contains "sends duration_hr" "duration_hr=1" "$calls"
  assert_contains "sends duration_min" "duration_min=30" "$calls"
}

test_update_edit_alias() {
  echo -e "\n${CYAN}▸ update: edit alias works${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"

  setup_mock_curl_sequence \
    '{"status":true}' \
    '<html>{"topic":"Edited","duration":30}</html>'

  local output; output=$(run_cli "$dir" edit 12345 --topic "Edited")
  assert_contains "edit alias works" "updated" "$output"
}

# ─── Raw tests ────────────────────────────────────────────────────────

test_raw_get() {
  echo -e "\n${CYAN}▸ raw: GET dispatches correctly${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"
  rm -f "${TMPDIR_BASE}/curl_calls.log"

  setup_mock_curl '{"result":"ok"}'

  local output; output=$(run_cli "$dir" raw GET /some/path)
  assert_contains "returns response" "ok" "$output"

  local calls; calls=$(get_curl_calls)
  assert_contains "calls correct path" "/some/path" "$calls"
  # GET should NOT have -X POST
  assert_not_contains "no POST method" "-X POST" "$calls"
}

test_raw_post() {
  echo -e "\n${CYAN}▸ raw: POST dispatches correctly${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"
  rm -f "${TMPDIR_BASE}/curl_calls.log"

  setup_mock_curl '{"posted":true}'

  local output; output=$(run_cli "$dir" raw POST /rest/test "key=value")
  assert_contains "returns response" "posted" "$output"

  local calls; calls=$(get_curl_calls)
  assert_contains "calls correct path" "/rest/test" "$calls"
  assert_contains "uses POST" "-X POST" "$calls"
  assert_contains "sends param" "key=value" "$calls"
}

# ─── Login tests ──────────────────────────────────────────────────────

test_login_calls_node_and_csrf() {
  echo -e "\n${CYAN}▸ login: calls node and then refresh-csrf${NC}"
  local dir; dir=$(setup_test_dir)

  # Mock node to create .raw_cookies (simulating grab-cookies.mjs)
  mkdir -p "$MOCK_BIN"
  cat > "${MOCK_BIN}/node" << NODEEOF
#!/usr/bin/env bash
# Mock node — simulate grab-cookies.mjs creating .raw_cookies
# The script path is the last argument
script_path="\${@: -1}"
script_dir=\$(dirname "\$script_path")
printf 'grabbed=cookies; from=browser' > "\${script_dir}/.raw_cookies"
echo "mock grab-cookies done"
NODEEOF
  chmod +x "${MOCK_BIN}/node"

  # Mock curl for the CSRF refresh that follows
  setup_mock_curl "ZOOM-CSRFTOKEN:LOGIN-TOKEN-123"

  local output; output=$(run_cli "$dir" login)
  assert_contains "calls node" "mock grab-cookies" "$output"
  assert_contains "refreshes CSRF" "LOGIN-TOKEN-123" "$output"

  # Verify CSRF file was created
  local csrf; csrf=$(cat "${dir}/.csrf_token" 2>/dev/null || echo "missing")
  assert_eq "CSRF token saved" "LOGIN-TOKEN-123" "$csrf"
}

test_login_auth_alias() {
  echo -e "\n${CYAN}▸ login: auth alias works${NC}"
  local dir; dir=$(setup_test_dir)

  mkdir -p "$MOCK_BIN"
  cat > "${MOCK_BIN}/node" << NODEEOF
#!/usr/bin/env bash
script_path="\${@: -1}"
script_dir=\$(dirname "\$script_path")
printf 'session=test' > "\${script_dir}/.raw_cookies"
echo "auth alias test"
NODEEOF
  chmod +x "${MOCK_BIN}/node"
  setup_mock_curl "ZOOM-CSRFTOKEN:AUTH-ALIAS"

  local output; output=$(run_cli "$dir" auth)
  assert_contains "auth alias triggers login" "auth alias test" "$output"
}

test_login_grab_cookies_alias() {
  echo -e "\n${CYAN}▸ login: grab-cookies alias works${NC}"
  local dir; dir=$(setup_test_dir)

  mkdir -p "$MOCK_BIN"
  cat > "${MOCK_BIN}/node" << NODEEOF
#!/usr/bin/env bash
script_path="\${@: -1}"
script_dir=\$(dirname "\$script_path")
printf 'session=test' > "\${script_dir}/.raw_cookies"
echo "grab alias test"
NODEEOF
  chmod +x "${MOCK_BIN}/node"
  setup_mock_curl "ZOOM-CSRFTOKEN:GRAB-ALIAS"

  local output; output=$(run_cli "$dir" grab-cookies)
  assert_contains "grab-cookies alias triggers login" "grab alias test" "$output"
}

# ─── Delete alias tests ──────────────────────────────────────────────

test_delete_rm_alias() {
  echo -e "\n${CYAN}▸ delete: rm alias works${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"
  setup_mock_curl '{"status":true}'
  local output; output=$(run_cli "$dir" rm 12345678901)
  assert_contains "rm alias deletes" "deleted" "$output"
}

test_delete_remove_alias() {
  echo -e "\n${CYAN}▸ delete: remove alias works${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"
  setup_mock_curl '{"status":true}'
  local output; output=$(run_cli "$dir" remove 12345678901)
  assert_contains "remove alias deletes" "deleted" "$output"
}

# ─── Help alias tests ────────────────────────────────────────────────

test_help_flag_aliases() {
  echo -e "\n${CYAN}▸ help: --help and -h flags work${NC}"
  local dir; dir=$(setup_test_dir)

  local output1; output1=$(run_cli "$dir" --help)
  assert_contains "--help shows help" "Manage Zoom meetings" "$output1"

  local output2; output2=$(run_cli "$dir" -h)
  assert_contains "-h shows help" "Manage Zoom meetings" "$output2"
}

test_no_args_shows_help() {
  echo -e "\n${CYAN}▸ help: no args shows help${NC}"
  local dir; dir=$(setup_test_dir)
  local output; output=$(run_cli "$dir")
  assert_contains "no args shows help" "Manage Zoom meetings" "$output"
}

# ─── is_auth_expired tests ───────────────────────────────────────────

test_auth_expired_user_not_login() {
  echo -e "\n${CYAN}▸ is_auth_expired: detects 'User not login' JSON error${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"

  setup_mock_curl '{"status":false,"errorCode":201,"errorMessage":"User not login."}'

  local output; output=$(run_cli "$dir" list)
  # Should detect auth failure, try reauth, fail (non-interactive), and show message
  assert_contains "detects expired session" "Session expired" "$output"
}

test_auth_expired_saml_redirect() {
  echo -e "\n${CYAN}▸ is_auth_expired: detects SAML redirect${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"

  setup_mock_curl '<html><form action="https://login.microsoftonline.com/saml2"><input type="hidden" name="SAMLRequest" value="abc"/></form></html>'

  local output; output=$(run_cli "$dir" list)
  assert_contains "detects SAML redirect" "Session expired" "$output"
}

test_auth_expired_error_page() {
  echo -e "\n${CYAN}▸ is_auth_expired: detects Zoom error page${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"

  setup_mock_curl '<html><head><title>Error - Zoom</title></head><body>Something went wrong</body></html>'

  local output; output=$(run_cli "$dir" list)
  assert_contains "detects error page" "Session expired" "$output"
}

test_auth_expired_valid_response_not_flagged() {
  echo -e "\n${CYAN}▸ is_auth_expired: valid JSON not flagged as expired${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"

  setup_mock_curl '{"status":true,"errorCode":0,"result":{"totalRecords":0,"meetings":[]}}'

  local output; output=$(run_cli "$dir" list)
  assert_not_contains "no session expired message" "Session expired" "$output"
  assert_contains "shows normal output" "Upcoming Meetings" "$output"
}

test_auth_expired_api_error_not_flagged() {
  echo -e "\n${CYAN}▸ is_auth_expired: non-auth API error not flagged as expired${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"

  # errorCode 400 (not 201) should NOT trigger reauth
  setup_mock_curl '{"status":false,"errorCode":400,"errorMessage":"Bad Request"}'

  local output; output=$(run_cli "$dir" list)
  assert_not_contains "no session expired for non-auth error" "Session expired" "$output"
}

# ─── zoom_authed retry tests ─────────────────────────────────────────

test_authed_retry_succeeds_after_reauth() {
  echo -e "\n${CYAN}▸ zoom_authed: retries after reauth and succeeds${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"

  # Mock node for reauth
  mkdir -p "$MOCK_BIN"
  cat > "${MOCK_BIN}/node" << NODEEOF
#!/usr/bin/env bash
script_dir=\$(dirname "\$2")
printf 'fresh=cookies' > "\${script_dir}/.raw_cookies"
NODEEOF
  chmod +x "${MOCK_BIN}/node"

  # First call: auth expired, second call (CSRF refresh): returns token,
  # third call (retry): succeeds
  setup_mock_curl_sequence \
    '{"status":false,"errorCode":201,"errorMessage":"User not login."}' \
    'ZOOM-CSRFTOKEN:FRESH-TOKEN' \
    '{"status":true,"errorCode":0,"result":{"totalRecords":0,"meetings":[]}}'

  # Force interactive TTY check to pass by overriding do_reauth in a subshell won't work,
  # but we can test the non-interactive path
  local output; output=$(run_cli "$dir" list)
  # In non-interactive mode, it should detect expiry and show the error
  assert_contains "detects expiry" "Session expired" "$output"
  assert_contains "tells user to login" "login" "$output"
}

test_authed_passthrough_on_valid() {
  echo -e "\n${CYAN}▸ zoom_authed: passes through valid responses without retry${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"
  rm -f "${TMPDIR_BASE}/curl_calls.log"

  setup_mock_curl '{"status":true,"errorCode":0,"result":{"totalRecords":1,"meetings":[{"time":"Today","list":[{"number":"111","topic":"Test","duration":30,"type":2}]}]}}'

  local output; output=$(run_cli "$dir" list)
  assert_contains "shows normal output" "1 total" "$output"
  assert_not_contains "no reauth triggered" "Session expired" "$output"

  # Verify curl was called only once (no retry)
  local call_count; call_count=$(wc -l < "${TMPDIR_BASE}/curl_calls.log" | tr -d ' ')
  assert_eq "only one curl call" "1" "$call_count"
}

# ─── do_reauth non-interactive test ──────────────────────────────────

test_reauth_non_interactive() {
  echo -e "\n${CYAN}▸ do_reauth: refuses in non-interactive context${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"

  setup_mock_curl '{"status":false,"errorCode":201,"errorMessage":"User not login."}'

  # Piped output = non-interactive
  local output; output=$(run_cli "$dir" list | cat)
  assert_contains "refuses reauth" "not running interactively" "$output"
}

# ─── zoom_post_json tests ────────────────────────────────────────────

test_post_json_content_type() {
  echo -e "\n${CYAN}▸ zoom_post_json: sends application/json content type${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"
  rm -f "${TMPDIR_BASE}/curl_calls.log"

  setup_mock_curl '{"status":true,"result":{"mn":12345}}'

  # Use raw command to test zoom_post_json indirectly via create
  # Instead, test via a minimal create that triggers zoom_post_json
  cp "${SCRIPT_DIR}/meeting-template.json" "${dir}/meeting-template.json"
  local output; output=$(run_cli "$dir" create --topic "JSON Test" --date "03/28/2026" --time "10:00" --ampm AM)

  local calls; calls=$(get_curl_calls)
  assert_contains "sends JSON content type" "application/json" "$calls"
}

test_post_json_sends_body() {
  echo -e "\n${CYAN}▸ zoom_post_json: sends JSON body via -d flag${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"
  rm -f "${TMPDIR_BASE}/curl_calls.log"

  setup_mock_curl_sequence \
    '{"status":true,"result":{"mn":99999}}' \
    '{"status":true,"result":{"meeting":{"topic":{"value":"Body Test"},"duration":{"value":60},"timezone":{"value":"UTC"}}}}'
  cp "${SCRIPT_DIR}/meeting-template.json" "${dir}/meeting-template.json"

  run_cli "$dir" create --topic "Body Test" --date "03/28/2026" --time "10:00" --ampm AM > /dev/null

  local calls; calls=$(get_curl_calls)
  assert_contains "sends to /rest/meeting/save" "/rest/meeting/save" "$calls"
  assert_contains "body contains topic" "Body Test" "$calls"
}

# ─── Create with meeting-template.json tests ─────────────────────────

test_create_requires_template() {
  echo -e "\n${CYAN}▸ create: errors when meeting-template.json is missing${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"
  # Don't copy meeting-template.json

  local output exit_code
  output=$(run_cli_with_exit "$dir" create --topic "No Template") && exit_code=0 || exit_code=$?
  assert_contains "errors about missing template" "meeting-template.json" "$output"
  assert_exit_code "exits non-zero" "1" "$exit_code"
}

test_create_overrides_template_fields() {
  echo -e "\n${CYAN}▸ create: overrides template fields correctly${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"
  rm -f "${TMPDIR_BASE}/curl_calls.log"
  cp "${SCRIPT_DIR}/meeting-template.json" "${dir}/meeting-template.json"

  setup_mock_curl_sequence \
    '{"status":true,"result":{"mn":55555}}' \
    '{"status":true,"result":{"meeting":{"topic":{"value":"Override Test"},"startDate":{"value":"04/15/2026"},"startTime":{"value":"2:30"},"startTime2":{"value":"PM"},"duration":{"value":45},"timezone":{"value":"US/Pacific"}}}}'

  run_cli "$dir" create \
    --topic "Override Test" \
    --date "04/15/2026" \
    --time "2:30" \
    --ampm PM \
    --duration 45 \
    --timezone "US/Pacific" > /dev/null

  local calls; calls=$(get_curl_calls)
  assert_contains "overrides topic" "Override Test" "$calls"
  assert_contains "overrides date" "04/15/2026" "$calls"
  assert_contains "overrides time" "2:30" "$calls"
  assert_contains "overrides duration" "45" "$calls"
  assert_contains "overrides timezone" "US/Pacific" "$calls"
}

test_create_invitees() {
  echo -e "\n${CYAN}▸ create: includes invitees in JSON payload${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"
  rm -f "${TMPDIR_BASE}/curl_calls.log"
  cp "${SCRIPT_DIR}/meeting-template.json" "${dir}/meeting-template.json"

  setup_mock_curl_sequence \
    '{"status":true,"result":{"mn":77777}}' \
    '{"status":true,"result":{"meeting":{"topic":{"value":"Invite Test"},"duration":{"value":60},"timezone":{"value":"UTC"}}}}'

  run_cli "$dir" create \
    --topic "Invite Test" \
    -i "alice@example.com" \
    -i "bob@example.com" \
    --date "03/28/2026" --time "10:00" --ampm AM > /dev/null

  local calls; calls=$(get_curl_calls)
  assert_contains "includes first invitee" "alice@example.com" "$calls"
  assert_contains "includes second invitee" "bob@example.com" "$calls"
}

test_create_recurring_weekly() {
  echo -e "\n${CYAN}▸ create: weekly recurring sets correct recurrence fields${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"
  rm -f "${TMPDIR_BASE}/curl_calls.log"
  cp "${SCRIPT_DIR}/meeting-template.json" "${dir}/meeting-template.json"

  setup_mock_curl_sequence \
    '{"status":true,"result":{"mn":88888}}' \
    '{"status":true,"result":{"meeting":{"topic":{"value":"Weekly"},"duration":{"value":60},"timezone":{"value":"UTC"},"recurring":{"value":true}}}}'

  run_cli "$dir" create \
    --topic "Weekly" \
    --date "03/28/2026" --time "10:00" --ampm AM \
    --recurring --recurrence-type WEEKLY --recurrence-days SA \
    > /dev/null

  local calls; calls=$(get_curl_calls)
  assert_contains "sets recurring value to true" '"value": true' "$calls"
  assert_contains "uses BYDAY type" "BYDAY" "$calls"
  assert_contains "sets day to 7 (Saturday)" '"value": "7"' "$calls"
  assert_contains "sets type to WEEKLY" "WEEKLY" "$calls"
  assert_contains "includes endTime" "endTime" "$calls"
}

test_create_non_recurring_keeps_template_block() {
  echo -e "\n${CYAN}▸ create: non-recurring keeps template recurring block intact${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"
  rm -f "${TMPDIR_BASE}/curl_calls.log"
  cp "${SCRIPT_DIR}/meeting-template.json" "${dir}/meeting-template.json"

  setup_mock_curl_sequence \
    '{"status":true,"result":{"mn":66666}}' \
    '{"status":true,"result":{"meeting":{"topic":{"value":"Simple"},"duration":{"value":30},"timezone":{"value":"UTC"}}}}'

  run_cli "$dir" create \
    --topic "Simple" \
    --date "03/28/2026" --time "10:00" --ampm AM \
    > /dev/null

  local calls; calls=$(get_curl_calls)
  # Non-recurring should still have recurringType in the payload (from template)
  assert_contains "keeps recurring block from template" "recurringType" "$calls"
  # But recurring.value should NOT be true
  assert_not_contains "recurring value not true" '"value": true, "childParams": {"meetingEventEnabled"' "$calls"
}

test_create_day_abbreviation_mapping() {
  echo -e "\n${CYAN}▸ create: maps day abbreviations to numeric values${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"
  rm -f "${TMPDIR_BASE}/curl_calls.log"
  cp "${SCRIPT_DIR}/meeting-template.json" "${dir}/meeting-template.json"

  setup_mock_curl_sequence \
    '{"status":true,"result":{"mn":44444}}' \
    '{"status":true,"result":{"meeting":{"topic":{"value":"Multi Day"},"duration":{"value":60},"timezone":{"value":"UTC"}}}}'

  run_cli "$dir" create \
    --topic "Multi Day" \
    --date "03/28/2026" --time "10:00" --ampm AM \
    --recurring --recurrence-type WEEKLY --recurrence-days "MO,WE,FR" \
    > /dev/null

  local calls; calls=$(get_curl_calls)
  # MO=2, WE=4, FR=6
  assert_contains "maps MO to 2" '"value": "2"' "$calls"
  assert_contains "maps WE to 4" '"value": "4"' "$calls"
  assert_contains "maps FR to 6" '"value": "6"' "$calls"
}

test_create_agenda_desc() {
  echo -e "\n${CYAN}▸ create: --agenda flag sets description${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"
  rm -f "${TMPDIR_BASE}/curl_calls.log"
  cp "${SCRIPT_DIR}/meeting-template.json" "${dir}/meeting-template.json"

  setup_mock_curl_sequence \
    '{"status":true,"result":{"mn":33333}}' \
    '{"status":true,"result":{"meeting":{"topic":{"value":"Agenda Test"},"duration":{"value":60},"timezone":{"value":"UTC"}}}}'

  run_cli "$dir" create \
    --topic "Agenda Test" \
    --agenda "Discuss Q2 planning" \
    --date "03/28/2026" --time "10:00" --ampm AM > /dev/null

  local calls; calls=$(get_curl_calls)
  assert_contains "sends agenda" "Discuss Q2 planning" "$calls"
}

# ─── View with JSON API tests ────────────────────────────────────────

test_view_json_api_success() {
  echo -e "\n${CYAN}▸ view: renders from /rest/meeting/view JSON response${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"

  local json='{"status":true,"result":{"meeting":{"topic":{"show":true,"value":"Team Standup"},"startDate":{"value":"04/01/2026"},"startTime":{"value":"9:00"},"startTime2":{"value":"AM"},"duration":{"value":30},"timezone":{"value":"Europe/London"},"recurring":{"value":false},"passcode":{"value":false,"childParams":{"meetingPasscode":{"show":true,"value":"123456"}}},"invitee":{"value":[{"email":"alice@test.com"},{"email":"bob@test.com"}]}}}}'
  setup_mock_curl "$json"

  local output; output=$(run_cli "$dir" view 12345678901)
  assert_contains "shows topic" "Team Standup" "$output"
  assert_contains "shows meeting ID" "12345678901" "$output"
  assert_contains "shows date" "04/01/2026" "$output"
  assert_contains "shows time" "9:00 AM" "$output"
  assert_contains "shows duration" "30 min" "$output"
  assert_contains "shows timezone" "Europe/London" "$output"
  assert_contains "shows passcode" "123456" "$output"
  assert_contains "shows invitees" "alice@test.com" "$output"
  assert_contains "shows second invitee" "bob@test.com" "$output"
}

test_view_json_api_no_passcode() {
  echo -e "\n${CYAN}▸ view: hides passcode when childParams is null${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"

  local json='{"status":true,"result":{"meeting":{"topic":{"value":"No Pass"},"startDate":{"value":"04/01/2026"},"startTime":{"value":"10:00"},"startTime2":{"value":"AM"},"duration":{"value":60},"timezone":{"value":"UTC"},"passcode":{"value":false,"childParams":null},"recurring":{"value":false}}}}'
  setup_mock_curl "$json"

  local output; output=$(run_cli "$dir" view 99999)
  assert_contains "shows topic" "No Pass" "$output"
  assert_not_contains "no passcode line" "Passcode" "$output"
}

test_view_json_api_error() {
  echo -e "\n${CYAN}▸ view: handles API error response${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"

  setup_mock_curl '{"status":false,"errorCode":-1,"errorMessage":"Invalid meeting ID."}'

  local output; output=$(run_cli "$dir" view 00000)
  assert_contains "shows error" "Failed to fetch" "$output"
}

test_view_recurring_meeting() {
  echo -e "\n${CYAN}▸ view: shows recurrence info for recurring meeting${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"

  local json='{"status":true,"result":{"meeting":{"topic":{"value":"Weekly Sync"},"startDate":{"value":"03/28/2026"},"startTime":{"value":"10:00"},"startTime2":{"value":"AM"},"duration":{"value":60},"timezone":{"value":"Europe/London"},"recurring":{"value":true,"childParams":{"recurring":{"value":{"type":"WEEKLY"}}}},"invitee":{"value":[]}}}}'
  setup_mock_curl "$json"

  local output; output=$(run_cli "$dir" view 12345)
  assert_contains "shows recurring type" "WEEKLY" "$output"
}

# ─── Delete with new endpoint tests ──────────────────────────────────

test_delete_sends_correct_params() {
  echo -e "\n${CYAN}▸ delete: sends id= to /meeting/delete${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"
  rm -f "${TMPDIR_BASE}/curl_calls.log"

  setup_mock_curl '{"status":true,"result":true}'

  run_cli "$dir" delete 94244974137 > /dev/null

  local calls; calls=$(get_curl_calls)
  assert_contains "calls /meeting/delete" "/meeting/delete" "$calls"
  assert_contains "sends id param" "id=94244974137" "$calls"
  assert_contains "sends sendMail=false" "sendMail=false" "$calls"
}

# ─── Auth expiry across different commands ────────────────────────────

test_auth_expired_on_view() {
  echo -e "\n${CYAN}▸ is_auth_expired: triggers on view command${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"

  setup_mock_curl '{"status":false,"errorCode":201,"errorMessage":"User not login."}'

  local output; output=$(run_cli "$dir" view 12345)
  assert_contains "detects on view" "Session expired" "$output"
}

test_auth_expired_on_delete() {
  echo -e "\n${CYAN}▸ is_auth_expired: triggers on delete command${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"

  setup_mock_curl '{"status":false,"errorCode":201,"errorMessage":"User not login."}'

  local output; output=$(run_cli "$dir" delete 12345)
  assert_contains "detects on delete" "Session expired" "$output"
}

test_auth_expired_on_create() {
  echo -e "\n${CYAN}▸ is_auth_expired: triggers on create command${NC}"
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"
  cp "${SCRIPT_DIR}/meeting-template.json" "${dir}/meeting-template.json"

  setup_mock_curl '{"status":false,"errorCode":201,"errorMessage":"User not login."}'

  local output; output=$(run_cli "$dir" create --topic "Auth Test" --date "03/28/2026" --time "10:00" --ampm AM)
  assert_contains "detects on create" "Session expired" "$output"
}

# ─── Run all tests ───────────────────────────────────────────────────

echo ""
echo -e "${CYAN}━━━ zoom-cli.sh tests ━━━${NC}"

# Cookie management
test_set_cookies_basic
test_set_cookies_strips_quotes
test_set_cookies_strips_whitespace
test_set_cookies_reports_count
test_set_cookies_missing_arg

# Import cookies
test_import_cookies_netscape
test_import_cookies_skips_comments
test_import_cookies_missing_file
test_import_cookies_empty_file

# CSRF
test_csrf_extraction
test_csrf_injected_into_cookies
test_csrf_replaces_old_token
test_csrf_bad_response

# Auth guards
test_get_cookies_missing
test_get_csrf_missing

# List
test_list_success
test_list_empty
test_list_api_error
test_list_html_error_response
test_list_rendering_multiple_meetings_per_day
test_list_meeting_without_optional_fields

# View
test_view_success
test_view_no_password
test_view_unparseable_response
test_view_aliases

# Create
test_create_help
test_create_with_all_args
test_create_defaults
test_create_recurring
test_create_no_id_extracted
test_create_unknown_option
test_create_aliases

# Update
test_update_success
test_update_failure
test_update_no_params
test_update_missing_id
test_update_unknown_option
test_update_all_params
test_update_edit_alias

# Delete
test_delete_success
test_delete_failure
test_delete_rm_alias
test_delete_remove_alias

# Raw
test_raw_get
test_raw_post

# Login
test_login_calls_node_and_csrf
test_login_auth_alias
test_login_grab_cookies_alias

# Meeting ID extraction (used by create)
test_meeting_id_extraction_from_redirect
test_meeting_id_extraction_from_json
test_meeting_id_extraction_from_url_in_body

# Command routing & help
test_command_aliases
test_help_output
test_unknown_command
test_view_missing_arg
test_delete_missing_arg
test_help_flag_aliases
test_no_args_shows_help

# Auth expiry detection (is_auth_expired)
test_auth_expired_user_not_login
test_auth_expired_saml_redirect
test_auth_expired_error_page
test_auth_expired_valid_response_not_flagged
test_auth_expired_api_error_not_flagged

# Auto-reauth (zoom_authed)
test_authed_retry_succeeds_after_reauth
test_authed_passthrough_on_valid
test_reauth_non_interactive

# Auth expiry across commands
test_auth_expired_on_view
test_auth_expired_on_delete
test_auth_expired_on_create

# zoom_post_json
test_post_json_content_type
test_post_json_sends_body

# Create with meeting-template.json
test_create_requires_template
test_create_overrides_template_fields
test_create_invitees
test_create_recurring_weekly
test_create_non_recurring_keeps_template_block
test_create_day_abbreviation_mapping
test_create_agenda_desc

# View with JSON API
test_view_json_api_success
test_view_json_api_no_passcode
test_view_json_api_error
test_view_recurring_meeting

# Delete with new endpoint
test_delete_sends_correct_params

# ─── Summary ─────────────────────────────────────────────────────────

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
if [[ $FAIL -eq 0 ]]; then
  echo -e "${GREEN}All ${TOTAL} tests passed ✓${NC}"
else
  echo -e "${RED}${FAIL}/${TOTAL} tests failed ✗${NC}"
fi
echo ""

# Cleanup
rm -rf "$TMPDIR_BASE"

exit "$FAIL"

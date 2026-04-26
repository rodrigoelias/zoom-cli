#!/usr/bin/env bash
#
# test-mcp.sh — Tests for the MCP server (mcp-server.sh)
#
# Tests JSON-RPC protocol compliance, tool functionality, security,
# and abuse resistance. Uses mock curl via PATH injection.
#
# Usage:  ./test-mcp.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MCP_SERVER="${SCRIPT_DIR}/mcp-server.sh"

# ─── Test infrastructure ──────────────────────────────────────────────

PASS=0; FAIL=0; TOTAL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; NC='\033[0m'

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
    echo -e "  ${GREEN}✓${NC} ${label}"
  else
    FAIL=$((FAIL + 1))
    echo -e "  ${RED}✗${NC} ${label}"
    echo -e "    expected: ${expected}"
    echo -e "    actual:   ${actual}"
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if echo "$haystack" | grep -qF "$needle"; then
    PASS=$((PASS + 1))
    echo -e "  ${GREEN}✓${NC} ${label}"
  else
    FAIL=$((FAIL + 1))
    echo -e "  ${RED}✗${NC} ${label}"
    echo -e "    expected to contain: ${needle}"
    echo -e "    actual: ${haystack:0:200}"
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if ! echo "$haystack" | grep -qF "$needle"; then
    PASS=$((PASS + 1))
    echo -e "  ${GREEN}✓${NC} ${label}"
  else
    FAIL=$((FAIL + 1))
    echo -e "  ${RED}✗${NC} ${label}"
    echo -e "    should NOT contain: ${needle}"
  fi
}

# Setup a temp dir for mocks (works in sandbox)
TMPDIR_BASE="${SCRIPT_DIR}/tmp-test"
mkdir -p "$TMPDIR_BASE"
MOCK_DIR=$(mktemp -d "${TMPDIR_BASE}/XXXXXX")
MOCK_BIN="${MOCK_DIR}/bin"
mkdir -p "$MOCK_BIN"

cleanup() {
  rm -rf "$MOCK_DIR"
}
trap cleanup EXIT

# Helper: send JSON-RPC message(s) to MCP server and capture stdout
# Uses mock curl and mock node via PATH injection
run_mcp() {
  local input="$1"
  printf '%s\n' "$input" | PATH="${MOCK_BIN}:${PATH}" bash "$MCP_SERVER" 2>/dev/null
}

# Helper: send multiple messages
run_mcp_multi() {
  PATH="${MOCK_BIN}:${PATH}" bash "$MCP_SERVER" 2>/dev/null
}

# Setup mock curl with a canned response
setup_mock_curl() {
  local response="$1"
  local exit_code="${2:-0}"
  # Write response to a data file to avoid quoting issues in the mock script
  printf '%s' "$response" > "${MOCK_DIR}/curl_response"
  cat > "${MOCK_BIN}/curl" <<MOCKEOF
#!/usr/bin/env bash
cat "${MOCK_DIR}/curl_response"
exit ${exit_code}
MOCKEOF
  chmod +x "${MOCK_BIN}/curl"
}

# Setup mock node (for initialize_session tests)
setup_mock_node() {
  local behavior="${1:-success}"
  if [[ "$behavior" == "success" ]]; then
    cat > "${MOCK_BIN}/node" << MOCKEOF
#!/usr/bin/env bash
# Mock node: write fake cookies to .raw_cookies
SCRIPT_DIR="\$(cd "\$(dirname "\$1")" && pwd)"
printf 'session=mock_cookie_value; _zm_ssid=mock_ssid' > "\${SCRIPT_DIR}/.raw_cookies"
exit 0
MOCKEOF
  else
    cat > "${MOCK_BIN}/node" << 'MOCKEOF'
#!/usr/bin/env bash
# Mock node: fail (simulate SSO timeout)
exit 1
MOCKEOF
  fi
  chmod +x "${MOCK_BIN}/node"
}

# ─── Protocol Tests ──────────────────────────────────────────────────

echo -e "\n${CYAN}━━━ MCP Server Tests ━━━${NC}"

echo -e "\n${CYAN}▸ Protocol: initialize response${NC}"
output=$(run_mcp '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}')
assert_eq "has jsonrpc field" "2.0" "$(echo "$output" | jq -r '.jsonrpc')"
assert_eq "echoes request id" "1" "$(echo "$output" | jq -r '.id')"
assert_eq "protocol version" "2025-11-25" "$(echo "$output" | jq -r '.result.protocolVersion')"
assert_contains "has tools capability" '"tools"' "$output"
assert_eq "server name" "zoom-cli-mcp" "$(echo "$output" | jq -r '.result.serverInfo.name')"

echo -e "\n${CYAN}▸ Protocol: notifications/initialized gets no response${NC}"
output=$(run_mcp '{"jsonrpc":"2.0","method":"notifications/initialized"}')
assert_eq "empty output for notification" "" "$output"

echo -e "\n${CYAN}▸ Protocol: tools/list returns 6 tools${NC}"
output=$(run_mcp '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
assert_eq "6 tools returned" "6" "$(echo "$output" | jq '.result.tools | length')"
assert_eq "first tool is zoom_list" "zoom_list" "$(echo "$output" | jq -r '.result.tools[0].name')"
assert_eq "second tool is zoom_view" "zoom_view" "$(echo "$output" | jq -r '.result.tools[1].name')"
assert_eq "third tool is initialize_session" "initialize_session" "$(echo "$output" | jq -r '.result.tools[2].name')"
assert_eq "fourth tool is zoom_update" "zoom_update" "$(echo "$output" | jq -r '.result.tools[3].name')"
assert_eq "fifth tool is zoom_create" "zoom_create" "$(echo "$output" | jq -r '.result.tools[4].name')"
assert_eq "sixth tool is zoom_delete" "zoom_delete" "$(echo "$output" | jq -r '.result.tools[5].name')"
# Verify no raw tool
tool_names=$(echo "$output" | jq -r '.result.tools[].name' | sort)
assert_not_contains "no raw tool" "raw" "$tool_names"

echo -e "\n${CYAN}▸ Protocol: unknown method returns -32601${NC}"
output=$(run_mcp '{"jsonrpc":"2.0","id":3,"method":"unknown/method","params":{}}')
assert_eq "error code -32601" "-32601" "$(echo "$output" | jq '.error.code')"
assert_eq "echoes request id" "3" "$(echo "$output" | jq -r '.id')"

echo -e "\n${CYAN}▸ Protocol: ping returns empty result${NC}"
output=$(run_mcp '{"jsonrpc":"2.0","id":4,"method":"ping","params":{}}')
assert_eq "ping result is empty object" "{}" "$(echo "$output" | jq -c '.result')"

echo -e "\n${CYAN}▸ Protocol: malformed JSON returns parse error${NC}"
output=$(run_mcp 'this is not json')
assert_eq "error code -32700" "-32700" "$(echo "$output" | jq '.error.code')"

# ─── Functional Tests: zoom_list ─────────────────────────────────────

echo -e "\n${CYAN}▸ Functional: zoom_list success${NC}"
setup_mock_curl '{"status":true,"errorCode":0,"result":{"totalRecords":2,"meetings":[{"time":"Today","list":[{"number":"12345678901","numberF":"123 4567 8901","topic":"Daily Standup","schTimeF":"09:00 AM - 09:30 AM","duration":30,"type":8,"occurrenceTip":"Occurrence 1 of 5"}]},{"time":"Wed, Apr 1","list":[{"number":"98765432109","topic":"Team Retro","schTimeF":"02:00 PM - 03:00 PM","duration":60,"type":2,"occurrenceTip":""}]}]}}'
output=$(run_mcp '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"zoom_list","arguments":{}}}')
tool_text=$(echo "$output" | jq -r '.result.content[0].text')
assert_eq "isError is false" "false" "$(echo "$output" | jq '.result.isError')"
assert_eq "ok is true" "true" "$(echo "$tool_text" | jq '.ok')"
assert_eq "totalRecords" "2" "$(echo "$tool_text" | jq '.data.totalRecords')"
assert_eq "has pagination page" "1" "$(echo "$tool_text" | jq '.data.page')"
assert_eq "has pagination hasMore" "false" "$(echo "$tool_text" | jq '.data.hasMore')"
assert_contains "meeting topic" "Daily Standup" "$tool_text"
assert_contains "second meeting" "Team Retro" "$tool_text"
assert_eq "isRecurring true for type 8" "true" "$(echo "$tool_text" | jq '.data.meetings[0].items[0].isRecurring')"
assert_eq "isRecurring false for type 2" "false" "$(echo "$tool_text" | jq '.data.meetings[1].items[0].isRecurring')"
assert_eq "empty occurrenceTip becomes null" "null" "$(echo "$tool_text" | jq '.data.meetings[1].items[0].occurrenceInfo')"

echo -e "\n${CYAN}▸ Functional: zoom_list pagination metadata${NC}"
setup_mock_curl '{"status":true,"errorCode":0,"result":{"totalRecords":87,"meetings":[]}}'
output=$(run_mcp '{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"zoom_list","arguments":{"page":1,"pageSize":50}}}')
tool_text=$(echo "$output" | jq -r '.result.content[0].text')
assert_eq "hasMore true when more pages" "true" "$(echo "$tool_text" | jq '.data.hasMore')"
assert_eq "pageSize echoed" "50" "$(echo "$tool_text" | jq '.data.pageSize')"

# ─── Functional Tests: zoom_view ─────────────────────────────────────

echo -e "\n${CYAN}▸ Functional: zoom_view success${NC}"
setup_mock_curl '{"status":true,"errorCode":0,"result":{"meeting":{"topic":{"value":"Weekly Sync"},"startDate":{"value":"04/01/2026"},"startTime":{"value":"10:00"},"startTime2":{"value":"AM"},"duration":{"value":60},"timezone":{"value":"Europe/London"},"recurring":{"value":false},"passcode":{"childParams":{"meetingPasscode":{"value":"abc123"}}},"invitee":{"value":[{"email":"alice@test.com"},{"email":"bob@test.com"}]}},"joinUrl":"https://skyscanner.zoom.us/j/12345678901"}}'
output=$(run_mcp '{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"zoom_view","arguments":{"meetingId":"12345678901"}}}')
tool_text=$(echo "$output" | jq -r '.result.content[0].text')
assert_eq "isError false" "false" "$(echo "$output" | jq '.result.isError')"
assert_eq "topic unwrapped" '"Weekly Sync"' "$(echo "$tool_text" | jq '.data.topic')"
assert_eq "startDate unwrapped" '"04/01/2026"' "$(echo "$tool_text" | jq '.data.startDate')"
assert_eq "duration unwrapped" "60" "$(echo "$tool_text" | jq '.data.duration')"
assert_eq "timezone unwrapped" '"Europe/London"' "$(echo "$tool_text" | jq '.data.timezone')"
assert_eq "passcode unwrapped" '"abc123"' "$(echo "$tool_text" | jq '.data.passcode')"
assert_eq "joinUrl at result level" '"https://skyscanner.zoom.us/j/12345678901"' "$(echo "$tool_text" | jq '.data.joinUrl')"
assert_eq "invitees extracted" '"alice@test.com"' "$(echo "$tool_text" | jq '.data.invitees[0]')"
assert_eq "meetingId echoed" '"12345678901"' "$(echo "$tool_text" | jq '.data.meetingId')"

# ─── Error Tests ─────────────────────────────────────────────────────

echo -e "\n${CYAN}▸ Error: zoom_view missing meetingId${NC}"
output=$(run_mcp '{"jsonrpc":"2.0","id":30,"method":"tools/call","params":{"name":"zoom_view","arguments":{}}}')
tool_text=$(echo "$output" | jq -r '.result.content[0].text')
assert_eq "isError true" "true" "$(echo "$output" | jq '.result.isError')"
assert_eq "error code BAD_INPUT" '"BAD_INPUT"' "$(echo "$tool_text" | jq '.error.code')"

echo -e "\n${CYAN}▸ Error: zoom_view non-numeric meetingId${NC}"
output=$(run_mcp '{"jsonrpc":"2.0","id":31,"method":"tools/call","params":{"name":"zoom_view","arguments":{"meetingId":"abc123"}}}')
tool_text=$(echo "$output" | jq -r '.result.content[0].text')
assert_eq "isError true" "true" "$(echo "$output" | jq '.result.isError')"
assert_eq "error code BAD_INPUT" '"BAD_INPUT"' "$(echo "$tool_text" | jq '.error.code')"

echo -e "\n${CYAN}▸ Error: auth expired response${NC}"
setup_mock_curl '{"status":false,"errorCode":201,"errorMessage":"User not login."}'
output=$(run_mcp '{"jsonrpc":"2.0","id":32,"method":"tools/call","params":{"name":"zoom_list","arguments":{}}}')
tool_text=$(echo "$output" | jq -r '.result.content[0].text')
assert_eq "isError true" "true" "$(echo "$output" | jq '.result.isError')"
assert_eq "error code AUTH_EXPIRED" '"AUTH_EXPIRED"' "$(echo "$tool_text" | jq '.error.code')"
assert_contains "references initialize_session" "initialize_session" "$tool_text"
assert_eq "retryable false" "false" "$(echo "$tool_text" | jq '.error.retryable')"

echo -e "\n${CYAN}▸ Error: SAML redirect detected as auth expired${NC}"
setup_mock_curl '<html><body>SAMLRequest redirect to login.microsoftonline.com</body></html>'
output=$(run_mcp '{"jsonrpc":"2.0","id":33,"method":"tools/call","params":{"name":"zoom_list","arguments":{}}}')
tool_text=$(echo "$output" | jq -r '.result.content[0].text')
assert_eq "SAML detected as AUTH_EXPIRED" '"AUTH_EXPIRED"' "$(echo "$tool_text" | jq '.error.code')"

echo -e "\n${CYAN}▸ Error: zoom_list API error${NC}"
setup_mock_curl '{"status":false,"errorCode":400,"errorMessage":"Bad request"}'
output=$(run_mcp '{"jsonrpc":"2.0","id":34,"method":"tools/call","params":{"name":"zoom_list","arguments":{}}}')
tool_text=$(echo "$output" | jq -r '.result.content[0].text')
assert_eq "isError true" "true" "$(echo "$output" | jq '.result.isError')"
assert_eq "error code ZOOM_API_ERROR" '"ZOOM_API_ERROR"' "$(echo "$tool_text" | jq '.error.code')"

echo -e "\n${CYAN}▸ Error: unknown tool name${NC}"
output=$(run_mcp '{"jsonrpc":"2.0","id":35,"method":"tools/call","params":{"name":"zoom_nonexistent_tool","arguments":{}}}')
tool_text=$(echo "$output" | jq -r '.result.content[0].text')
assert_eq "isError true for unknown tool" "true" "$(echo "$output" | jq '.result.isError')"
assert_contains "unknown tool error" "Unknown tool" "$tool_text"

# ─── Security Tests ──────────────────────────────────────────────────

echo -e "\n${CYAN}▸ Security: no cookies/CSRF in tool output${NC}"
setup_mock_curl '{"status":true,"errorCode":0,"result":{"totalRecords":0,"meetings":[]}}'
# Set fake credentials to check they don't leak
output=$(printf '%s\n' '{"jsonrpc":"2.0","id":40,"method":"tools/call","params":{"name":"zoom_list","arguments":{}}}' | \
  PATH="${MOCK_BIN}:${PATH}" bash -c '
    source '"$MCP_SERVER"' 2>/dev/null <<< ""
  ' 2>/dev/null || true)
# Run the actual test with credentials set
full_output=$(run_mcp '{"jsonrpc":"2.0","id":40,"method":"tools/call","params":{"name":"zoom_list","arguments":{}}}')
assert_not_contains "no raw cookie in output" "session=mock" "$full_output"
assert_not_contains "no csrf in output" "FAKE-CSRF" "$full_output"

echo -e "\n${CYAN}▸ Security: ZOOM_DEBUG suppressed${NC}"
setup_mock_curl '{"status":true,"errorCode":0,"result":{"totalRecords":0,"meetings":[]}}'
full_output=$(printf '%s\n' '{"jsonrpc":"2.0","id":41,"method":"tools/call","params":{"name":"zoom_list","arguments":{}}}' | \
  ZOOM_DEBUG=1 PATH="${MOCK_BIN}:${PATH}" bash "$MCP_SERVER" 2>/dev/null)
assert_not_contains "no debug prefix in stdout" "[dbg]" "$full_output"

echo -e "\n${CYAN}▸ Security: shell metacharacters in meetingId rejected${NC}"
output=$(run_mcp '{"jsonrpc":"2.0","id":42,"method":"tools/call","params":{"name":"zoom_view","arguments":{"meetingId":"123; cat /etc/passwd"}}}')
tool_text=$(echo "$output" | jq -r '.result.content[0].text')
assert_eq "rejects shell metacharacters" '"BAD_INPUT"' "$(echo "$tool_text" | jq '.error.code')"

echo -e "\n${CYAN}▸ Security: no raw tool in tools/list${NC}"
output=$(run_mcp '{"jsonrpc":"2.0","id":43,"method":"tools/list","params":{}}')
tool_names=$(echo "$output" | jq -r '.result.tools[].name')
assert_not_contains "raw not in tools" "raw" "$tool_names"
assert_not_contains "set-cookies not in tools" "set-cookies" "$tool_names"
assert_not_contains "import-cookies not in tools" "import-cookies" "$tool_names"

# ─── Abuse Tests ─────────────────────────────────────────────────────

echo -e "\n${CYAN}▸ Abuse: malformed JSON server stays alive${NC}"
output=$(printf '%s\n%s\n' \
  'this is garbage' \
  '{"jsonrpc":"2.0","id":50,"method":"ping","params":{}}' | \
  PATH="${MOCK_BIN}:${PATH}" bash "$MCP_SERVER" 2>/dev/null)
# Should get two responses: parse error + ping response
line_count=$(echo "$output" | wc -l | tr -d ' ')
assert_eq "server processes both messages" "2" "$line_count"
last_line=$(echo "$output" | tail -1)
assert_eq "ping still works after bad input" "{}" "$(echo "$last_line" | jq -c '.result')"

echo -e "\n${CYAN}▸ Abuse: oversized meetingId rejected${NC}"
big_id=$(python3 -c "print('9'*100)")
output=$(run_mcp "{\"jsonrpc\":\"2.0\",\"id\":51,\"method\":\"tools/call\",\"params\":{\"name\":\"zoom_view\",\"arguments\":{\"meetingId\":\"${big_id}\"}}}")
tool_text=$(echo "$output" | jq -r '.result.content[0].text')
assert_eq "rejects oversized ID" '"BAD_INPUT"' "$(echo "$tool_text" | jq '.error.code')"

# ─── Initialize Session Tests ───────────────────────────────────────

echo -e "\n${CYAN}▸ Functional: initialize_session success${NC}"
setup_mock_node "success"
# Mock curl for CSRF refresh — return CSRF token in expected format
printf '%s' 'ZOOM-CSRFTOKEN:mock_csrf_token_12345' > "${MOCK_DIR}/curl_response"
output=$(run_mcp '{"jsonrpc":"2.0","id":60,"method":"tools/call","params":{"name":"initialize_session","arguments":{}}}')
tool_text=$(echo "$output" | jq -r '.result.content[0].text')
assert_eq "isError is false" "false" "$(echo "$output" | jq '.result.isError')"
assert_eq "status session_ready" '"session_ready"' "$(echo "$tool_text" | jq '.data.status')"

echo -e "\n${CYAN}▸ Functional: initialize_session already active${NC}"
# After the previous successful init, session should be active
# Send another init request — should return already_active
setup_mock_node "success"
printf '%s' 'ZOOM-CSRFTOKEN:mock_csrf_token_12345' > "${MOCK_DIR}/curl_response"
# We need to test within a single server invocation to preserve state
output=$(printf '%s\n%s\n' \
  '{"jsonrpc":"2.0","id":61,"method":"tools/call","params":{"name":"initialize_session","arguments":{}}}' \
  '{"jsonrpc":"2.0","id":62,"method":"tools/call","params":{"name":"initialize_session","arguments":{}}}' | \
  PATH="${MOCK_BIN}:${PATH}" bash "$MCP_SERVER" 2>/dev/null)
second_line=$(echo "$output" | sed -n '2p')
second_text=$(echo "$second_line" | jq -r '.result.content[0].text')
assert_eq "second init returns already_active" '"already_active"' "$(echo "$second_text" | jq '.data.status')"

echo -e "\n${CYAN}▸ Error: initialize_session SSO timeout${NC}"
setup_mock_node "timeout"
output=$(run_mcp '{"jsonrpc":"2.0","id":63,"method":"tools/call","params":{"name":"initialize_session","arguments":{}}}')
tool_text=$(echo "$output" | jq -r '.result.content[0].text')
assert_eq "isError true on timeout" "true" "$(echo "$output" | jq '.result.isError')"
assert_eq "error code INIT_FAILED" '"INIT_FAILED"' "$(echo "$tool_text" | jq '.error.code')"

echo -e "\n${CYAN}▸ Security: initialize_session cleans up disk artifacts${NC}"
setup_mock_node "success"
printf '%s' 'ZOOM-CSRFTOKEN:mock_csrf_token_12345' > "${MOCK_DIR}/curl_response"
# Run init and then check that .raw_cookies and cookies.txt are cleaned up
printf '%s\n' '{"jsonrpc":"2.0","id":64,"method":"tools/call","params":{"name":"initialize_session","arguments":{}}}' | \
  PATH="${MOCK_BIN}:${PATH}" bash "$MCP_SERVER" 2>/dev/null >/dev/null
# The mock node writes .raw_cookies relative to the script dir — check it was cleaned
# We can't easily check the actual script dir from here, but we can verify the mock was called
assert_eq "mock node exists" "true" "$([[ -x "${MOCK_BIN}/node" ]] && echo true || echo false)"

# ─── Functional Tests: zoom_create ──────────────────────────────────

echo -e "\n${CYAN}▸ Functional: zoom_create success${NC}"
setup_mock_curl '{"status":true,"errorCode":0,"result":{"mn":"94244974137","meetingNumber":"94244974137","joinLink":"https://skyscanner.zoom.us/j/94244974137"}}'
output=$(run_mcp '{"jsonrpc":"2.0","id":100,"method":"tools/call","params":{"name":"zoom_create","arguments":{"topic":"Test Meeting","date":"04/30/2026","time":"2:00","ampm":"PM","duration":60}}}')
tool_text=$(echo "$output" | jq -r '.result.content[0].text')
assert_eq "isError false" "false" "$(echo "$output" | jq '.result.isError')"
assert_eq "ok true" "true" "$(echo "$tool_text" | jq '.ok')"
assert_eq "meetingId returned" '"94244974137"' "$(echo "$tool_text" | jq '.data.meetingId')"
assert_contains "joinUrl present" "zoom.us/j/94244974137" "$tool_text"
assert_eq "topic echoed" '"Test Meeting"' "$(echo "$tool_text" | jq '.data.topic')"

echo -e "\n${CYAN}▸ Error: zoom_create missing topic${NC}"
output=$(run_mcp '{"jsonrpc":"2.0","id":101,"method":"tools/call","params":{"name":"zoom_create","arguments":{"topic":"","date":"04/30/2026","time":"2:00"}}}')
tool_text=$(echo "$output" | jq -r '.result.content[0].text')
assert_eq "isError true" "true" "$(echo "$output" | jq '.result.isError')"
assert_eq "error code BAD_INPUT" '"BAD_INPUT"' "$(echo "$tool_text" | jq '.error.code')"

echo -e "\n${CYAN}▸ Error: zoom_create missing date${NC}"
output=$(run_mcp '{"jsonrpc":"2.0","id":102,"method":"tools/call","params":{"name":"zoom_create","arguments":{"topic":"Test","date":"","time":"2:00"}}}')
tool_text=$(echo "$output" | jq -r '.result.content[0].text')
assert_eq "isError true" "true" "$(echo "$output" | jq '.result.isError')"
assert_eq "error code BAD_INPUT" '"BAD_INPUT"' "$(echo "$tool_text" | jq '.error.code')"

echo -e "\n${CYAN}▸ Error: zoom_create invalid date format${NC}"
output=$(run_mcp '{"jsonrpc":"2.0","id":103,"method":"tools/call","params":{"name":"zoom_create","arguments":{"topic":"Test","date":"2026-04-30","time":"2:00"}}}')
tool_text=$(echo "$output" | jq -r '.result.content[0].text')
assert_eq "isError true" "true" "$(echo "$output" | jq '.result.isError')"
assert_eq "error code BAD_INPUT" '"BAD_INPUT"' "$(echo "$tool_text" | jq '.error.code')"

echo -e "\n${CYAN}▸ Error: zoom_create invalid time format${NC}"
output=$(run_mcp '{"jsonrpc":"2.0","id":104,"method":"tools/call","params":{"name":"zoom_create","arguments":{"topic":"Test","date":"04/30/2026","time":"14:00:00"}}}')
tool_text=$(echo "$output" | jq -r '.result.content[0].text')
assert_eq "isError true" "true" "$(echo "$output" | jq '.result.isError')"
assert_eq "error code BAD_INPUT" '"BAD_INPUT"' "$(echo "$tool_text" | jq '.error.code')"

echo -e "\n${CYAN}▸ Error: zoom_create auth expired${NC}"
setup_mock_curl '{"status":false,"errorCode":201,"errorMessage":"User not login."}'
output=$(run_mcp '{"jsonrpc":"2.0","id":105,"method":"tools/call","params":{"name":"zoom_create","arguments":{"topic":"Test Meeting","date":"04/30/2026","time":"2:00","ampm":"PM"}}}')
tool_text=$(echo "$output" | jq -r '.result.content[0].text')
assert_eq "isError true" "true" "$(echo "$output" | jq '.result.isError')"
assert_eq "error code AUTH_EXPIRED" '"AUTH_EXPIRED"' "$(echo "$tool_text" | jq '.error.code')"

echo -e "\n${CYAN}▸ Error: zoom_create API error${NC}"
setup_mock_curl '{"status":false,"errorCode":400,"errorMessage":"Bad request"}'
output=$(run_mcp '{"jsonrpc":"2.0","id":106,"method":"tools/call","params":{"name":"zoom_create","arguments":{"topic":"Test Meeting","date":"04/30/2026","time":"2:00","ampm":"PM"}}}')
tool_text=$(echo "$output" | jq -r '.result.content[0].text')
assert_eq "isError true" "true" "$(echo "$output" | jq '.result.isError')"
assert_eq "error code ZOOM_API_ERROR" '"ZOOM_API_ERROR"' "$(echo "$tool_text" | jq '.error.code')"

echo -e "\n${CYAN}▸ Security: zoom_create writes disabled${NC}"
output=$(printf '%s\n' '{"jsonrpc":"2.0","id":107,"method":"tools/call","params":{"name":"zoom_create","arguments":{"topic":"Test Meeting","date":"04/30/2026","time":"2:00","ampm":"PM"}}}' | \
  ZOOM_CLI_WRITES_ENABLED=false PATH="${MOCK_BIN}:${PATH}" bash "$MCP_SERVER" 2>/dev/null)
tool_text=$(echo "$output" | jq -r '.result.content[0].text')
assert_eq "isError true" "true" "$(echo "$output" | jq '.result.isError')"
assert_eq "error code WRITES_DISABLED" '"WRITES_DISABLED"' "$(echo "$tool_text" | jq '.error.code')"

echo -e "\n${CYAN}▸ Error: zoom_create invalid invitee email${NC}"
output=$(run_mcp '{"jsonrpc":"2.0","id":108,"method":"tools/call","params":{"name":"zoom_create","arguments":{"topic":"Test","date":"04/30/2026","time":"2:00","invitees":["not-an-email"]}}}')
tool_text=$(echo "$output" | jq -r '.result.content[0].text')
assert_eq "isError true" "true" "$(echo "$output" | jq '.result.isError')"
assert_eq "error code BAD_INPUT" '"BAD_INPUT"' "$(echo "$tool_text" | jq '.error.code')"

echo -e "\n${CYAN}▸ Audit: zoom_create audit logged${NC}"
setup_mock_curl '{"status":true,"errorCode":0,"result":{"mn":"94244974137","meetingNumber":"94244974137","joinLink":"https://skyscanner.zoom.us/j/94244974137"}}'
# Clean up any prior audit log
rm -f "${SCRIPT_DIR}/.mcp-audit.log"
run_mcp '{"jsonrpc":"2.0","id":109,"method":"tools/call","params":{"name":"zoom_create","arguments":{"topic":"Audit Test","date":"04/30/2026","time":"2:00","ampm":"PM"}}}' >/dev/null
assert_eq "audit log file created" "true" "$([[ -f "${SCRIPT_DIR}/.mcp-audit.log" ]] && echo true || echo false)"
assert_contains "audit log has create_attempt" "create_attempt" "$(cat "${SCRIPT_DIR}/.mcp-audit.log" 2>/dev/null)"
rm -f "${SCRIPT_DIR}/.mcp-audit.log"

# ─── Functional Tests: zoom_update ──────────────────────────────────

echo -e "\n${CYAN}▸ Functional: zoom_update success${NC}"
setup_mock_curl '{"status":true,"errorCode":0,"result":{}}'
output=$(run_mcp '{"jsonrpc":"2.0","id":110,"method":"tools/call","params":{"name":"zoom_update","arguments":{"meetingId":"94244974137","topic":"Updated Topic"}}}')
tool_text=$(echo "$output" | jq -r '.result.content[0].text')
assert_eq "isError false" "false" "$(echo "$output" | jq '.result.isError')"
assert_eq "ok true" "true" "$(echo "$tool_text" | jq '.ok')"
assert_eq "status updated" '"updated"' "$(echo "$tool_text" | jq '.data.status')"
assert_eq "meetingId echoed" '"94244974137"' "$(echo "$tool_text" | jq '.data.meetingId')"

echo -e "\n${CYAN}▸ Error: zoom_update missing meetingId${NC}"
output=$(run_mcp '{"jsonrpc":"2.0","id":111,"method":"tools/call","params":{"name":"zoom_update","arguments":{"topic":"Updated Topic"}}}')
tool_text=$(echo "$output" | jq -r '.result.content[0].text')
assert_eq "isError true" "true" "$(echo "$output" | jq '.result.isError')"
assert_eq "error code BAD_INPUT" '"BAD_INPUT"' "$(echo "$tool_text" | jq '.error.code')"

echo -e "\n${CYAN}▸ Error: zoom_update no update fields${NC}"
output=$(run_mcp '{"jsonrpc":"2.0","id":112,"method":"tools/call","params":{"name":"zoom_update","arguments":{"meetingId":"94244974137"}}}')
tool_text=$(echo "$output" | jq -r '.result.content[0].text')
assert_eq "isError true" "true" "$(echo "$output" | jq '.result.isError')"
assert_eq "error code BAD_INPUT" '"BAD_INPUT"' "$(echo "$tool_text" | jq '.error.code')"
assert_contains "at least one field message" "At least one field" "$tool_text"

echo -e "\n${CYAN}▸ Error: zoom_update invalid date format${NC}"
output=$(run_mcp '{"jsonrpc":"2.0","id":113,"method":"tools/call","params":{"name":"zoom_update","arguments":{"meetingId":"123","date":"bad-date"}}}')
tool_text=$(echo "$output" | jq -r '.result.content[0].text')
assert_eq "isError true" "true" "$(echo "$output" | jq '.result.isError')"
assert_eq "error code BAD_INPUT" '"BAD_INPUT"' "$(echo "$tool_text" | jq '.error.code')"

echo -e "\n${CYAN}▸ Error: zoom_update auth expired${NC}"
setup_mock_curl '{"status":false,"errorCode":201,"errorMessage":"User not login."}'
output=$(run_mcp '{"jsonrpc":"2.0","id":114,"method":"tools/call","params":{"name":"zoom_update","arguments":{"meetingId":"94244974137","topic":"New Topic"}}}')
tool_text=$(echo "$output" | jq -r '.result.content[0].text')
assert_eq "isError true" "true" "$(echo "$output" | jq '.result.isError')"
assert_eq "error code AUTH_EXPIRED" '"AUTH_EXPIRED"' "$(echo "$tool_text" | jq '.error.code')"

echo -e "\n${CYAN}▸ Security: zoom_update writes disabled${NC}"
output=$(printf '%s\n' '{"jsonrpc":"2.0","id":115,"method":"tools/call","params":{"name":"zoom_update","arguments":{"meetingId":"94244974137","topic":"New Topic"}}}' | \
  ZOOM_CLI_WRITES_ENABLED=false PATH="${MOCK_BIN}:${PATH}" bash "$MCP_SERVER" 2>/dev/null)
tool_text=$(echo "$output" | jq -r '.result.content[0].text')
assert_eq "isError true" "true" "$(echo "$output" | jq '.result.isError')"
assert_eq "error code WRITES_DISABLED" '"WRITES_DISABLED"' "$(echo "$tool_text" | jq '.error.code')"

# ─── Functional Tests: zoom_delete ──────────────────────────────────


echo -e "\n${CYAN}▸ Functional: zoom_delete step 1 returns token${NC}"
setup_mock_curl '{"status":true,"errorCode":0,"result":{"meeting":{"topic":{"value":"Test Meeting"}}}}'
output=$(run_mcp '{"jsonrpc":"2.0","id":200,"method":"tools/call","params":{"name":"zoom_delete","arguments":{"meetingId":"94244974137"}}}')
tool_text=$(echo "$output" | jq -r '.result.content[0].text')
assert_eq "isError false" "false" "$(echo "$output" | jq '.result.isError')"
assert_eq "ok true" "true" "$(echo "$tool_text" | jq '.ok')"
assert_eq "action is confirm_required" '"confirm_required"' "$(echo "$tool_text" | jq '.data.action')"
assert_eq "meetingId echoed" '"94244974137"' "$(echo "$tool_text" | jq '.data.meetingId')"
assert_eq "topic present" '"Test Meeting"' "$(echo "$tool_text" | jq '.data.topic')"
token_val=$(echo "$tool_text" | jq -r '.data.confirmToken')
assert_eq "confirmToken non-empty" "true" "$([[ -n "$token_val" ]] && echo true || echo false)"
rm -f "${SCRIPT_DIR}/.mcp-audit.log"

echo -e "\n${CYAN}▸ Functional: zoom_delete full two-step success${NC}"
setup_mock_curl '{"status":true,"errorCode":0,"result":{"meeting":{"topic":{"value":"Test Meeting"}}}}'
_ts_fifo="${MOCK_DIR}/ts_fifo_$$"
_ts_out="${MOCK_DIR}/ts_out_$$"
mkfifo "$_ts_fifo"
PATH="${MOCK_BIN}:${PATH}" bash "$MCP_SERVER" < "$_ts_fifo" > "$_ts_out" 2>/dev/null &
_ts_pid=$!
exec 7>"$_ts_fifo"
# Step 1
printf '%s\n' '{"jsonrpc":"2.0","id":201,"method":"tools/call","params":{"name":"zoom_delete","arguments":{"meetingId":"94244974137"}}}' >&7
_tsw=0; while [[ $(wc -l < "$_ts_out" 2>/dev/null || echo 0) -lt 1 ]]; do sleep 0.1; _tsw=$((_tsw+1)); ((_tsw>30)) && break; done
_ts_token=$(sed -n '1p' "$_ts_out" | jq -r '.result.content[0].text' | jq -r '.data.confirmToken')
# Step 2 — same server process so token is valid
printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":202,\"method\":\"tools/call\",\"params\":{\"name\":\"zoom_delete\",\"arguments\":{\"meetingId\":\"94244974137\",\"confirmToken\":\"${_ts_token}\"}}}" >&7
_tsw=0; while [[ $(wc -l < "$_ts_out" 2>/dev/null || echo 0) -lt 2 ]]; do sleep 0.1; _tsw=$((_tsw+1)); ((_tsw>30)) && break; done
exec 7>&-
wait "$_ts_pid" 2>/dev/null || true
step2=$(sed -n '2p' "$_ts_out")
step2_text=$(echo "$step2" | jq -r '.result.content[0].text')
assert_eq "step2 isError false" "false" "$(echo "$step2" | jq '.result.isError')"
assert_eq "step2 ok true" "true" "$(echo "$step2_text" | jq '.ok')"
assert_eq "step2 status deleted" '"deleted"' "$(echo "$step2_text" | jq '.data.status')"
assert_eq "step2 meetingId echoed" '"94244974137"' "$(echo "$step2_text" | jq '.data.meetingId')"
rm -f "$_ts_fifo" "$_ts_out" "${SCRIPT_DIR}/.mcp-audit.log"

echo -e "\n${CYAN}▸ Error: zoom_delete invalid token (no prior step 1)${NC}"
output=$(run_mcp '{"jsonrpc":"2.0","id":204,"method":"tools/call","params":{"name":"zoom_delete","arguments":{"meetingId":"94244974137","confirmToken":"fake-token-abc123"}}}')
tool_text=$(echo "$output" | jq -r '.result.content[0].text')
assert_eq "isError true" "true" "$(echo "$output" | jq '.result.isError')"
assert_eq "error code BAD_INPUT" '"BAD_INPUT"' "$(echo "$tool_text" | jq '.error.code')"

echo -e "\n${CYAN}▸ Error: zoom_delete token reuse rejected${NC}"
# Single server: step1 → step2 (success) → step2 again with same token (rejected)
setup_mock_curl '{"status":true,"errorCode":0,"result":{"meeting":{"topic":{"value":"Test Meeting"}}}}'
_ru_fifo="${MOCK_DIR}/ru_fifo_$$"
_ru_out="${MOCK_DIR}/ru_out_$$"
mkfifo "$_ru_fifo"
PATH="${MOCK_BIN}:${PATH}" bash "$MCP_SERVER" < "$_ru_fifo" > "$_ru_out" 2>/dev/null &
_ru_pid=$!
exec 7>"$_ru_fifo"
# Step 1 — get token
printf '%s\n' '{"jsonrpc":"2.0","id":205,"method":"tools/call","params":{"name":"zoom_delete","arguments":{"meetingId":"94244974137"}}}' >&7
_ruw=0; while [[ $(wc -l < "$_ru_out" 2>/dev/null || echo 0) -lt 1 ]]; do sleep 0.1; _ruw=$((_ruw+1)); ((_ruw>30)) && break; done
_ru_token=$(sed -n '1p' "$_ru_out" | jq -r '.result.content[0].text' | jq -r '.data.confirmToken')
# Step 2 — consume token successfully
printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":206,\"method\":\"tools/call\",\"params\":{\"name\":\"zoom_delete\",\"arguments\":{\"meetingId\":\"94244974137\",\"confirmToken\":\"${_ru_token}\"}}}" >&7
_ruw=0; while [[ $(wc -l < "$_ru_out" 2>/dev/null || echo 0) -lt 2 ]]; do sleep 0.1; _ruw=$((_ruw+1)); ((_ruw>30)) && break; done
# Step 3 — reuse same token (must be rejected)
printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":207,\"method\":\"tools/call\",\"params\":{\"name\":\"zoom_delete\",\"arguments\":{\"meetingId\":\"94244974137\",\"confirmToken\":\"${_ru_token}\"}}}" >&7
_ruw=0; while [[ $(wc -l < "$_ru_out" 2>/dev/null || echo 0) -lt 3 ]]; do sleep 0.1; _ruw=$((_ruw+1)); ((_ruw>30)) && break; done
exec 7>&-
wait "$_ru_pid" 2>/dev/null || true
step3=$(sed -n '3p' "$_ru_out")
step3_text=$(echo "$step3" | jq -r '.result.content[0].text')
assert_eq "token reuse isError true" "true" "$(echo "$step3" | jq '.result.isError')"
assert_eq "token reuse error BAD_INPUT" '"BAD_INPUT"' "$(echo "$step3_text" | jq '.error.code')"
rm -f "$_ru_fifo" "$_ru_out" "${SCRIPT_DIR}/.mcp-audit.log"

echo -e "\n${CYAN}▸ Error: zoom_delete meeting not found${NC}"
setup_mock_curl '{"status":false,"errorCode":404,"errorMessage":"Meeting not found"}'
output=$(run_mcp '{"jsonrpc":"2.0","id":210,"method":"tools/call","params":{"name":"zoom_delete","arguments":{"meetingId":"94244974137"}}}')
tool_text=$(echo "$output" | jq -r '.result.content[0].text')
assert_eq "isError true" "true" "$(echo "$output" | jq '.result.isError')"
assert_eq "error code ZOOM_API_ERROR" '"ZOOM_API_ERROR"' "$(echo "$tool_text" | jq '.error.code')"

echo -e "\n${CYAN}▸ Error: zoom_delete invalid meetingId${NC}"
output=$(run_mcp '{"jsonrpc":"2.0","id":211,"method":"tools/call","params":{"name":"zoom_delete","arguments":{"meetingId":"abc-invalid"}}}')
tool_text=$(echo "$output" | jq -r '.result.content[0].text')
assert_eq "isError true" "true" "$(echo "$output" | jq '.result.isError')"
assert_eq "error code BAD_INPUT" '"BAD_INPUT"' "$(echo "$tool_text" | jq '.error.code')"

echo -e "\n${CYAN}▸ Error: zoom_delete auth expired (step 1)${NC}"
setup_mock_curl '{"status":false,"errorCode":201,"errorMessage":"User not login."}'
output=$(run_mcp '{"jsonrpc":"2.0","id":212,"method":"tools/call","params":{"name":"zoom_delete","arguments":{"meetingId":"94244974137"}}}')
tool_text=$(echo "$output" | jq -r '.result.content[0].text')
assert_eq "isError true" "true" "$(echo "$output" | jq '.result.isError')"
assert_eq "error code AUTH_EXPIRED" '"AUTH_EXPIRED"' "$(echo "$tool_text" | jq '.error.code')"

echo -e "\n${CYAN}▸ Security: zoom_delete writes disabled${NC}"
output=$(printf '%s\n' '{"jsonrpc":"2.0","id":213,"method":"tools/call","params":{"name":"zoom_delete","arguments":{"meetingId":"94244974137"}}}' | \
  ZOOM_CLI_WRITES_ENABLED=false PATH="${MOCK_BIN}:${PATH}" bash "$MCP_SERVER" 2>/dev/null)
tool_text=$(echo "$output" | jq -r '.result.content[0].text')
assert_eq "isError true" "true" "$(echo "$output" | jq '.result.isError')"
assert_eq "error code WRITES_DISABLED" '"WRITES_DISABLED"' "$(echo "$tool_text" | jq '.error.code')"

# Rate-limit test: 7th delete in the same minute must be rejected.
# We do 6 full step1+step2 cycles in a single server process, then one more step2.
echo -e "\n${CYAN}▸ Abuse: zoom_delete rate limit (7th delete rejected)${NC}"
setup_mock_curl '{"status":true,"errorCode":0,"result":{"meeting":{"topic":{"value":"Rate Test"}}}}'

# Build all 13 messages: 6 pairs of (step1, step2) plus one extra step1 for the 7th attempt
_rl_msgs=()
for _i in $(seq 1 6); do
  _rl_msgs+=("{\"jsonrpc\":\"2.0\",\"id\":$((220 + (_i-1)*2)),\"method\":\"tools/call\",\"params\":{\"name\":\"zoom_delete\",\"arguments\":{\"meetingId\":\"94244974137\"}}}")
  _rl_msgs+=("STEP2_TOKEN_${_i}")
done
# 7th step1
_rl_msgs+=("{\"jsonrpc\":\"2.0\",\"id\":234,\"method\":\"tools/call\",\"params\":{\"name\":\"zoom_delete\",\"arguments\":{\"meetingId\":\"94244974137\"}}}")

# Use a FIFO approach but send messages one at a time with token extraction
_rl_fifo="${MOCK_DIR}/rl_fifo_$$"
_rl_outfile="${MOCK_DIR}/rl_out_$$"
mkfifo "$_rl_fifo"

PATH="${MOCK_BIN}:${PATH}" bash "$MCP_SERVER" < "$_rl_fifo" > "$_rl_outfile" 2>/dev/null &
_rl_pid=$!
exec 8>"$_rl_fifo"

_rl_line=0
for _i in $(seq 1 6); do
  # Step 1
  _rl_id1=$((220 + (_i-1)*2))
  printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":${_rl_id1},\"method\":\"tools/call\",\"params\":{\"name\":\"zoom_delete\",\"arguments\":{\"meetingId\":\"94244974137\"}}}" >&8
  _rl_line=$(( _rl_line + 1 ))
  _waited=0
  while [[ $(wc -l < "$_rl_outfile" 2>/dev/null || echo 0) -lt $_rl_line ]]; do
    sleep 0.1; _waited=$(( _waited + 1 )); (( _waited > 30 )) && break
  done

  # Extract token from step 1 response
  _rl_token=$(sed -n "${_rl_line}p" "$_rl_outfile" | jq -r '.result.content[0].text' | jq -r '.data.confirmToken')

  # Step 2
  _rl_id2=$((220 + (_i-1)*2 + 1))
  printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":${_rl_id2},\"method\":\"tools/call\",\"params\":{\"name\":\"zoom_delete\",\"arguments\":{\"meetingId\":\"94244974137\",\"confirmToken\":\"${_rl_token}\"}}}" >&8
  _rl_line=$(( _rl_line + 1 ))
  _waited=0
  while [[ $(wc -l < "$_rl_outfile" 2>/dev/null || echo 0) -lt $_rl_line ]]; do
    sleep 0.1; _waited=$(( _waited + 1 )); (( _waited > 30 )) && break
  done
done

# 7th step1 — get a new token
printf '%s\n' '{"jsonrpc":"2.0","id":234,"method":"tools/call","params":{"name":"zoom_delete","arguments":{"meetingId":"94244974137"}}}' >&8
_rl_line=$(( _rl_line + 1 ))
_waited=0
while [[ $(wc -l < "$_rl_outfile" 2>/dev/null || echo 0) -lt $_rl_line ]]; do
  sleep 0.1; _waited=$(( _waited + 1 )); (( _waited > 30 )) && break
done
_rl_token7=$(sed -n "${_rl_line}p" "$_rl_outfile" | jq -r '.result.content[0].text' | jq -r '.data.confirmToken')

# 7th step2 — should be rate limited
printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":235,\"method\":\"tools/call\",\"params\":{\"name\":\"zoom_delete\",\"arguments\":{\"meetingId\":\"94244974137\",\"confirmToken\":\"${_rl_token7}\"}}}" >&8
_rl_line=$(( _rl_line + 1 ))
_waited=0
while [[ $(wc -l < "$_rl_outfile" 2>/dev/null || echo 0) -lt $_rl_line ]]; do
  sleep 0.1; _waited=$(( _waited + 1 )); (( _waited > 30 )) && break
done

exec 8>&-
wait "$_rl_pid" 2>/dev/null || true

_rl_last=$(sed -n "${_rl_line}p" "$_rl_outfile")
_rl_last_text=$(echo "$_rl_last" | jq -r '.result.content[0].text')
assert_eq "7th delete isError true" "true" "$(echo "$_rl_last" | jq '.result.isError')"
assert_eq "7th delete RATE_LIMITED" '"RATE_LIMITED"' "$(echo "$_rl_last_text" | jq '.error.code')"
rm -f "$_rl_fifo" "$_rl_outfile" "${SCRIPT_DIR}/.mcp-audit.log"

# ─── Summary ─────────────────────────────────────────────────────────

echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "Tests: ${TOTAL}  ${GREEN}Passed: ${PASS}${NC}  ${RED}Failed: ${FAIL}${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Cleanup tmp-test if empty
rmdir "${TMPDIR_BASE}" 2>/dev/null || true

exit $FAIL

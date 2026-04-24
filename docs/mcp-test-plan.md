# MCP Read-Only Wrapper: Test Plan

Functional, security, and abuse test plan for the read-only MCP layer over `zoom-cli.sh`.

---

## Test Infrastructure

All tests reuse the existing mock infrastructure from `test-zoom-cli.sh`:

| Component | Location | Purpose |
|---|---|---|
| `setup_mock_curl` | line 84 | Single canned curl response |
| `setup_mock_curl_sequence` | line 100 | Ordered multi-response sequences |
| `get_curl_calls` | line 130 | Inspect outbound curl arguments |
| `setup_test_dir` | line 77 | Isolated temp directory per test |
| `run_cli` / `run_cli_with_exit` | lines 146, 155 | Execute CLI with mocked PATH and SCRIPT_DIR |
| `assert_eq`, `assert_contains`, `assert_not_contains`, `assert_exit_code` | lines 21-73 | Assertion helpers |

### MCP-Specific Additions

The MCP wrapper translates tool calls into `zoom-cli.sh` invocations and returns structured JSON results. Tests for the MCP layer need a thin harness that:

1. Invokes the MCP wrapper with a JSON-RPC-style tool call.
2. Captures the structured response (JSON with `content` and `isError` fields).
3. Reuses the same mock curl / temp-dir pattern from the existing suite.

```bash
# Example: run MCP tool call and capture structured output
run_mcp_tool() {
  local test_dir="$1" tool_name="$2"; shift 2
  # The MCP wrapper delegates to zoom-cli.sh under the hood.
  # Mock PATH injection works identically.
  PATH="${MOCK_BIN}:${PATH}" "${test_dir}/mcp-wrapper.sh" "$tool_name" "$@" 2>&1
}
```

---

## 1. Functional Tests

### 1.1 `list` -- Success

**Maps to existing test:** `test_list_success` (line 325)

| Field | Value |
|---|---|
| Tool call | `zoom_list_meetings` |
| Preconditions | `.raw_cookies` and `.csrf_token` present |
| Mock response | `{"status":true,"errorCode":0,"result":{"totalRecords":2,"meetings":[...]}}` |
| Expected output | Structured JSON containing meeting topic, number, time, duration |
| Assertions | Response `isError` is false; content includes both meetings; total count is 2 |

```bash
test_mcp_list_success() {
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"

  local json='{"status":true,"errorCode":0,"result":{"totalRecords":2,"meetings":[{"time":"Today","list":[{"number":"12345678901","numberF":"123 4567 8901","topic":"Daily Standup","schTimeF":"09:00 AM","duration":30,"type":8,"occurrenceTip":""}]},{"time":"Wed, Apr 1","list":[{"number":"98765432109","topic":"Retro","schTimeF":"02:00 PM","duration":60,"type":2,"occurrenceTip":""}]}]}}'
  setup_mock_curl "$json"

  local output; output=$(run_mcp_tool "$dir" zoom_list_meetings)
  assert_contains "list returns meetings"    "Daily Standup" "$output"
  assert_contains "list returns second mtg"  "Retro"         "$output"
  assert_not_contains "no isError flag"      '"isError":true' "$output"
}
```

### 1.2 `list` -- Empty Result

**Maps to existing test:** `test_list_empty` (line 349)

| Field | Value |
|---|---|
| Mock response | `{"status":true,"errorCode":0,"result":{"totalRecords":0,"meetings":[]}}` |
| Expected output | Content indicates no upcoming meetings |
| Assertions | `isError` is false; content includes "No upcoming meetings" or equivalent |

### 1.3 `list` -- API Error (Non-JSON)

**Maps to existing test:** `test_list_html_error_response` (line 369)

| Field | Value |
|---|---|
| Mock response | `<html><body>Error 405</body></html>` |
| Expected output | Sanitized error message |
| Assertions | `isError` is true; message does not leak raw HTML; message is stable text like "Failed to fetch meetings" |

### 1.4 `view` -- Success

**Maps to existing test:** `test_view_success` (line 520)

| Field | Value |
|---|---|
| Tool call | `zoom_view_meeting` with `meeting_id=12345678901` |
| Mock response | Full meeting JSON with topic, date, time, passcode, invitees |
| Assertions | Content includes topic, meeting ID, date, duration, timezone, passcode |

### 1.5 `view` -- Missing Argument

**Maps to existing test:** `test_view_missing_arg` (line 438)

| Field | Value |
|---|---|
| Tool call | `zoom_view_meeting` with no `meeting_id` |
| Expected output | `isError` is true; message contains "Usage" or validation error |
| Assertions | Exit code is non-zero; no crash or stack trace |

### 1.6 `view` -- Invalid Meeting ID

**New test -- extends `test_view_unparseable_response` (line 552)**

| Field | Value |
|---|---|
| Tool call | `zoom_view_meeting` with `meeting_id=00000` |
| Mock response | `{"status":false,"errorCode":-1,"errorMessage":"Meeting not found."}` |
| Assertions | `isError` is true; message is stable ("Failed to fetch meeting"); no raw JSON leaked |

### 1.7 Invalid Input -- Non-Numeric Meeting ID

**New test**

| Field | Value |
|---|---|
| Tool call | `zoom_view_meeting` with `meeting_id=abc` |
| Expected | Error returned before any curl call is made (input validation) |
| Assertions | `isError` is true; `get_curl_calls` returns empty |

### 1.8 Expired Auth Behavior

**Maps to existing tests:** `test_auth_expired_user_not_login` (line 976), `test_auth_expired_saml_redirect` (line 988), `test_auth_expired_error_page` (line 1000)

| Field | Value |
|---|---|
| Tool call | `zoom_list_meetings` |
| Mock responses | `{"errorCode":201,"errorMessage":"User not login."}`, SAML redirect HTML, Zoom error page |
| Expected | `isError` is true; message is "Session expired" (sanitized); no reauth attempted in MCP mode (non-interactive) |
| Assertions | `assert_contains "Session expired"`; no node/browser process spawned |

```bash
test_mcp_auth_expired_no_reauth() {
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"

  setup_mock_curl '{"status":false,"errorCode":201,"errorMessage":"User not login."}'

  local output; output=$(run_mcp_tool "$dir" zoom_list_meetings)
  assert_contains "reports expiry"       "Session expired" "$output"
  assert_contains "tells user to login"  "login"           "$output"
  # MCP mode is non-interactive, so do_reauth should refuse
  assert_contains "non-interactive"      "not running interactively" "$output"
}
```

---

## 2. Security Tests

### 2.1 No Secret Files Touched in MCP Mode

**Context:** Cookie and CSRF files are `.raw_cookies` and `.csrf_token` in `$SCRIPT_DIR`.

| Check | Method |
|---|---|
| MCP wrapper never writes to `.raw_cookies` | Run a read-only tool call (`list`, `view`); verify file mtime is unchanged |
| MCP wrapper never writes to `.csrf_token` | Same as above |
| MCP wrapper never creates new secret files | Check `$SCRIPT_DIR` for unexpected dotfiles after tool call |

```bash
test_mcp_no_secret_writes() {
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"
  setup_mock_curl '{"status":true,"errorCode":0,"result":{"totalRecords":0,"meetings":[]}}'

  local before_cookie; before_cookie=$(stat -f '%m' "${dir}/.raw_cookies" 2>/dev/null || stat -c '%Y' "${dir}/.raw_cookies")
  local before_csrf;   before_csrf=$(stat -f '%m' "${dir}/.csrf_token" 2>/dev/null || stat -c '%Y' "${dir}/.csrf_token")

  sleep 1  # ensure mtime would change if written
  run_mcp_tool "$dir" zoom_list_meetings > /dev/null

  local after_cookie; after_cookie=$(stat -f '%m' "${dir}/.raw_cookies" 2>/dev/null || stat -c '%Y' "${dir}/.raw_cookies")
  local after_csrf;   after_csrf=$(stat -f '%m' "${dir}/.csrf_token" 2>/dev/null || stat -c '%Y' "${dir}/.csrf_token")

  assert_eq "cookie file untouched" "$before_cookie" "$after_cookie"
  assert_eq "csrf file untouched"   "$before_csrf"   "$after_csrf"
}
```

### 2.2 No Tokens or Cookies in Output

**Maps to existing pattern:** `assert_not_contains` usage (e.g., line 290)

| Check | Method |
|---|---|
| Output does not contain raw cookie values | `assert_not_contains "session=abc"` on every tool response |
| Output does not contain CSRF token | `assert_not_contains "FAKE-CSRF"` on every tool response |
| Debug mode (`ZOOM_DEBUG=1`) output is suppressed | Run with `ZOOM_DEBUG=1`; verify stderr is not forwarded to MCP response |

```bash
test_mcp_no_tokens_in_output() {
  local dir; dir=$(setup_test_dir)
  printf 'session=abc; _zm_ssid=secret123' > "${dir}/.raw_cookies"
  printf 'MY-CSRF-TOKEN-XYZ' > "${dir}/.csrf_token"
  setup_mock_curl '{"status":true,"errorCode":0,"result":{"totalRecords":0,"meetings":[]}}'

  local output; output=$(run_mcp_tool "$dir" zoom_list_meetings)
  assert_not_contains "no raw cookie"  "session=abc"          "$output"
  assert_not_contains "no ssid"        "_zm_ssid=secret123"   "$output"
  assert_not_contains "no csrf token"  "MY-CSRF-TOKEN-XYZ"    "$output"
}

test_mcp_debug_mode_suppressed() {
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"
  setup_mock_curl '{"status":true,"errorCode":0,"result":{"totalRecords":0,"meetings":[]}}'

  local output; output=$(ZOOM_DEBUG=1 run_mcp_tool "$dir" zoom_list_meetings 2>&1)
  assert_not_contains "no dbg prefix" "[dbg]"       "$output"
  assert_not_contains "no cookie val" "session=abc"  "$output"
}
```

### 2.3 Missing Cookie File

**Maps to existing test:** `test_get_cookies_missing` (line 304)

| Field | Value |
|---|---|
| Precondition | No `.raw_cookies` file |
| Expected | `isError` is true; message says "No cookies" |
| Assertions | No crash; no stack trace; stable error text |

### 2.4 Missing CSRF File

**Maps to existing test:** `test_get_csrf_missing` (line 313)

| Field | Value |
|---|---|
| Precondition | `.raw_cookies` exists, no `.csrf_token` |
| Expected | `isError` is true; message says "No CSRF" |

### 2.5 Crash / Restart Does Not Recover Old Session

**New test**

| Field | Value |
|---|---|
| Scenario | A tool call fails due to expired auth. After the process exits, a new invocation should not silently reuse stale credentials. |
| Method | Run list with expired-auth mock; verify failure. Then run list again without re-seeding cookies; verify it still fails (no cached session recovery). |

```bash
test_mcp_no_session_recovery_after_crash() {
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"

  # First call: auth expired
  setup_mock_curl '{"status":false,"errorCode":201,"errorMessage":"User not login."}'
  local out1; out1=$(run_mcp_tool "$dir" zoom_list_meetings)
  assert_contains "first call detects expiry" "Session expired" "$out1"

  # Simulate crash/restart: same dir, same stale files
  # Second call should also fail -- no magic session recovery
  local out2; out2=$(run_mcp_tool "$dir" zoom_list_meetings)
  assert_contains "second call still fails" "Session expired" "$out2"
}
```

### 2.6 Write Commands Are Blocked in Read-Only MCP Mode

**New test -- critical for read-only gating**

The MCP wrapper must refuse `create`, `update`, and `delete` tool calls.

```bash
test_mcp_blocks_create() {
  local dir; dir=$(setup_test_dir)
  rm -f "${TMPDIR_BASE}/curl_calls.log"

  local output; output=$(run_mcp_tool "$dir" zoom_create_meeting --topic "Blocked")
  assert_contains "create blocked" "not available" "$output"
  # Verify no curl call was made
  local calls; calls=$(get_curl_calls)
  assert_eq "no curl calls" "" "$calls"
}

test_mcp_blocks_delete() {
  local dir; dir=$(setup_test_dir)
  local output; output=$(run_mcp_tool "$dir" zoom_delete_meeting 12345)
  assert_contains "delete blocked" "not available" "$output"
}

test_mcp_blocks_update() {
  local dir; dir=$(setup_test_dir)
  local output; output=$(run_mcp_tool "$dir" zoom_update_meeting 12345 --topic "Nope")
  assert_contains "update blocked" "not available" "$output"
}
```

---

## 3. Abuse Tests

### 3.1 Malformed Payloads

| Scenario | Input | Expected |
|---|---|---|
| Empty tool name | `""` | Error: "Unknown" or "not available" |
| Tool name with shell metacharacters | `"; rm -rf /"` | Error, no command injection |
| Meeting ID with shell metacharacters | `"123; cat /etc/passwd"` | Error at input validation; no curl call |
| Meeting ID as very long string | `"1" * 10000` | Error; no buffer overflow or hang |
| Unicode in meeting ID | `"\u202e\u0041"` | Error; clean rejection |

```bash
test_mcp_malformed_tool_name() {
  local dir; dir=$(setup_test_dir)
  local output; output=$(run_mcp_tool "$dir" '"; rm -rf /"')
  assert_contains "rejects bad tool" "Unknown" "$output"
}

test_mcp_shell_injection_in_meeting_id() {
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"
  rm -f "${TMPDIR_BASE}/curl_calls.log"

  local output; output=$(run_mcp_tool "$dir" zoom_view_meeting '123; cat /etc/passwd')
  # Should either reject or pass the literal string safely
  local calls; calls=$(get_curl_calls)
  assert_not_contains "no /etc/passwd access" "/etc/passwd" "$calls"
}
```

### 3.2 Oversized Payloads

| Scenario | Input | Expected |
|---|---|---|
| Meeting ID is 100,000 characters | `python3 -c "print('9'*100000)"` | Rejected before curl; error returned within timeout |
| Tool arguments exceeding 1 MB | Large JSON blob as argument | Rejected or truncated; no OOM crash |

```bash
test_mcp_oversized_meeting_id() {
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"

  local big_id; big_id=$(python3 -c "print('9'*100000)")
  local output exit_code
  output=$(run_mcp_tool "$dir" zoom_view_meeting "$big_id") && exit_code=0 || exit_code=$?

  # Should not hang or crash; should return an error
  assert_contains "rejects oversized input" "error" "$(echo "$output" | tr '[:upper:]' '[:lower:]')"
}
```

### 3.3 Rapid Repeated Calls

| Scenario | Method | Expected |
|---|---|---|
| 50 `list` calls in quick succession | Bash loop | All return valid responses or errors; no state corruption |
| Interleaved `list` and `view` calls | Parallel subshells | No file locking issues; cookie/CSRF files not corrupted |

```bash
test_mcp_rapid_list_calls() {
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"
  setup_mock_curl '{"status":true,"errorCode":0,"result":{"totalRecords":0,"meetings":[]}}'

  local failures=0
  for i in $(seq 1 50); do
    local output; output=$(run_mcp_tool "$dir" zoom_list_meetings 2>&1)
    if ! echo "$output" | grep -qF "Upcoming Meetings"; then
      failures=$((failures + 1))
    fi
  done
  assert_eq "all 50 calls succeed" "0" "$failures"
}

test_mcp_concurrent_calls() {
  local dir; dir=$(setup_test_dir)
  printf 'session=abc' > "${dir}/.raw_cookies"
  printf 'FAKE-CSRF' > "${dir}/.csrf_token"
  setup_mock_curl '{"status":true,"errorCode":0,"result":{"totalRecords":0,"meetings":[]}}'

  # Launch 10 parallel calls
  local pids=()
  for i in $(seq 1 10); do
    run_mcp_tool "$dir" zoom_list_meetings > /dev/null 2>&1 &
    pids+=($!)
  done

  local failures=0
  for pid in "${pids[@]}"; do
    wait "$pid" || failures=$((failures + 1))
  done
  assert_eq "no concurrent failures" "0" "$failures"

  # Verify secret files are not corrupted
  local cookies; cookies=$(cat "${dir}/.raw_cookies")
  assert_eq "cookies intact" "session=abc" "$cookies"
}
```

---

## 4. Error Response Format

All MCP error responses must follow a stable, sanitized structure:

```json
{
  "content": [
    {
      "type": "text",
      "text": "Human-readable error message without secrets or stack traces"
    }
  ],
  "isError": true
}
```

### Validation Checklist

| Property | Requirement | How to Test |
|---|---|---|
| `isError` field present | Always set on errors | Parse JSON output for every error test case |
| No cookie values | Never in `text` field | `assert_not_contains` against known cookie values |
| No CSRF token | Never in `text` field | `assert_not_contains` against known CSRF value |
| No stack traces | No Python/Bash tracebacks | `assert_not_contains "Traceback"`, `assert_not_contains "line "` |
| Stable message text | Same error text across runs | Run twice, compare output |
| No raw HTML | HTML errors are translated | `assert_not_contains "<html>"` |

---

## 5. Test Matrix Summary

| # | Test Case | Category | Existing Test | New/Extended |
|---|---|---|---|---|
| F1 | list success | Functional | `test_list_success` (325) | Extended for MCP JSON envelope |
| F2 | list empty | Functional | `test_list_empty` (349) | Extended |
| F3 | list error (HTML) | Functional | `test_list_html_error_response` (369) | Extended |
| F4 | view success | Functional | `test_view_success` (520) | Extended |
| F5 | view missing arg | Functional | `test_view_missing_arg` (438) | Extended |
| F6 | view invalid ID | Functional | `test_view_unparseable_response` (552) | Extended |
| F7 | view non-numeric ID | Functional | -- | New |
| F8 | auth expired (3 variants) | Functional | lines 976, 988, 1000 | Extended for no-reauth |
| S1 | no secret file writes | Security | -- | New |
| S2 | no tokens in output | Security | `assert_not_contains` pattern (290) | Extended |
| S3 | debug mode suppressed | Security | -- | New |
| S4 | missing cookie file | Security | `test_get_cookies_missing` (304) | Extended |
| S5 | missing CSRF file | Security | `test_get_csrf_missing` (313) | Extended |
| S6 | no session recovery | Security | -- | New |
| S7 | write commands blocked | Security | -- | New (create/update/delete) |
| A1 | malformed tool name | Abuse | -- | New |
| A2 | shell injection in ID | Abuse | -- | New |
| A3 | oversized meeting ID | Abuse | -- | New |
| A4 | rapid repeated calls | Abuse | -- | New |
| A5 | concurrent calls | Abuse | -- | New |

---

## 6. Running the Tests

Tests should be added to a new file `test-mcp.sh` that sources the shared infrastructure:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Source shared helpers from the main test file or a factored-out helper
source "${SCRIPT_DIR}/test-helpers.sh"  # extracted from test-zoom-cli.sh

# ... MCP-specific tests ...
```

Alternatively, MCP tests can be appended to `test-zoom-cli.sh` as a new section:

```bash
# ─── MCP wrapper tests ──────────────────────────────────────────────
test_mcp_list_success
test_mcp_auth_expired_no_reauth
test_mcp_no_secret_writes
test_mcp_no_tokens_in_output
# ...
```

All tests use the same `MOCK_BIN` PATH injection and temp-dir isolation, so no additional infrastructure is needed beyond the MCP wrapper entry point.

# MCP Wrapper Safety Controls

This document defines the security controls and policies for the zoom-cli MCP wrapper. These controls reduce abuse and secret leakage risks when zoom-cli is exposed via Model Context Protocol (MCP).

## Overview

The zoom-cli tool manages Zoom meetings using session cookies from browser login. When exposed via MCP, it must enforce strict controls to:

- Prevent execution of arbitrary commands or paths
- Block access to sensitive operations (raw API calls)
- Protect credentials stored on disk (.raw_cookies, .csrf_token)
- Sanitize all output to remove secrets from error messages
- Log all actions with audit trail while masking sensitive data

---

## 1. Command Allowlist

**Principle**: Only safe, read-only commands are exposed via MCP in the initial release. Write operations are deferred to Phase 2+.

### Allowed Commands

| Command | MCP Exposure | Purpose | Risk Level |
|---------|---|---------|-----------|
| `list` / `ls` | ✓ Yes | List upcoming meetings (read-only) | Low |
| `view` / `show` / `get` | ✓ Yes | View single meeting details (read-only) | Low |
| `create` / `new` / `schedule` | Deferred (Phase 2+) | Schedule new meeting (controlled args) | Medium |
| `update` / `edit` | Deferred (Phase 2+) | Update meeting details (controlled args) | Medium |
| `delete` / `rm` / `remove` | Deferred (Phase 2+) | Delete meeting (single ID validation) | Medium |

### Blocked Commands (Never Expose via MCP)

| Command | Why | Risk |
|---------|-----|------|
| `raw` | Passes arbitrary paths and POST parameters directly to curl; enables full API access bypass | **Critical** |
| `set-cookies` | Allows injection of attacker-controlled cookies | Critical |
| `import-cookies` | Reads arbitrary files and parses as cookies | Critical |
| `login` / `auth` / `grab-cookies` | Launches browser for interactive SSO | Medium (not applicable to automated MCP) |
| `refresh-csrf` | Can be abused to trigger auth errors; requires cookies already set | Low-Medium |

**Testable Criterion**:
```bash
# Verify raw command is rejected when called via MCP wrapper
mcp-call "raw GET /meeting" && echo "FAIL: raw not blocked" || echo "PASS: raw blocked"
```

---

## 2. Argument Validation Strategy

**Principle**: Strictly validate input for each exposed command. No argument should reach zoom_get/zoom_post without validation.

### Per-Command Validation

#### `list` / `ls`
- **Validation**: No arguments accepted.
- **Testable Criterion**:
  ```bash
  # Should reject if any args provided
  cmd_list extra_arg && echo "FAIL: list accepts args" || echo "PASS"
  ```

#### `view` / `show` / `get`
- **Validation**: Meeting ID must be:
  - Non-empty string
  - Numeric (digits only) or meeting link format
  - Max 20 characters (longest Zoom meeting ID is ~11 digits)
- **Implementation**:
  ```bash
  # Example validation
  if [[ ! "$meeting_id" =~ ^[0-9]{1,20}$ ]]; then
    err "Invalid meeting ID format"
    exit 1
  fi
  ```
- **Testable Criterion**:
  ```bash
  cmd_view "123456789" && echo "PASS: valid ID accepted"
  cmd_view "abc" && echo "FAIL: non-numeric ID accepted" || echo "PASS"
  cmd_view "" && echo "FAIL: empty ID accepted" || echo "PASS"
  cmd_view "123456789012345678901" && echo "FAIL: oversized ID accepted" || echo "PASS"
  ```

#### `create` / `new` / `schedule` (deferred — included here for completeness when write tools are enabled)
- **Validation**:
  - `--topic` / `-t`: Non-empty string, max 300 characters
  - `--date` / `-d`: MM/DD/YYYY format only
  - `--time`: H:MM or HH:MM format only, 0-23 hour range
  - `--ampm`: Exactly "AM" or "PM" (case-insensitive)
  - `--duration`: Positive integer, 1-540 minutes (1 min to 9 hours)
  - `--timezone`: Must be in /etc/timezone or system tz database
  - `--invite` / `-i`: Valid email format (basic check: contains @ and .)
  - `--recurrence-type`: Whitelist only DAILY, WEEKLY, MONTHLY
  - `--recurrence-interval`: Positive integer, 1-100
  - `--recurrence-days`: Comma-separated from {SU,MO,TU,WE,TH,FR,SA}
- **Implementation**: Use bash `case` statements for whitelist validation.
- **Testable Criterion**:
  ```bash
  # Valid inputs should work
  cmd_create --topic "Standup" --duration 30 && echo "PASS"
  
  # Invalid inputs should reject
  cmd_create --duration 1000 && echo "FAIL: oversized duration" || echo "PASS"
  cmd_create --timezone "America/InvalidCity" && echo "FAIL: bad timezone" || echo "PASS"
  cmd_create --invite "not-an-email" && echo "FAIL: bad email" || echo "PASS"
  cmd_create --ampm "am" && echo "FAIL: case-sensitive ampm" || echo "PASS"
  ```

#### `update` / `edit` (deferred — included here for completeness when write tools are enabled)
- **Validation**:
  - Meeting ID: Same as `view` (numeric, 1-20 chars)
  - All optional parameters: Same validation as `create`
  - At least one update parameter must be provided
- **Testable Criterion**:
  ```bash
  cmd_update "123456789" --topic "New Topic" && echo "PASS"
  cmd_update "notanumber" --topic "Fail" && echo "FAIL" || echo "PASS"
  cmd_update "123456789" && echo "FAIL: no args" || echo "PASS"
  ```

#### `delete` / `rm` / `remove` (deferred — included here for completeness when write tools are enabled)
- **Validation**:
  - Meeting ID: Same as `view` (numeric, 1-20 chars)
- **Testable Criterion**:
  ```bash
  cmd_delete "123456789" && echo "PASS"
  cmd_delete "abc" && echo "FAIL" || echo "PASS"
  ```

### Validation Implementation Pattern

All validators should follow this pattern:
```bash
validate_meeting_id() {
  local id="$1"
  [[ -z "$id" ]] && { err "Meeting ID required"; return 1; }
  [[ ! "$id" =~ ^[0-9]{1,20}$ ]] && { err "Invalid meeting ID"; return 1; }
  return 0
}

validate_email() {
  local email="$1"
  [[ "$email" =~ ^[^@]+@[^@]+\.[^@]+$ ]] || { err "Invalid email"; return 1; }
  return 0
}
```

---

## 3. Execution Timeout & Output Size Limits

**Principle**: Prevent resource exhaustion and denial-of-service attacks.

### Timeout Policy

**Current State**: `CURL_TIMEOUT=15` (line 19 in zoom-cli.sh)

**Policy**:
- All curl calls inherit `--max-time 15` seconds
- MCP wrapper must not allow override of CURL_TIMEOUT
- If a response takes >15 seconds, curl fails and the command is retried once (see `zoom_authed()` at line 162)
- If retry also times out, error is returned to caller

**Testable Criterion**:
```bash
# Verify timeout is applied to all zoom_* calls
grep -n "max-time" zoom-cli.sh | wc -l
# Expected: 4 (zoom_get, zoom_post, zoom_post_follow, zoom_post_json)
```

### Output Size Limit

**Current State**: No explicit output size limit; responses are truncated to 500 chars in debug output only.

**Policy**:
- MCP wrapper must enforce max response size of 100 KB (102,400 bytes)
- Responses exceeding this limit are truncated with message: `"[Output truncated — response exceeded 100 KB limit]"`
- Truncation happens before JSON parsing/formatting
- File-based output (.raw_cookies, .csrf_token) is read-only; no write limits needed

**Implementation**:
```bash
# In MCP wrapper, after curl call:
response_size=${#response}
if (( response_size > 102400 )); then
  response="${response:0:102400}"
  warn "[Response truncated from $response_size to 100 KB]"
fi
```

**Testable Criterion**:
```bash
# Verify response truncation
long_response=$(printf 'x%.0s' {1..200000})
if [[ ${#long_response} -gt 102400 ]]; then
  echo "PASS: truncation logic needed"
fi
```

---

## 4. Audit Logging Policy

**Principle**: Log all MCP actions for security auditing while masking secrets.

### What Gets Logged

Every MCP call must record:
1. Timestamp (ISO 8601)
2. Command name (e.g., "view", "create")
3. Caller identity (if available from MCP context)
4. Input parameters (validated, non-secret)
5. Result (success/error, not including sensitive values)
6. Response size
7. Execution time

### What Does NOT Get Logged

- Full response bodies (only summary)
- Cookie strings
- CSRF tokens
- Email addresses of invitees
- Meeting join URLs (link itself is sensitive)
- Any secrets from error messages

### Log Format

```
[2026-04-24T15:30:45Z] ACTION=view MEETING_ID=123456789 RESULT=success SIZE=1240 TIME_MS=342
[2026-04-24T15:31:12Z] ACTION=create TOPIC="Standup" DURATION=30 RESULT=success NEW_ID=987654321 TIME_MS=1205
[2026-04-24T15:32:00Z] ACTION=delete MEETING_ID=123456789 RESULT=success TIME_MS=612
[2026-04-24T15:32:15Z] ACTION=create TOPIC="Meeting" DURATION=999 RESULT=error ERROR=invalid_duration TIME_MS=15
```

### Log Storage

- Location: `${SCRIPT_DIR}/.mcp-audit.log` (same dir as zoom-cli.sh)
- Rotation: Keep last 100 entries (automatic truncation if >10,000 lines)
- Permissions: Mode 0600 (read/write by owner only)

### Log Utility Functions

```bash
audit_log() {
  local action="$1"
  local status="$2"
  local metadata="$3"  # Additional key=value pairs
  
  local timestamp
  timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  
  echo "[${timestamp}] ACTION=${action} STATUS=${status} ${metadata}" >> "${SCRIPT_DIR}/.mcp-audit.log"
  
  # Rotate if needed
  local line_count
  line_count=$(wc -l < "${SCRIPT_DIR}/.mcp-audit.log")
  if (( line_count > 10000 )); then
    tail -n 5000 "${SCRIPT_DIR}/.mcp-audit.log" > "${SCRIPT_DIR}/.mcp-audit.log.tmp"
    mv "${SCRIPT_DIR}/.mcp-audit.log.tmp" "${SCRIPT_DIR}/.mcp-audit.log"
  fi
}
```

**Testable Criterion**:
```bash
# Call a command and verify audit log entry
cmd_list
tail -1 "${SCRIPT_DIR}/.mcp-audit.log" | grep -q "ACTION=list" && echo "PASS: logged" || echo "FAIL"
```

---

## 5. Secret Redaction Rules

**Principle**: No secret should ever appear in error messages, logs, or MCP output.

### Secret Types & Redaction

| Secret | Appears In | Redaction Rule | Status |
|--------|-----------|-----------------|--------|
| **Cookie string** | `.raw_cookies` file | Never expose via MCP; block file access completely | Critical |
| **CSRF token** | `.csrf_token` file | Never expose via MCP; block file access completely | Critical |
| **Cookie in curl headers** | Error output when curl verbose mode enabled | Strip `-v` from any curl calls; never enable verbose in MCP mode | Medium |
| **CSRF in API response** | `refresh-csrf` debug output (line 89) | `dbg()` calls must be suppressed when `ZOOM_DEBUG=1` is set via MCP | Medium |
| **API error messages** | Response body from Zoom API | Sanitize errorMessage field before returning | Low-Medium |
| **Invitee emails** | `create` command response | Mask with `***` in logs | Low |
| **Join URLs** | `view`/`create` response | Mask domain with `https://***` in logs | Low |

### Redaction Implementation

#### A. Prevent ZOOM_DEBUG via MCP

**Current Risk** (line 26):
```bash
dbg() { [[ "${ZOOM_DEBUG:-0}" == "1" ]] && echo -e "${YELLOW}[dbg]${NC} $*" >&2 || true; }
```

**MCP Policy**: When called via MCP, unset or force `ZOOM_DEBUG=0`:
```bash
# In MCP wrapper initialization
export ZOOM_DEBUG=0
unset ZOOM_DEBUG
```

**Testable Criterion**:
```bash
ZOOM_DEBUG=1 cmd_refresh_csrf 2>&1 | grep -q "csrf_js response" && echo "FAIL: debug output exposed" || echo "PASS"
```

#### B. Block File Access

**Current Risk**: Files `.raw_cookies` and `.csrf_token` are readable.

**Policy**: MCP wrapper must reject any attempt to:
- Read .raw_cookies or .csrf_token files
- List directory contents containing them
- Copy or transfer these files

**Implementation**:
```bash
# Add permission check before any file operation
is_sensitive_file() {
  local path="$1"
  [[ "$path" == ".raw_cookies" ]] || [[ "$path" == ".csrf_token" ]] && return 0
  return 1
}

# In each command that touches files
if is_sensitive_file "$target_file"; then
  err "Access denied: cannot expose credentials"
  return 1
fi
```

**Testable Criterion**:
```bash
# Verify files are not readable via any public interface
cat "${SCRIPT_DIR}/.raw_cookies" && echo "FAIL: readable" || echo "PASS: protected"
```

#### C. Sanitize API Error Messages

**Implementation**: Before returning error responses, strip any cookie/token-like values:
```bash
sanitize_error_message() {
  local msg="$1"
  # Remove patterns like "Cookie: ..." or token values
  msg=$(echo "$msg" | sed 's/Cookie:[^;]*/Cookie:***REDACTED***/g')
  msg=$(echo "$msg" | sed 's/ZOOM-CSRFTOKEN=[^ ,;]*/ZOOM-CSRFTOKEN=***REDACTED***/g')
  msg=$(echo "$msg" | sed -E 's/(zoom-csrftoken|zoom_token):\s*[^ ]+/\1:***REDACTED***/gi')
  echo "$msg"
}

# Before returning error to MCP
if echo "$response" | grep -q "errorMessage"; then
  response=$(echo "$response" | python3 -c "
import sys, json
d = json.load(sys.stdin)
if 'errorMessage' in d:
  d['errorMessage'] = '$(sanitize_error_message \"${d['errorMessage']}\")'
print(json.dumps(d))
")
fi
```

**Testable Criterion**:
```bash
# Force an auth error and verify no secrets in output
bad_cookies="test=value" ./zoom-cli.sh view 999 2>&1 | grep -iE "(cookie|csrf|token)" && echo "FAIL: secrets exposed" || echo "PASS"
```

---

## 6. Environment Variable Isolation

**Principle**: MCP wrapper runs in a controlled environment with only necessary vars.

### Required Environment

| Variable | Purpose | Set By | Safe? |
|----------|---------|--------|-------|
| `SCRIPT_DIR` | Base path for .raw_cookies, .csrf_token | Script itself | Yes |
| `RAW_COOKIE_FILE` | Path to cookie file | Script (line 16) | Yes |
| `CSRF_FILE` | Path to CSRF token file | Script (line 17) | Yes |
| `ZOOM_BASE` | API base URL (hardcoded) | Script (line 18) | Yes |
| `CURL_TIMEOUT` | Curl timeout (hardcoded) | Script (line 19) | Yes |

### Forbidden Environment Variables (MCP Must Strip)

| Variable | Why |
|----------|-----|
| `ZOOM_DEBUG` | Exposes secrets in debug output |
| `http_proxy` / `https_proxy` | Could redirect API calls to attacker server |
| `LD_PRELOAD` / `LD_LIBRARY_PATH` | Could load malicious code |
| `SHELL` / `BASH_ENV` | Could execute arbitrary code |

### MCP Wrapper Environment Setup

```bash
#!/bin/bash
# mcp-zoom-wrapper.sh — Safe MCP entry point

# Strip all unsafe vars
unset ZOOM_DEBUG http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
unset LD_PRELOAD LD_LIBRARY_PATH BASH_ENV SHELL

# Ensure timeout is enforced
export CURL_TIMEOUT=15

# Run zoom-cli with validated command
source /path/to/zoom-cli.sh "$@"
```

**Testable Criterion**:
```bash
# Verify MCP wrapper unsets debug
ZOOM_DEBUG=1 ./mcp-zoom-wrapper.sh view 123 2>&1 | grep -q "\[dbg\]" && echo "FAIL" || echo "PASS"
```

---

## Summary: Testable Acceptance Criteria

### 1. Wrapper Cannot Execute Arbitrary Commands

```bash
# Test: raw command is blocked
./mcp-zoom-wrapper.sh raw GET /meeting && echo "FAIL: raw allowed" || echo "PASS"

# Test: unknown commands rejected
./mcp-zoom-wrapper.sh unknown-cmd && echo "FAIL" || echo "PASS"

# Test: set-cookies blocked
./mcp-zoom-wrapper.sh set-cookies "x=y" && echo "FAIL" || echo "PASS"
```

### 2. raw Command Explicitly Blocked

```bash
# Already covered above
./mcp-zoom-wrapper.sh raw POST /rest/meeting/save '{}' && echo "FAIL: raw not blocked" || echo "PASS"
```

### 3. ZOOM_DEBUG Env Var Stripped in MCP Mode

```bash
ZOOM_DEBUG=1 ./mcp-zoom-wrapper.sh view 999 2>&1 | grep -E "\[dbg\]|csrf_js response" \
  && echo "FAIL: debug output leaked" || echo "PASS: debug suppressed"
```

### 4. Logs Include Action Metadata But No Secrets

```bash
# Create a meeting and check audit log (deferred — write commands not exposed until Phase 2+)
./mcp-zoom-wrapper.sh create --topic "Test" && \
  tail -1 .mcp-audit.log | grep -q "ACTION=create" && echo "PASS: logged" || echo "FAIL"

# Verify no sensitive data
tail -5 .mcp-audit.log | grep -iE "cookie|csrf|token|password" \
  && echo "FAIL: secrets in log" || echo "PASS: sanitized"
```

### 5. Safety Controls Documented with Testable Criteria

All test cases in this document use bash expressions that can be automated in CI/CD:

```bash
#!/bin/bash
# test-mcp-safety.sh

failed=0

# Test 1: raw blocked
./mcp-zoom-wrapper.sh raw GET /meeting >/dev/null 2>&1 && ((failed++))

# Test 2: ZOOM_DEBUG stripped
ZOOM_DEBUG=1 ./mcp-zoom-wrapper.sh list 2>&1 | grep -q "\[dbg\]" && ((failed++))

# Test 3: Audit log exists
[[ -f .mcp-audit.log ]] || ((failed++))

# Test 4: No secrets in log
grep -iE "^.*cookie|^.*csrf" .mcp-audit.log && ((failed++))

exit $failed
```

---

## Implementation Roadmap

### Phase 1: Command Dispatch Hardening (Done)
- [x] Document allowlist
- [x] Document command blocking (raw)
- [ ] Implement validation guards in wrapper

### Phase 2: Argument Validation (Recommended for Phase 4)
- [ ] Implement per-command validators
- [ ] Add timezone validation against system database
- [ ] Add email format validation

### Phase 3: Secret Redaction (Recommended for Phase 4)
- [ ] Suppress ZOOM_DEBUG in MCP mode
- [ ] Implement sanitize_error_message utility
- [ ] Add tests for secret leakage

### Phase 4: Audit Logging (Recommended for Phase 5)
- [ ] Implement audit_log utility
- [ ] Add per-command logging hooks
- [ ] Set up log rotation

---

## References

- **Codebase**: zoom-cli.sh (lines 722-783 command dispatch, lines 26 debug function)
- **MCP Security Best Practices**: Principle of least privilege, defense in depth
- **Related Issues**: #5 (this documentation)

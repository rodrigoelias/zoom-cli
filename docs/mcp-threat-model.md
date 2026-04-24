# zoom-cli Threat Model

Last updated: 2026-04-24

## Scope

This document covers `zoom-cli.sh`, `grab-cookies.mjs`, and the credential files they produce (`.raw_cookies`, `.csrf_token`). It is meant for anyone evaluating whether to run this tool on their machine.

## Assumptions

1. The user's workstation is not already fully compromised. If an attacker has root or the user's UID, all bets are off regardless of this tool.
2. The Zoom web session being impersonated belongs to a single user. There is no multi-tenant isolation.
3. Network traffic between the workstation and `*.zoom.us` uses TLS (enforced by curl's HTTPS URLs). We trust the system CA store.
4. The user has reviewed and trusts the specific versions of `curl`, `node`, `python3`, and `jq` on their PATH.

## Architecture Overview

```
User --> zoom-cli.sh --[curl]--> zoom.us (HTTPS)
              |
              +--> .raw_cookies   (plaintext session cookies)
              +--> .csrf_token    (plaintext CSRF token)
              +--> grab-cookies.mjs --[playwright/chromium]--> SSO flow
```

All API requests are made by shelling out to `curl`. JSON processing uses `python3`. Browser-based login uses `node` running Playwright.

---

## What IS Protected

### CSRF token lifecycle
- `cmd_refresh_csrf` fetches a fresh token via `POST /csrf_js` with the `FETCH-CSRF-TOKEN: 1` header (line 78-84).
- The token is prepended to the cookie string so it travels as both a cookie and a header value on every subsequent request (line 108).
- Every `zoom_get`, `zoom_post`, and `zoom_post_json` call sends the `zoom-csrftoken` header and the `x-requested-with: XMLHttpRequest, OWASP CSRFGuard Project` header. This matches the browser's CSRF protection scheme.

### Session expiry detection
- `is_auth_expired()` (lines 130-142) checks for three distinct expiry patterns:
  - JSON error code 201 / "User not login" message
  - SAML redirect (`login.microsoftonline.com`, `SAMLRequest`)
  - Zoom error page (`<title>Error - Zoom</title>`)
- `zoom_authed` wraps API calls with a single automatic retry after re-authentication. It does not retry infinitely.

### Non-interactive guard
- `do_reauth` (lines 147-157) checks `[[ -t 0 && -t 1 ]]` before launching a browser. In non-interactive contexts (piped, cron, MCP server), it refuses to re-authenticate and returns an error instead of hanging.

### TLS for API traffic
- All `ZOOM_BASE` URLs use `https://`. Curl follows redirects (`-L`) but still over HTTPS.

---

## What is NOT Protected

### 1. Plaintext credential files on disk

**Risk: HIGH**

`.raw_cookies` and `.csrf_token` are written to `SCRIPT_DIR` with no filesystem permission restrictions. Any process running as the same user (or root) can read them.

- `printf '%s' "$raw" > "$RAW_COOKIE_FILE"` (line 51, 63, 108) -- no `umask` or `chmod 600`.
- `writeFileSync(RAW_COOKIE_FILE, raw, "utf-8")` in `grab-cookies.mjs` (line 67) -- same issue.
- The Netscape-format `cookies.txt` is also written world-readable (line 83).

**Impact:** An attacker with read access to the project directory obtains a full Zoom session. They can list, create, modify, and delete meetings on behalf of the user.

### 2. PATH-based binary resolution

**Risk: HIGH**

Every external binary is resolved via `PATH`:
- `curl` -- carries cookies and CSRF tokens to the network
- `node` -- receives the path to `grab-cookies.mjs` and launches a browser with SSO
- `python3` -- processes API responses; `cmd_create` passes user input through it
- `jq` -- not currently used in the main script but may appear in extensions
- `awk`, `sed`, `date`, `wc`, `tr`, `grep`, `cut` -- standard utilities

A malicious binary placed earlier in `PATH` intercepts all API calls, credentials, and responses. The test suite itself demonstrates this attack: `PATH="${MOCK_BIN}:${PATH}"` (line 151 of `test-zoom-cli.sh`) is how it mocks `curl` and `node`.

**Impact:** Full credential theft, silent API manipulation, or arbitrary code execution under the user's UID.

### 3. No response integrity verification

**Risk: MEDIUM**

Responses from `curl` are accepted as-is. There is no signature, checksum, or schema validation.

- `test_list_html_error_response` (test-zoom-cli.sh line 369-377) shows the CLI receives `<html><body>Error 405</body></html>` and simply reports "Failed to fetch". It does not distinguish between a legitimate error and an injected response.
- In `cmd_create`, response JSON is parsed via `eval "$(echo "$response" | python3 ...)"` (line 614). If an attacker controls the response (via PATH injection or network MITM before TLS terminates), they can inject shell commands through the eval.

**Impact:** If response content is attacker-controlled, arbitrary code execution is possible via the `eval` in `cmd_create`.

### 4. Stale credentials persist after failure

**Risk: LOW-MEDIUM**

If `grab-cookies.mjs` fails (timeout, crash, Playwright error), any previously written `.raw_cookies` remains on disk. The CLI will continue using stale credentials without warning until `is_auth_expired` triggers.

There is no mechanism to invalidate or rotate credential files on failure.

### 5. No rate limiting or circuit breaker

**Risk: LOW**

`CURL_TIMEOUT=15` (line 19) bounds individual request duration. There is no:
- Request-per-second throttle
- Backoff after repeated failures
- Circuit breaker to stop after N consecutive errors

In MCP usage, a misbehaving caller could issue hundreds of Zoom API requests per minute. Zoom's server-side rate limiting is the only backstop.

### 6. Cookie and CSRF token in shell variables

**Risk: LOW**

Cookies and CSRF tokens are passed as command-line arguments to `curl` (via `-H "Cookie: ${cookies}"`). On most Unix systems, `/proc/<pid>/cmdline` is readable by the same user, briefly exposing credentials during the `curl` process lifetime. This is standard for shell-based HTTP tools but worth noting.

### 7. Eval-based response parsing in cmd_create

**Risk: MEDIUM**

Line 614 uses `eval "$(echo "$response" | python3 ...)"` to extract variables from the create-meeting response. The Python script uses `shlex.quote()` to sanitize values, which is correct. However, the pattern is fragile: a bug in the Python sanitization path or an unexpected response format could lead to shell injection.

---

## Threat Scenarios

### Scenario A: Malicious local process reads credentials
- **Vector:** Any process running as the user reads `.raw_cookies`
- **Likelihood:** Moderate (browser extensions, npm postinstall scripts, malware)
- **Mitigation available:** Set `umask 077` before running, or manually `chmod 600` the files
- **Mitigation NOT implemented:** The tool does not do this automatically

### Scenario B: PATH injection via compromised dependency
- **Vector:** A compromised npm package or brew formula places a binary named `curl` or `node` in a directory that appears before `/usr/bin` in PATH
- **Likelihood:** Low but well-documented in supply-chain attacks
- **Mitigation available:** Pin PATH explicitly (e.g., `PATH=/usr/bin:/bin`) before invoking zoom-cli
- **Mitigation NOT implemented:** The tool uses ambient PATH

### Scenario C: MCP caller floods Zoom API
- **Vector:** An LLM agent or MCP client calls `list`/`create`/`delete` in a tight loop
- **Likelihood:** Moderate in automated setups
- **Mitigation available:** Wrap the MCP server with rate limiting
- **Mitigation NOT implemented:** No built-in throttle

### Scenario D: Stale session used after logout
- **Vector:** User logs out of Zoom in browser, but `.raw_cookies` still contains the old session
- **Likelihood:** High (normal usage pattern)
- **Mitigation available:** Delete credential files on logout, or add a `zoom-cli.sh logout` command
- **Mitigation NOT implemented:** No logout command exists

---

## User-Facing Security Notes

Before using zoom-cli, understand these points:

1. **Your Zoom session cookies are stored in plaintext** in `.raw_cookies` next to the script. Treat this file like a password. Do not commit it to version control. The `.gitignore` should exclude it.

2. **Anyone who can read your project directory can impersonate your Zoom session.** This includes other processes running as your user, shared filesystems, and backup tools.

3. **The tool trusts whatever `curl`, `node`, and `python3` resolve to on your PATH.** If you are in an environment where PATH may be modified by untrusted code (e.g., nvm, pyenv, direnv, or CI runners), verify which binaries are being used: `which curl node python3`.

4. **There is no automatic credential rotation or expiry.** If your Zoom session expires, the tool will detect it and prompt for re-login. But credentials are never proactively cleared.

5. **The tool does not validate that Zoom's responses are genuine.** It trusts TLS to prevent network-level tampering, but does not verify response structure beyond basic JSON parsing.

6. **When used as an MCP server, every connected client gets full access** to whatever Zoom operations the tool supports. There is no per-client authorization or scoping.

---

## Sign-Off Checklist

Complete this checklist before broader use (beyond the original developer):

- [ ] `.raw_cookies`, `.csrf_token`, and `cookies.txt` are in `.gitignore`
- [ ] File permissions on credential files are restricted (`chmod 600`)
- [ ] PATH is reviewed or pinned in the execution environment
- [ ] Users have read the "User-Facing Security Notes" section above
- [ ] Rate limiting is in place if the tool is exposed via MCP
- [ ] A logout/credential-wipe command has been considered
- [ ] The `eval` in `cmd_create` (line 614) has been reviewed for shell injection resistance
- [ ] Backup and disk-encryption status of the machine has been confirmed (protects credential files at rest)

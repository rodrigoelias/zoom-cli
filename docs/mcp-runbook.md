# zoom-cli MCP Operator Runbook

Operational guide for running zoom-cli as an MCP tool server. Covers session startup, health checks, shutdown, and troubleshooting.

## Prerequisites

- `bash` (4.x+), `curl`, `python3`, `jq` (optional, for debugging)
- Node.js 18+ with Playwright installed (`npm install`) -- only needed for automated login
- Network access to `skyscanner.zoom.us`

## Session startup

zoom-cli requires two credential files before any API call succeeds:

| File | Contents | Created by |
|------|----------|------------|
| `.raw_cookies` | Semicolon-delimited browser cookies | `login` or `set-cookies` |
| `.csrf_token` | CSRF token value | `refresh-csrf` (called automatically by `login`) |

Both files live in the script directory (next to `zoom-cli.sh`).

### Path A: Automated login (interactive only)

```bash
./zoom-cli.sh login
```

This launches a Chromium window via Playwright (`grab-cookies.mjs`), waits for SSO to complete, writes `.raw_cookies`, then automatically calls `refresh-csrf` to populate `.csrf_token`.

**Not usable from MCP.** The `login` command requires a visible browser and an interactive terminal. Provision credentials before starting the MCP server.

### Path B: Manual cookie injection

1. Sign into `https://skyscanner.zoom.us` in a browser.
2. Open DevTools Console and run: `copy(document.cookie)`
3. Provide the cookies to zoom-cli:

```bash
./zoom-cli.sh set-cookies "<paste>"
```

4. Fetch the CSRF token:

```bash
./zoom-cli.sh refresh-csrf
```

5. Verify the session works:

```bash
./zoom-cli.sh list
```

### MCP cold-start checklist

1. Ensure `.raw_cookies` and `.csrf_token` exist in the zoom-cli directory.
2. Start the MCP server process.
3. Issue a `list` command as a smoke test. If it returns meetings (or "No upcoming meetings."), the session is live.

Total time from cookie paste to working session: under 2 minutes.

## Health checks

There is no dedicated health-check or `status` command. The recommended approach:

1. Run `list` and check the output.
2. A successful response contains `"status":true` in the JSON body. The CLI prints "Upcoming Meetings" or "No upcoming meetings."
3. Any auth failure triggers `is_auth_expired()` inside `zoom_authed`, which produces a clear error (see Troubleshooting below).

### Suggested periodic check

If operating zoom-cli as a long-running MCP server, run `list` on a schedule (e.g., every 30 minutes). If it fails with a session-expired error, credentials must be refreshed out-of-band.

## Normal shutdown

### MCP mode

The MCP process holds credentials in the filesystem, not in memory. Stopping the process is sufficient -- no cleanup is strictly required.

To revoke access immediately:

```bash
rm -f .raw_cookies .csrf_token
```

This prevents any further API calls until new credentials are provisioned.

### Interactive mode

Same as above. There is no `logout` command. Delete the credential files to revoke the session.

## Re-authentication in MCP (non-interactive) mode

When a session expires, `zoom_authed` calls `do_reauth()`. That function checks for an interactive terminal (`[[ -t 0 && -t 1 ]]`). MCP processes are never interactive, so reauth always fails with:

```
Session expired and not running interactively. Run: ./zoom-cli.sh login
```

**This is expected behavior.** To recover:

1. On an interactive machine, run `./zoom-cli.sh login` or repeat the manual cookie injection steps (Path B above).
2. The MCP server does not need to restart -- it reads `.raw_cookies` and `.csrf_token` from disk on every request.

## Debug mode

Set `ZOOM_DEBUG=1` to enable verbose output via `dbg()`. This prints raw HTTP response bodies truncated to 500 characters.

```bash
ZOOM_DEBUG=1 ./zoom-cli.sh list
```

**Security warning:** Debug output includes raw cookies, CSRF tokens, and full API responses. Do not enable in production logs or shared environments.

## Troubleshooting

### Decision tree

```
Command fails
  |
  |-- Output contains "No cookies"
  |     -> .raw_cookies file is missing.
  |        Fix: run set-cookies or login.
  |
  |-- Output contains "No CSRF token"
  |     -> .csrf_token file is missing.
  |        Fix: run refresh-csrf (requires .raw_cookies to exist first).
  |
  |-- Output contains "Session expired"
  |     -> Auth is invalid. One of three failure modes was detected (see below).
  |        Fix: re-provision credentials (login or set-cookies + refresh-csrf).
  |
  |-- Output contains "Failed to fetch meetings" (or similar)
  |     -> API returned status:false but not an auth error.
  |        Fix: enable ZOOM_DEBUG=1, inspect the raw response.
  |
  |-- Output contains "curl failed"
  |     -> Network issue. curl could not reach skyscanner.zoom.us.
  |        Fix: check VPN, DNS, proxy settings. Timeout is 15 seconds.
  |
  |-- "No upcoming meetings."
        -> This is a valid response. The account has no meetings in the next 3 months.
           Not an error.
```

### Three auth failure modes

`is_auth_expired()` (line 130 of `zoom-cli.sh`) detects these patterns:

| Mode | What the server returns | Pattern matched |
|------|------------------------|-----------------|
| JSON error | `{"errorCode": 201, "errorMessage": "User not login."}` | `errorCode":201` or `User not login` |
| SAML redirect | HTML containing a SAML form | `login.microsoftonline.com` or `SAMLRequest` |
| Error page | HTML with Zoom error title | `<title>Error - Zoom</title>` |

All three produce the same CLI output: "Session expired" followed by a reauth attempt (which fails in MCP mode).

**Distinguishing them** requires `ZOOM_DEBUG=1`:

- **JSON error**: You see a clean JSON object with `errorCode` and `errorMessage`.
- **SAML redirect**: The body starts with `<html>` and contains `SAMLRequest` or a Microsoft login URL. This usually means cookies expired and the server is redirecting to SSO.
- **Error page**: The body is HTML with `<title>Error - Zoom</title>`. This can indicate a server-side issue or an invalid endpoint.

### Empty list vs. auth failure

These two conditions look different in the CLI:

| Condition | API response | CLI output |
|-----------|-------------|------------|
| No meetings scheduled | `{"status":true, "result":{"totalRecords":0, "meetings":[]}}` | "No upcoming meetings." |
| Auth failure | `{"errorCode":201, ...}` or HTML redirect | "Session expired and not running interactively." |

The `cmd_list` function validates `status==True` before inspecting the `meetings` array. An empty list with `status==True` is a legitimate result, not an error.

### Common scenarios

**Cookies expire after a few hours**

Zoom web session cookies typically expire. When this happens, API calls return the "User not login" JSON error or a SAML redirect. Re-provision cookies using Path B.

**CSRF token becomes stale**

If only the CSRF token is stale (cookies still valid), API calls may fail with a non-201 error. Run `refresh-csrf` without replacing cookies:

```bash
./zoom-cli.sh refresh-csrf
```

**curl times out**

The default timeout is 15 seconds (`CURL_TIMEOUT=15` on line 19). If you are behind a slow VPN, this may not be enough. There is no CLI flag to override it; edit the variable in `zoom-cli.sh` if needed.

**meeting-template.json missing**

The `create` command requires `meeting-template.json` in the script directory. If the file is missing, the command exits with: "Missing meeting-template.json". This file is part of the repository and should not be deleted.

## File reference

| File | Purpose |
|------|---------|
| `zoom-cli.sh` | Main CLI script |
| `grab-cookies.mjs` | Playwright-based SSO cookie capture |
| `meeting-template.json` | JSON payload template for meeting creation |
| `.raw_cookies` | Session cookies (gitignored, created at runtime) |
| `.csrf_token` | CSRF token (gitignored, created at runtime) |

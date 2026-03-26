# zoom-cli — Agent Notes

Technical findings and patterns discovered while building and debugging the Zoom web CLI.

## Zoom Web API Architecture

Zoom's meeting management UI (`skyscanner.zoom.us/meeting`) is a **Vue SPA**. The HTML page is a shell — all data is loaded via XHR to REST endpoints. Scraping the HTML directly yields nothing useful.

### Key Endpoints

| Endpoint | Method | Content-Type | Purpose |
|---|---|---|---|
| `/csrf_js` | POST | text/plain | Returns `ZOOM-CSRFTOKEN:<value>` |
| `/rest/meeting/list` | POST | `application/x-www-form-urlencoded` | List meetings (paginated) |
| `/rest/meeting/view` | POST | `application/x-www-form-urlencoded` | View meeting details (`number=<id>`) |
| `/rest/meeting/save` | POST | `application/json` | Create or update a meeting |
| `/meeting/delete` | POST | `application/x-www-form-urlencoded` | Delete a meeting (`id=<id>`) |

**Note**: `/rest/meeting/end_ask` (which appears in older docs) returns 500 errors. The real delete endpoint is `/meeting/delete`.

### Required Headers

Every authenticated request must include:

```
Cookie: <full cookie string>
zoom-csrftoken: <token>                              # lowercase!
x-requested-with: XMLHttpRequest, OWASP CSRFGuard Project
Accept: application/json, text/plain, */*
User-Agent: <real browser UA string>
Referer: https://skyscanner.zoom.us/meeting
```

Critical gotchas:
- **`zoom-csrftoken`** must be **lowercase** — uppercase `ZOOM-CSRFTOKEN` is silently ignored by the API.
- **`x-requested-with`** must include both `XMLHttpRequest` and `OWASP CSRFGuard Project` (comma-separated). Missing this causes HTTP 405 or silent auth failures.
- **`Accept: text/html`** triggers error pages instead of JSON. Always use `application/json`.

### Session / Cookie Lifecycle

- Cookies come from SSO via Microsoft (`login.microsoftonline.com` SAML).
- Session cookies expire frequently (within hours of inactivity, not days).
- The CSRF token (`/csrf_js`) succeeds even with stale cookies — it's not a reliable indicator of session health.
- Playwright captures httpOnly cookies correctly via `context.cookies()`.
- After fresh login, the browser sometimes lands on a page other than `/meeting` (e.g., `/` or `/profile`). The `grab-cookies.mjs` `waitForURL` pattern must be broad enough to handle this: `/skyscanner\.zoom\.us(?!\/saml)/`.

## Meeting Create API (`/rest/meeting/save`)

### Payload Structure

The create/save endpoint accepts a **large JSON payload** (~50 top-level keys). The API rejects payloads missing required fields with a generic `"Invalid parameters."` error — no indication of which field is missing.

**Solution**: We maintain `meeting-template.json` with the full default payload captured from a real browser session, then override specific fields (topic, date, time, recurrence, invitees).

### Fields That Cause Silent Failures If Missing or Wrong

| Field | What happens if missing/wrong |
|---|---|
| `scheduleFor.value` | `"Invalid parameters."` — must be the user's Zoom ID |
| `enforceSignedIn.childParams.meetingAuthSelectedOption.value` | `"Invalid parameters."` — must include the org-specific auth option object |
| `meetingId.childParams.pmiNumber.value` | `"Invalid parameters."` — must be the user's PMI number |
| `passcode.childParams.meetingPasscode.value` | `"Invalid parameters."` if empty string (needs a real passcode or `false`) |
| `recurring` block (any part of it) | `"Invalid parameters."` — must be present even for non-recurring meetings |

### Recurring Meeting Format

Recurring meetings set `recurring.value = true` (not `null`). The recurrence details live in `recurring.childParams.recurring.value`:

```json
{
  "type": "WEEKLY",
  "endType": "END_DATETIME",
  "timezone": "Europe/London",
  "currentUserId": "<zoom_user_id>",
  "startTime": "03/28/2026 10:00",
  "endTime": "06/26/2026 23:59",
  "recurrenceValues": [
    {"type": "INTERVAL", "value": "1"},
    {"type": "BYDAY", "value": "7"}
  ]
}
```

Key details:
- **Day of week** uses `"BYDAY"` (not `"DAY_OF_WEEK"`) with **numeric values**: SU=1, MO=2, TU=3, WE=4, TH=5, FR=6, SA=7.
- **End date is required** — the API errors with `"convertRecurrenceToRRule don't have count or until"` if neither `endTime` nor a count is provided.
- **`recurringOccurs.value`** is an **array** of day strings: `["7"]` for Saturday, `["7","1"]` for Saturday+Sunday.
- Non-recurring meetings should keep the template's default `recurring` block intact (with `recurring.value = null` and the childParams structure). Setting it to `{value: null, childParams: null}` causes `"Invalid parameters."`.

### Invitee Format

```json
{
  "invitee": {
    "value": [
      {
        "custom": true,
        "displayName": "user@example.com",
        "email": "user@example.com",
        "uniqueKey": "user@example.com",
        "isEmail": true
      }
    ]
  }
}
```

### Create Response

```json
{
  "status": true,
  "result": {
    "mn": 99663712779,
    "joinLink": "https://skyscanner.zoom.us/j/99663712779",
    "mmeid": "E7LVFMjZTuC6OBVQ5zCsvQ",
    "url": "https://skyscanner.zoom.us/meeting/99663712779?meetingMasterEventId=..."
  }
}
```

The meeting number is in `result.mn`. The `mmeid` (meetingMasterEventId) is needed for some operations (e.g., viewing specific occurrences of recurring meetings).

## Meeting List API (`/rest/meeting/list`)

Form-encoded POST with params:
- `listType=upcoming` (or `previous`)
- `page=1`, `pageSize=50`
- `dateDuration=2026-03-25,2026-06-25` (optional date range)
- `isShowPAC=false`

Response groups meetings by date:

```json
{
  "result": {
    "totalRecords": 34,
    "meetings": [
      {
        "time": "Today",
        "list": [
          {
            "number": "94244974137",
            "topic": "Don / Rodrigo",
            "type": 8,
            "duration": 60,
            "schTimeF": "01:30 PM - 02:30 PM",
            "occurrenceTip": "Occurrence 13 of 110",
            "meetingMasterEventId": "SGIBpzqpTwSrs_rZYoK4iQ"
          }
        ]
      }
    ]
  }
}
```

Meeting `type` values: `2` = single scheduled, `8` = recurring.

## Meeting Delete API (`/meeting/delete`)

Form-encoded POST:
- `id=<meeting_number>` (the numeric meeting ID)
- `sendMail=false`
- `mailBody=` (empty)

Returns `{"status": true, "result": true}` on success.

## macOS Compatibility

BSD grep (macOS) does not support `-P` (Perl regex). All patterns must use:
- `grep -oE` (extended regex) — works on both macOS and Linux
- `sed -n` for lookbehind-like patterns
- `python3` for complex regex extraction

Also, `grep -qF "$needle"` fails on macOS if `$needle` starts with `--`. Always use `grep -qF -- "$needle"`.

## Playwright Cookie Capture

The `grab-cookies.mjs` script:
1. Launches visible Chromium (SSO requires user interaction)
2. Navigates to `/meeting` which triggers SAML redirect
3. Waits for URL to return to `zoom.us` (but NOT `/saml`)
4. Calls `context.cookies()` which includes httpOnly cookies
5. Writes raw cookie string to `.raw_cookies` and Netscape format to `cookies.txt`

The `login` CLI command chains this with `refresh-csrf` automatically.

## Testing Approach

Tests in `test-zoom-cli.sh` use:
- **Mock curl** via PATH injection — a temp script in `$MOCK_BIN/curl` that returns canned responses and logs call args
- **Mock curl sequences** — `setup_mock_curl_sequence` for commands that make multiple curl calls (e.g., create → view)
- **Temp directories** — each test gets its own dir with a copy of `zoom-cli.sh`, isolating cookie/CSRF files
- **No network** — all 140+ tests run offline

## Auto-Reauth on Session Expiry

All API-calling commands (`list`, `view`, `create`, `delete`, `update`) go through `zoom_authed`, a wrapper that:

1. Executes the request normally
2. Checks the response for auth failure indicators:
   - `"errorCode":201` / `"User not login."`
   - SAML redirect HTML (`login.microsoftonline.com`, `SAMLRequest`)
   - Zoom error page (`<title>Error - Zoom</title>`)
3. If expired and running in an **interactive terminal** (`-t 0 && -t 1`):
   - Automatically launches `grab-cookies.mjs` (Playwright browser for SSO)
   - Refreshes the CSRF token
   - Retries the original request once
4. If expired and **not interactive** (piped, cron, CI): prints error and exits

The `raw` debug command intentionally bypasses this — it returns whatever the API gives back.

**Note**: The CSRF endpoint (`/csrf_js`) returns a valid-looking token even with stale session cookies. It cannot be used as a session health check. Only actual API calls (like `/rest/meeting/list`) reveal expired sessions.

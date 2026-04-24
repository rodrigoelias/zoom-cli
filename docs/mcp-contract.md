# MCP Tool Contracts

Strict input/output contracts for all read-only MCP tools exposed by zoom-cli.

---

## Normalized Response Envelope

Every MCP tool response uses this envelope:

```json
{
  "ok": true,
  "data": { ... }
}
```

On failure:

```json
{
  "ok": false,
  "error": {
    "code": "AUTH_EXPIRED",
    "message": "Session expired. Re-run login.",
    "retryable": true
  }
}
```

### Fields

| Field             | Type    | Description                                        |
| ----------------- | ------- | -------------------------------------------------- |
| `ok`              | boolean | `true` on success, `false` on failure              |
| `data`            | object  | Present only when `ok` is `true`                   |
| `error`           | object  | Present only when `ok` is `false`                  |
| `error.code`      | string  | Machine-readable error code (see Error Taxonomy)   |
| `error.message`   | string  | Human-readable explanation                         |
| `error.retryable` | boolean | Whether the caller should retry after intervention |

---

## Error Taxonomy

| Code             | Meaning                                              | Retryable | Trigger in `zoom-cli.sh`                                                                                         |
| ---------------- | ---------------------------------------------------- | --------- | ---------------------------------------------------------------------------------------------------------------- |
| `AUTH_EXPIRED`   | Session cookies or CSRF token are stale/invalid       | yes       | `is_auth_expired()` (line 130): `errorCode:201`, SAML redirect HTML, `<title>Error - Zoom</title>` page         |
| `BAD_INPUT`      | Caller provided invalid or missing parameters         | no        | MCP wrapper validates inputs before calling zoom-cli                                                             |
| `ZOOM_API_ERROR` | Zoom returned `status: false` with a non-auth error   | no        | `status == false` + `errorMessage` where `is_auth_expired()` returns false (e.g. `errorCode: 400`, `-1`)         |
| `INTERNAL_ERROR` | Unexpected failure (curl timeout, unparseable body)   | no        | Non-JSON response, curl exit != 0, python parse failure                                                          |

### Auth Failure Detection (`is_auth_expired`, lines 130-142)

The following response patterns are classified as `AUTH_EXPIRED`:

1. JSON containing `"errorCode":201` or `"User not login"`
2. HTML containing `login.microsoftonline.com` or `SAMLRequest` (SAML redirect)
3. HTML containing `<title>Error - Zoom</title>`

All other `status: false` responses map to `ZOOM_API_ERROR`.

---

## `zoom_list`

List upcoming or previous meetings with optional date filtering.

### Input Schema

```json
{
  "type": "object",
  "properties": {
    "listType": {
      "type": "string",
      "enum": ["upcoming", "previous"],
      "default": "upcoming",
      "description": "Whether to list upcoming or past meetings."
    },
    "page": {
      "type": "integer",
      "minimum": 1,
      "default": 1,
      "description": "Page number for pagination."
    },
    "pageSize": {
      "type": "integer",
      "minimum": 1,
      "maximum": 50,
      "default": 50,
      "description": "Number of results per page."
    },
    "startDate": {
      "type": "string",
      "pattern": "^\\d{4}-\\d{2}-\\d{2}$",
      "description": "Start of date range (YYYY-MM-DD). Optional."
    },
    "endDate": {
      "type": "string",
      "pattern": "^\\d{4}-\\d{2}-\\d{2}$",
      "description": "End of date range (YYYY-MM-DD). Optional."
    }
  },
  "required": [],
  "additionalProperties": false
}
```

### Mapping to Zoom API

The MCP wrapper translates inputs to the form-encoded POST `zoom_post "/rest/meeting/list"` (line 289):

| MCP input    | Zoom form field    | Notes                                                |
| ------------ | ------------------ | ---------------------------------------------------- |
| `listType`   | `listType`         | Passed directly                                      |
| `page`       | `page`             | Passed directly                                      |
| `pageSize`   | `pageSize`         | Passed directly                                      |
| `startDate`  | `dateDuration`     | Combined as `startDate,endDate`                      |
| `endDate`    | `dateDuration`     | Combined as `startDate,endDate`                      |
| (none)       | `isShowPAC=false`  | Always sent (line 286); hides PAC phone audio meetings |

### Success Response

```json
{
  "ok": true,
  "data": {
    "totalRecords": 2,
    "meetings": [
      {
        "date": "Today",
        "items": [
          {
            "meetingId": "12345678901",
            "meetingIdFormatted": "123 4567 8901",
            "topic": "Daily Standup",
            "timeRange": "09:00 AM - 09:30 AM",
            "duration": 30,
            "isRecurring": true,
            "occurrenceInfo": "Occurrence 1 of 5"
          }
        ]
      },
      {
        "date": "Wed, Apr 1",
        "items": [
          {
            "meetingId": "98765432109",
            "meetingIdFormatted": "987 6543 2109",
            "topic": "Team Retro",
            "timeRange": "02:00 PM - 03:00 PM",
            "duration": 60,
            "isRecurring": false,
            "occurrenceInfo": null
          }
        ]
      }
    ]
  }
}
```

### Field Mapping from Zoom API

The raw Zoom response nests meetings in `result.meetings[]`, where each entry is a date group:

| MCP output field   | Zoom raw field                  | Transformation                                  |
| ------------------ | ------------------------------- | ----------------------------------------------- |
| `date`             | `meetings[].time`              | Passed through (e.g. `"Today"`, `"Wed, Apr 1"`) |
| `meetingId`        | `meetings[].list[].number`     | String                                          |
| `meetingIdFormatted` | `meetings[].list[].numberF`  | Human-readable with spaces                      |
| `topic`            | `meetings[].list[].topic`      | Passed through                                  |
| `timeRange`        | `meetings[].list[].schTimeF`   | Passed through                                  |
| `duration`         | `meetings[].list[].duration`   | Integer (minutes)                               |
| `isRecurring`      | `meetings[].list[].type`       | `true` when `type == 8`, `false` otherwise      |
| `occurrenceInfo`   | `meetings[].list[].occurrenceTip` | `null` when empty string                     |

### Error Response Examples

**Auth expired:**
```json
{
  "ok": false,
  "error": {
    "code": "AUTH_EXPIRED",
    "message": "Session expired. Re-run login.",
    "retryable": true
  }
}
```

**API error:**
```json
{
  "ok": false,
  "error": {
    "code": "ZOOM_API_ERROR",
    "message": "Unauthorized",
    "retryable": false
  }
}
```

---

## `zoom_view`

Retrieve details for a single meeting.

### Input Schema

```json
{
  "type": "object",
  "properties": {
    "meetingId": {
      "type": "string",
      "pattern": "^[0-9]+$",
      "description": "Numeric meeting ID (e.g. '94244974137')."
    }
  },
  "required": ["meetingId"],
  "additionalProperties": false
}
```

### Mapping to Zoom API

Translates to the form-encoded POST `zoom_post "/rest/meeting/view" "number=${meetingId}"` (line 351).

### The `val()` Unwrapper Pattern

The Zoom `/rest/meeting/view` API wraps most fields in a `{"value": ...}` object. The MCP wrapper must unwrap these before returning data.

From `zoom-cli.sh` (lines 374-377):

```python
def val(obj):
    if isinstance(obj, dict) and 'value' in obj:
        return obj['value']
    return obj
```

**Example raw vs unwrapped:**

| Raw Zoom field                 | After `val()`         |
| ------------------------------ | --------------------- |
| `{"value": "Weekly Sync"}`     | `"Weekly Sync"`       |
| `{"value": 60}`                | `60`                  |
| `{"value": false}`             | `false`               |
| `"plain string"`               | `"plain string"`      |

Fields that use the `val()` wrapper: `topic`, `startDate`, `startTime`, `startTime2`, `duration`, `timezone`, `recurring`.

Fields that do NOT use it (live at `result` level): `joinUrl`.

### Success Response

```json
{
  "ok": true,
  "data": {
    "topic": "Weekly Sync",
    "meetingId": "12345678901",
    "startDate": "04/01/2026",
    "startTime": "10:00",
    "startTimePeriod": "AM",
    "duration": 60,
    "timezone": "Europe/London",
    "isRecurring": false,
    "recurrenceType": null,
    "passcode": "abc123",
    "joinUrl": "https://skyscanner.zoom.us/j/12345678901",
    "invitees": ["alice@test.com", "bob@test.com"]
  }
}
```

### Field Mapping from Zoom API

| MCP output field   | Zoom raw path                                          | Transformation                                             |
| ------------------ | ------------------------------------------------------ | ---------------------------------------------------------- |
| `topic`            | `result.meeting.topic`                                 | `val()` unwrap                                             |
| `meetingId`        | Input `meetingId` echoed back                          | --                                                         |
| `startDate`        | `result.meeting.startDate`                             | `val()` unwrap                                             |
| `startTime`        | `result.meeting.startTime`                             | `val()` unwrap                                             |
| `startTimePeriod`  | `result.meeting.startTime2`                            | `val()` unwrap (AM/PM)                                     |
| `duration`         | `result.meeting.duration`                              | `val()` unwrap; integer (minutes)                          |
| `timezone`         | `result.meeting.timezone`                              | `val()` unwrap                                             |
| `isRecurring`      | `result.meeting.recurring`                             | `val()` unwrap; boolean                                    |
| `recurrenceType`   | `result.meeting.recurring.childParams.recurring.value.type` | Present only when `isRecurring == true`; `null` otherwise |
| `passcode`         | `result.meeting.passcode.childParams.meetingPasscode`  | `val()` unwrap; `null` if `childParams` is null/absent     |
| `joinUrl`          | `result.joinUrl` or `result.join_url`                  | Not inside `meeting`; lives at `result` level (line 404)   |
| `invitees`         | `result.meeting.invitee`                               | `val()` unwrap then extract `.email` or `.displayName`     |

### Error Response Examples

**Bad input (missing meeting ID):**
```json
{
  "ok": false,
  "error": {
    "code": "BAD_INPUT",
    "message": "meetingId is required and must be numeric.",
    "retryable": false
  }
}
```

**Meeting not found:**
```json
{
  "ok": false,
  "error": {
    "code": "ZOOM_API_ERROR",
    "message": "Meeting not found.",
    "retryable": false
  }
}
```

**Non-JSON response from Zoom:**
```json
{
  "ok": false,
  "error": {
    "code": "INTERNAL_ERROR",
    "message": "Unexpected response format from Zoom API.",
    "retryable": false
  }
}
```

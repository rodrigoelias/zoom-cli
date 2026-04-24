# MCP Write-Tool Rollout Plan

Controlled rollout of write capabilities (create, update, delete) for the zoom-cli MCP wrapper.

## Rollout Stages

### Stage 1: `create` (lowest risk)

**Why first:** Creating a meeting is additive. It does not modify or destroy existing data. Worst case is an orphaned meeting that can be manually deleted.

**Gate:** None beyond standard auth. The MCP wrapper exposes `zoom_create` and requires all mandatory fields (topic, date, time). Missing fields produce `"Invalid parameters."` from Zoom's API, which is safe.

**Payload note:** `meeting-template.json` contains ~50 top-level keys with nested `childParams`. The `cmd_create` function fills defaults for most fields; only `topic`, `date`, `time`, `duration`, and `timezone` are user-supplied. The template is not exposed to MCP callers directly.

**Graduation criteria:** 10 successful creates with no unexpected side effects. Verify via `cmd_list` that created meetings appear correctly.

### Stage 2: `update` (moderate risk)

**Why second:** Updates modify existing meetings but do not destroy them. The original state can often be recovered by updating again.

**Gate:** Before exposing `update`, require:
1. **Existence check** -- call `cmd_view` on the meeting ID and confirm it exists before allowing the update.
2. **Field allowlist** -- only permit updates to: `topic`, `date`, `time`, `ampm`, `duration_hr`, `duration_min`. Do not allow arbitrary payload passthrough.
3. **Dry-run mode** -- during initial rollout, log the intended change and return it for confirmation before executing. The MCP tool should return a preview and require a second call with `confirm=true`.

**Graduation criteria:** 20 successful updates across at least 5 distinct meetings with no data corruption. Spot-check via `cmd_view` after each update.

### Stage 3: `delete` (highest risk)

**Why last:** Deletion is irreversible. A deleted meeting cannot be recovered via the Zoom web API.

**Gate:** Before exposing `delete`, require:
1. **Existence check** -- call `cmd_view` to confirm the meeting exists and return its details.
2. **Confirmation gate** -- the MCP tool must use a two-step flow:
   - Step 1: `delete_request(meeting_id)` returns meeting details and a confirmation token (random UUID, valid for 60 seconds).
   - Step 2: `delete_confirm(meeting_id, token)` executes the deletion.
3. **Rate limit** -- maximum 3 deletions per 5-minute window. Reject further deletes with an explicit error.

**Graduation criteria:** 10 successful deletions with confirmation flow working correctly. Zero accidental deletions during testing.

## Retry-After-Reauth Decision

**Decision: Allow one reauth-and-retry for all write operations, including delete.**

`zoom_authed()` (line 162) wraps all commands. If the API returns `errorCode:201` (session expired), it re-authenticates and retries once. The key question is whether this retry is safe for destructive operations.

**Analysis:** An `errorCode:201` response means the session was invalid *before* the request was processed. Zoom rejects the entire request; no partial execution occurs. The same applies to SAMLRequest redirects -- the server never processed the write. Therefore the retry after reauth is the first actual attempt at the operation, not a duplicate.

**No code changes needed.** The existing `zoom_authed` behavior is correct for all write operations.

**Caveat:** If Zoom ever changes behavior to partially process requests before returning auth errors, this decision must be revisited. The MCP audit log (see below) will capture retry events for monitoring.

## Audit Requirements for Write Calls

All write operations must produce structured audit records. These go to stderr (captured by MCP transport) and optionally to a log file.

### Audit record format

```json
{
  "timestamp": "2026-04-24T14:30:00Z",
  "operation": "create|update|delete",
  "meeting_id": "12345678",
  "caller": "mcp-client-id",
  "parameters": {"topic": "...", "date": "..."},
  "result": "success|failure",
  "error": null,
  "retried_after_reauth": false
}
```

### What to log

| Event | Required Fields |
|---|---|
| Write attempt | timestamp, operation, meeting_id (if applicable), parameters |
| Write success | all above + result=success |
| Write failure | all above + result=failure, error message |
| Reauth retry | all above + retried_after_reauth=true |
| Confirmation issued (delete) | timestamp, operation=delete, meeting_id, token (hashed) |
| Confirmation used (delete) | timestamp, operation=delete_confirm, meeting_id |
| Rate limit hit (delete) | timestamp, operation=delete, meeting_id, result=rate_limited |

### Interception point

Audit logging should be added at the `zoom_post` and `zoom_post_json` call sites, not at the `cmd_*` dispatch level. This ensures that:
- Retries are captured (they go through `zoom_post`/`zoom_post_json` again).
- Direct `raw` command usage is also audited.
- The audit layer cannot be bypassed by adding new `cmd_*` functions.

Concretely, wrap `zoom_post` and `zoom_post_json` with audit-aware versions:

```bash
zoom_post_audited() {
  local path="$1"
  audit_log "write_attempt" "$path" "$@"
  local result
  result=$(zoom_post "$@")
  local rc=$?
  audit_log "write_result" "$path" "$rc" "${result:0:200}"
  printf '%s' "$result"
  return $rc
}
```

Then update `cmd_delete` and `cmd_update` to call `zoom_post_audited` instead of `zoom_post`.

## Rollback Strategy

### Immediate rollback (minutes)

If a write tool causes problems in production:

1. **Disable at MCP layer** -- remove or comment out the tool registration in the MCP wrapper. No code deploy needed if the wrapper reads tool definitions from a config file.
2. **Feature flag** -- if implemented, set `ZOOM_CLI_WRITES_ENABLED=false` in the environment. The MCP wrapper should check this before dispatching any write operation.

```bash
# Add to the top of cmd_create, cmd_update, cmd_delete:
if [[ "${ZOOM_CLI_WRITES_ENABLED:-true}" != "true" ]]; then
  err "Write operations are disabled."
  exit 1
fi
```

### Meeting-level rollback (minutes to hours)

- **Accidental create:** Delete the meeting via `cmd_delete` or the Zoom web UI.
- **Accidental update:** Re-update with correct values. If original values are unknown, check audit log for the `parameters` field of the prior successful update or the `cmd_view` snapshot taken before the update.
- **Accidental delete:** No API recovery. Must recreate the meeting manually. This is why delete has the strongest gating (confirmation + rate limit).

### Stage rollback (hours)

If an entire stage proves problematic:

1. Revert the MCP tool registration for that stage.
2. Keep the underlying `cmd_*` functions intact (they remain usable via CLI).
3. File a GitHub issue documenting what went wrong.
4. Do not proceed to the next stage until the issue is resolved.

### Data preservation

Before any `update` or `delete`, the MCP wrapper should call `cmd_view` and cache the full meeting state in the audit log. This provides a recovery record:

```json
{
  "timestamp": "2026-04-24T14:29:59Z",
  "operation": "pre_write_snapshot",
  "meeting_id": "12345678",
  "snapshot": { "topic": "...", "startTime": "...", ... }
}
```

## Test Coverage Alignment

Existing tests that validate write failure paths:

| Test | Line | What it covers |
|---|---|---|
| `test_delete_api_error` | 470 | Delete returns `errorCode:404` |
| `test_update_api_error` | 740 | Update returns `errorCode:403` |
| `test_create_*` series | 1142+ | Various creation scenarios |

Additional tests needed for rollout:

| Test | Purpose |
|---|---|
| `test_delete_confirmation_required` | Delete without confirmation token is rejected |
| `test_delete_rate_limit` | Fourth delete in 5 minutes is rejected |
| `test_update_field_allowlist` | Update with disallowed field is rejected |
| `test_write_disabled_flag` | All writes rejected when `ZOOM_CLI_WRITES_ENABLED=false` |
| `test_write_audit_log` | Audit record emitted for each write operation |
| `test_pre_write_snapshot` | `cmd_view` called before update/delete |

The existing `get_curl_calls()` helper in the test suite can verify that the correct endpoints and payloads are sent, serving as an audit analog during testing.

## Summary

| Stage | Operation | Risk | Gate | Graduation |
|---|---|---|---|---|
| 1 | create | Low | Standard auth | 10 successful creates |
| 2 | update | Moderate | Existence check + field allowlist + dry-run | 20 updates across 5+ meetings |
| 3 | delete | High | Existence check + confirmation token + rate limit | 10 deletions, zero accidental |

**Retry-after-reauth:** Allowed for all operations. `errorCode:201` means the request was never processed, so the retry is the first real attempt.

**Rollback speed:** Seconds (feature flag) to minutes (MCP tool deregistration).

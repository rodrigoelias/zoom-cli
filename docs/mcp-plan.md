# MCP Wrapper -- Phase 0: Scope and Security Guardrails

## 1. Initial Tool Set (Read-Only)

The MCP wrapper exposes exactly two tools in the first release:

| MCP Tool    | CLI Function       | API Endpoint             | HTTP Method   |
|-------------|--------------------|--------------------------|---------------|
| `zoom_list` | `cmd_list` (L274)  | `POST /rest/meeting/list`| form-encoded  |
| `zoom_view` | `cmd_view` (L346)  | `POST /rest/meeting/view`| form-encoded  |

Both tools are **read-only** -- they fetch data and return structured JSON. No meeting state is modified.

## 2. Deferred Operations

The following operations are explicitly **out of scope** for the initial MCP release:

| Operation | CLI Function        | API Endpoint                              | Rationale                                         |
|-----------|---------------------|-------------------------------------------|----------------------------------------------------|
| Create    | `cmd_create` (L428) | `POST /rest/meeting/save`                 | Mutating; requires careful input validation         |
| Update    | `cmd_update` (L665) | `POST /rest/meeting/save?meetingNumber=`  | Mutating; partial-update semantics are complex      |
| Delete    | `cmd_delete` (L648) | `POST /meeting/delete`                    | Destructive; no undo; high-risk for automated agents|

These will be considered for a future phase once the read-only wrapper is stable and the security model has been validated in practice.

## 3. Excluded Commands

### `raw` (L709)

The `raw` subcommand (`cmd_raw`) passes arbitrary HTTP methods, paths, and POST parameters directly to the Zoom API with no restrictions. It **must not** be exposed through MCP because:

- It bypasses all input validation.
- It can reach any Zoom web endpoint, including destructive or administrative ones.
- It was designed as a developer debugging tool, not a user-facing feature.

### `ZOOM_DEBUG=1` / `dbg()` (L26)

When `ZOOM_DEBUG=1` is set, the `dbg()` function emits raw API response bodies to stderr. In MCP mode this must be disabled because:

- Response bodies may contain session tokens, passcodes, or PII.
- MCP transports (stdio) treat stderr as a diagnostic channel that may be logged or displayed to end users.
- There is no mechanism to redact sensitive fields before output.

**Constraint:** The MCP wrapper must never set `ZOOM_DEBUG=1` and must not propagate it from the environment to the underlying CLI process.

## 4. Security Constraints

### 4.1 No Secret Persistence to Disk in MCP Mode

The CLI stores cookies in `.raw_cookies` and the CSRF token in `.csrf_token` (L17-18). In MCP mode:

- Secrets (cookie string, CSRF token) must be passed at session startup and held **only in memory** (environment variables or in-process state).
- The MCP wrapper must **never** write `.raw_cookies` or `.csrf_token` to disk.
- If the wrapper delegates to `zoom-cli.sh`, it must override `RAW_COOKIE_FILE` and `CSRF_FILE` to use temporary, process-scoped paths (e.g., `/dev/fd/` or a `mktemp` file cleaned up on exit).

### 4.2 No Secret Values in stdout/stderr

Secrets must never appear in MCP tool output or diagnostic logs:

- The cookie string embedded in curl headers (`zoom_get` L183, `zoom_post` L200) must not be logged.
- CSRF tokens must not appear in tool responses.
- Error messages that include raw API responses must be truncated/redacted before returning to the MCP client.

### 4.3 Session Tied to Process / Terminal Lifetime

- The MCP session inherits its authentication from the process that starts it (e.g., via environment variables `ZOOM_COOKIES` and `ZOOM_CSRF`).
- When the MCP server process exits, the session credentials are gone -- there is nothing on disk to leak.
- There is no background refresh, no token rotation, and no persistent session store.
- If the session expires mid-use, the MCP tool returns a clear error; it does **not** attempt interactive re-authentication (`do_reauth` at L145 launches a browser, which is not viable in MCP mode).

## 5. Secret Exposure Points (Inventory)

| Location                        | Risk                                         | Mitigation                                      |
|---------------------------------|----------------------------------------------|-------------------------------------------------|
| `dbg()` (L26)                   | Dumps raw response bodies to stderr          | Never set `ZOOM_DEBUG=1` in MCP mode            |
| `zoom_get` / `zoom_post` (L183, L200) | Cookie string in curl `-H` flag       | Do not log curl commands; suppress `-v` output   |
| `cmd_raw` (L709)                | Unrestricted API access                      | Exclude from MCP entirely                       |
| `.raw_cookies` / `.csrf_token` (L17-18) | Secrets persisted to disk             | Use in-memory or ephemeral paths in MCP mode    |
| `err()` calls with `${response:0:500}` | May include tokens in error output   | Redact or omit raw responses in MCP tool output |

## 6. Acceptance Criteria

- [ ] `docs/mcp-plan.md` exists and covers scope, constraints, deferrals, and exclusions.
- [ ] Only `zoom_list` and `zoom_view` are in the initial tool set.
- [ ] `create`, `update`, and `delete` are deferred with documented rationale.
- [ ] `ZOOM_DEBUG` is explicitly excluded from MCP mode.
- [ ] `raw` command is explicitly excluded from MCP mode.
- [ ] No-secret-persistence constraint is documented.
- [ ] No-secret-in-stdout/stderr constraint is documented.
- [ ] Session-lifetime constraint is documented.

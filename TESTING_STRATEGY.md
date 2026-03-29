# Testing Strategy: Web-to-CLI for Zoom

This document outlines the comprehensive testing approach for building a Zoom CLI via Okta SSO, following the web-to-cli skill methodology.

## Testing Pyramid

```
                    ▲
                   / \
                  /   \  E2E Tests (real Zoom API)
                 /     \
                /-------\
               /         \
              / Integration\ Tests (mocked HTTP)
             /             \
            /---------------\
           /                 \
          /    Unit Tests     \  (fast, isolated)
         /      (fastest)     \
        /_____________________\
```

## Phase 1: Unit Tests (Fast, No Network) ✅ DONE

These tests run instantly, require zero credentials, and test core logic in isolation.

### Tests Included

**1. Cookie Management** (`tests/cookies.test.ts`)
- ✅ Parse raw cookie strings
- ✅ Serialize to raw format (HTTP header compatible)
- ✅ Netscape format roundtrip (curl/wget compatible)
- ✅ Cookie validation (detect Zoom cookies)
- ✅ Cookie merging and updates

**2. HTTP Client** (`tests/http-client.test.ts`)
- ✅ GET/POST/PUT/DELETE requests
- ✅ Header injection (CSRF, cookies)
- ✅ Auth expiry detection (401, 403, JSON error codes, SAML redirects)
- ✅ Error handling (API errors, network errors)
- ✅ Cookie and CSRF token management

**3. Zoom API Models** (`tests/zoom-api.test.ts`)
- ✅ Meeting object validation
- ✅ CreateMeetingRequest validation
- ✅ API error response parsing
- ✅ Recurrence validation

### Run Unit Tests

```bash
npm test
npm run test:coverage    # With coverage report
npm run test:watch      # Watch mode
```

### Coverage Expectations

- **Cookies**: 100% coverage (all edge cases)
- **HTTP Client**: 95%+ coverage (auth detection, errors)
- **API Models**: 100% coverage (validation logic)

---

## Phase 2: Offline Integration Tests (Mocked HTTP)

These tests verify complete workflows **without network calls** by mocking axios/curl.

### Test Structure

Each offline test:
1. **Mocks the HTTP layer** (axios/curl responses)
2. **Simulates real API responses** (from captured requests)
3. **Verifies correct behavior** (cookies updated, errors handled, etc.)
4. **Asserts on HTTP calls** (correct endpoint, headers, payload)

### Tests to Implement

**Auth & Session** (`tests/offline/auth.test.ts`)
- [ ] Cookie capture flow (mock Playwright)
- [ ] Login via Okta (mock SSO redirect)
- [ ] MFA handling (if required)
- [ ] CSRF token extraction from responses
- [ ] Session refresh on expiry

**API Operations** (`tests/offline/meetings.test.ts`)
- [ ] List meetings (GET `/v2/users/me/meetings`)
- [ ] Get meeting details (GET `/v2/meetings/{meetingId}`)
- [ ] Create meeting (POST `/v2/users/me/meetings`)
- [ ] Update meeting (PUT `/v2/meetings/{meetingId}`)
- [ ] Delete meeting (DELETE `/v2/meetings/{meetingId}`)
- [ ] Error responses for each operation

**CLI Interface** (`tests/offline/cli.test.ts`)
- [ ] Command parsing (`zoom meetings list`)
- [ ] Help output (`zoom --help`)
- [ ] Flag validation (`zoom meetings create --topic "Meeting"`)
- [ ] Error messages for missing arguments
- [ ] Output formatting (JSON, table, CSV)

**Payload Correctness** (`tests/offline/payloads.test.ts`)
- [ ] Meeting creation payload matches API expectations
- [ ] Field mapping (CLI args → API fields)
- [ ] Date/time format conversion
- [ ] Timezone handling
- [ ] Recurrence template expansion

---

## Phase 3: E2E Tests (Real Zoom API) 🔐

These tests run **against the actual Zoom API** with real credentials.

### Prerequisites

```bash
# Set up credentials (from Okta)
export ZOOM_COOKIES="..."  # From npm run capture-cookies
export ZOOM_CSRF_TOKEN="..." # From api-discovery

# Or store in .env
ZOOM_CREDENTIALS_FILE=".cookies/.raw_cookies"
```

### E2E Test Suite

**Real API Tests** (`tests/e2e/real-api.test.ts`)
- [ ] Authenticate (login via Okta, capture cookies)
- [ ] List real meetings
- [ ] Get meeting details
- [ ] Create test meeting
- [ ] Update test meeting
- [ ] Delete test meeting
- [ ] Verify cleanup

### Run E2E Tests

```bash
# Requires valid ZOOM_COOKIES env var
npm run test:e2e

# With debug output
DEBUG=zoom-cli:* npm run test:e2e
```

---

## Phase 4: Behavior-Driven Tests

These use Gherkin syntax to verify user-facing behavior.

### Example: List Meetings

```gherkin
Feature: Zoom CLI - List Meetings
  As a user
  I want to list my Zoom meetings from the CLI
  So I can see upcoming meetings without opening Zoom

  Scenario: List upcoming meetings
    Given I am authenticated with Zoom
    When I run "zoom meetings list --upcoming"
    Then I see a table of meetings
    And the table includes: topic, start time, duration, join URL

  Scenario: Filter by date range
    Given I am authenticated with Zoom
    When I run "zoom meetings list --from 2024-04-01 --to 2024-04-30"
    Then I see only meetings in that date range

  Scenario: Export as JSON
    Given I am authenticated with Zoom
    When I run "zoom meetings list --format json"
    Then I see valid JSON output
    And the JSON contains all meeting fields
```

---

## Test Checklist: By Phase

### Phase 1: Session Capture
- [ ] Cookie parsing (raw, Netscape)
- [ ] Okta SSO simulation (mocked)
- [ ] MFA handling (if required)
- [ ] Cookie validation (required cookies present)
- [ ] Cookie persistence (read/write files)
- [ ] Multiple auth methods (if supported)

### Phase 2: API Discovery
- [ ] Request sniffing (capture headers, body)
- [ ] Response sniffing (capture status, body)
- [ ] Endpoint catalog generation
- [ ] CSRF token extraction (from response)
- [ ] Error response detection
- [ ] Session expiry detection

### Phase 3: Payload Extraction
- [ ] Field format mapping (dates, enums, booleans)
- [ ] Template creation (meeting-template.json)
- [ ] Payload validation (required fields)
- [ ] Edge case handling (max length, special chars)
- [ ] API payload roundtrip (POST → GET → compare)

### Phase 4: CLI Implementation
- [ ] Command parsing (subcommands, flags, args)
- [ ] Help text and examples
- [ ] Output formatting (JSON, table, CSV)
- [ ] Error messages (clear, actionable)
- [ ] Progress indicators
- [ ] Pagination handling

### Phase 5: Testing
- [ ] Unit tests (all utilities, no network)
- [ ] Offline integration tests (mocked HTTP)
- [ ] E2E tests (real Zoom API, requires credentials)
- [ ] Edge cases (session expiry, network errors, invalid input)
- [ ] macOS compatibility (grep, date, etc.)

### Phase 6: Documentation
- [ ] `agents.md` (API catalog for Claude)
- [ ] `API-DISCOVERY.md` (findings from network sniffing)
- [ ] `TESTING.md` (this file)
- [ ] `README.md` (user guide)
- [ ] Template files committed and annotated

---

## Running Tests at Each Phase

```bash
# Phase 1: Cookie utilities
npm test -- cookies.test.ts

# Phase 2: HTTP client
npm test -- http-client.test.ts

# Phase 3: API models
npm test -- zoom-api.test.ts

# All unit tests
npm test

# Unit tests + coverage
npm run test:coverage

# Watch mode (for development)
npm run test:watch

# Offline integration tests (when implemented)
npm test -- offline/

# E2E tests (requires credentials)
npm run test:e2e
```

---

## Coverage Goals

| Phase | Component | Target | Rationale |
|-------|-----------|--------|-----------|
| 1 | Cookies | 100% | Foundation; must be bulletproof |
| 2 | HTTP Client | 95%+ | Core logic; error paths critical |
| 3 | API Models | 100% | Validation; must catch bad data |
| 4 | CLI | 80% | User-facing; coverage needed for common paths |
| Overall | Integration | 70%+ | Full workflow coverage |

---

## Test Data & Fixtures

All test data is committed in `tests/fixtures/`:

```
tests/
├── fixtures/
│   ├── cookies/
│   │   ├── valid.json         # Full cookie set
│   │   ├── expired.json       # Expired cookies
│   │   └── malformed.json     # Bad cookie strings
│   ├── requests/
│   │   ├── list-meetings.json
│   │   ├── create-meeting.json
│   │   └── error-responses.json
│   └── responses/
│       ├── meeting-list.json
│       ├── meeting-detail.json
│       └── meeting-created.json
```

---

## Continuous Integration

### GitHub Actions Workflow

```yaml
name: Test Suite

on: [push, pull_request]

jobs:
  unit-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - uses: actions/setup-node@v3
        with:
          node-version: '18'
      - run: npm ci
      - run: npm run lint
      - run: npm test -- --coverage
      - run: npm run build

  offline-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - uses: actions/setup-node@v3
      - run: npm ci
      - run: npm test -- offline/

  e2e-tests:
    runs-on: ubuntu-latest
    if: github.event_name == 'pull_request' && contains(github.head_ref, 'api-test')
    steps:
      - uses: actions/checkout@v3
      - uses: actions/setup-node@v3
      - run: npm ci
      - run: npm run test:e2e
    env:
      ZOOM_CREDENTIALS_FILE: ${{ secrets.ZOOM_CREDENTIALS_FILE }}
```

---

## Troubleshooting Tests

### Common Issues

**"No cookies found" error**
- Run: `npm run capture-cookies`
- Ensure you complete Okta login in the browser

**"Auth expired" error in tests**
- Cookies may have expired
- Re-capture: `npm run capture-cookies`
- Or refresh in tests: implement auto-reauth

**Mocked HTTP tests failing**
- Check that mock response matches expected API format
- Verify error codes match Zoom's actual responses
- Use `tests/fixtures/` for reference

**E2E tests timeout**
- Increase timeout: `jest.setTimeout(10000)`
- Check network connectivity
- Verify Zoom API is accessible

---

## Next Steps

1. ✅ **Phase 1-3 unit tests** — Complete now
2. [ ] **Implement offline integration tests** — Mock HTTP responses
3. [ ] **Set up E2E test harness** — Real API calls
4. [ ] **Add CI/CD pipeline** — GitHub Actions
5. [ ] **Document test results** — Coverage reports

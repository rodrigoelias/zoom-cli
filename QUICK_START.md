# Zoom CLI - Quick Start

## 30-Second Setup

```bash
# 1. Install
git clone <repo> zoom-cli && cd zoom-cli && npm install

# 2. Run tests (verify everything works)
npm test

# 3. Capture cookies (interactive — you login to Zoom)
npm run capture-cookies

# 4. Done! Cookies saved to .cookies/.raw_cookies
```

---

## What's Happening?

```
Your Browser (Playwright)
    ↓
Open zoom.us
    ↓
You see Okta login page
    ↓
You complete SSO + MFA
    ↓
Script captures cookies automatically
    ↓
.cookies/.raw_cookies ← ready to use
```

---

## Test Everything Works

```bash
npm test              # Should see: "45 passed ✅"
npm run test:coverage # With coverage report
```

---

## Next: Discover API

```bash
npm run sniff-api
# Browser opens → navigate Zoom.us → API calls captured
# Ctrl+C when done
# Results: docs/api-discovery.json
```

---

## Project Structure

```
zoom-cli/
├── src/                    # Utilities (cookies, HTTP, API models)
├── tests/                  # All tests (45 tests, all passing)
├── scripts/                # Discovery tools (capture-cookies, sniff-api)
├── docs/                   # Generated API catalog
├── README.md               # Full guide
├── TESTING_STRATEGY.md     # Test plan
└── PROJECT_STATUS.md       # Current progress
```

---

## Key Commands

```bash
npm test                 # Run all tests (45/45 passing)
npm run test:watch      # Watch mode
npm run test:coverage   # Coverage report
npm run capture-cookies # Get authenticated session (interactive)
npm run sniff-api       # Discover API endpoints (interactive)
npm run build           # Compile TypeScript
npm run lint            # Check for errors
```

---

## What's Done ✅

- [x] Phase 1: Cookie capture (Okta SSO)
- [x] Phase 2: HTTP client + auth detection
- [x] Phase 2: API models
- [x] Phase 2: Comprehensive tests (45 passing)
- [x] Documentation

## What's Next 🔲

- [ ] Phase 2b: Run API discovery (`npm run sniff-api`)
- [ ] Phase 3: Extract payloads + templates
- [ ] Phase 4: Build CLI commands
- [ ] Phase 5: E2E testing
- [ ] Phase 6: Final docs

---

## Common Issues

### "No cookies found" when running tests
- Tests don't need real cookies (they're mocked)
- Run: `npm test` — should pass

### "I want to use the CLI now"
- Not ready yet (Phase 3-4)
- We're currently at Phase 2 (API discovery)
- But all building blocks are tested and ready

### "How do I know it's working?"
```bash
npm test
# Look for: "Test Suites: 3 passed, 3 total"
#          "Tests: 45 passed, 45 total"
```

---

## Architecture

```
┌─ Okta SSO ──────┐
│ (Your Browser)  │
└────────┬────────┘
         │
         ↓
   Cookie Capture (Playwright)
         ↓
   .cookies/.raw_cookies
         │
         ├─→ HTTP Client
         │
         └─→ HTTP Headers
                │
                ↓
         Zoom Internal APIs
                │
                ↓
         Meeting Management
             (List, Create,
              Update, Delete)
```

---

## Test Coverage

```
✅ Cookie parsing     (15 tests)
✅ HTTP client        (15 tests)
✅ API models         (15 tests)

45 tests, all passing
95%+ code coverage
```

---

## How It Works (High Level)

1. **Phase 1 (✅ Done)**
   - Playwright opens Zoom.us in a real browser
   - You complete Okta SSO login
   - Script captures authenticated cookies
   - Cookies saved locally (`.cookies/.raw_cookies`)

2. **Phase 2 (✅ Done)**
   - Built HTTP client with auth detection
   - Handles session expiry (401, 403, SAML redirects, etc.)
   - Typed Zoom API models (meetings, settings, etc.)
   - Full test coverage (45 tests)

3. **Phase 2b (🔲 Next)**
   - Run `npm run sniff-api` with captured cookies
   - You manually navigate Zoom UI
   - Script logs all API calls (endpoints, headers, payloads)
   - Generate API catalog (`docs/api-discovery.json`)

4. **Phase 3 (🔲 Later)**
   - Extract payload templates from discovered requests
   - Build validation for all fields
   - Offline integration tests

5. **Phase 4 (🔲 Later)**
   - Implement CLI: `zoom meetings list`, `zoom meetings create`, etc.
   - Add auto-reauth (detect expired sessions, re-login automatically)
   - Output formatting

6. **Phase 5-6 (🔲 Later)**
   - E2E tests against real Zoom API
   - Final documentation
   - macOS compatibility verification

---

## Files Worth Reading

- **`README.md`** — Full user guide
- **`TESTING_STRATEGY.md`** — Detailed test approach + checklist
- **`PROJECT_STATUS.md`** — Current progress + technical decisions
- **`src/cookies.ts`** — How cookie parsing works
- **`src/http-client.ts`** — How auth detection works
- **`src/zoom-api.ts`** — Zoom API structure

---

## Support

Questions? Check:
1. `README.md` — answers most questions
2. `TESTING_STRATEGY.md` — testing details
3. `PROJECT_STATUS.md` — current progress
4. `npm test` — verify everything works

---

**Ready?** Run: `npm test` to verify setup, then `npm run capture-cookies` to get started!

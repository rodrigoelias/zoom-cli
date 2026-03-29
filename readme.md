# 🎯 Zoom CLI - Manage Meetings from Command Line

A command-line interface for Zoom meeting management, built by reverse-engineering Zoom's internal API through Okta SSO authentication.

**Status**: 🏗️ **Phase 2** — API Discovery (building next)

---

## 🚀 Quick Start

### 1. Clone & Setup

```bash
git clone <repo-url> zoom-cli
cd zoom-cli
npm install
```

### 2. Capture Cookies (Okta SSO)

```bash
npm run capture-cookies
```

This will:
- Open Zoom.us in your browser
- Redirect you to Okta login
- Capture authenticated cookies after you complete SSO + MFA
- Save cookies to `.cookies/.raw_cookies`

### 3. Discover API Endpoints

```bash
npm run sniff-api
```

This will:
- Load your captured cookies
- Open Zoom.us with those cookies
- Monitor all network requests as you navigate
- Generate `docs/api-discovery.json` with endpoint catalog

### 4. Run Tests

```bash
# All unit tests (no network, fast)
npm test

# With coverage report
npm run test:coverage

# Watch mode (for development)
npm run test:watch
```

---

## 📋 Features (Planned)

- [x] **Phase 1** — Session capture via Okta SSO
- [x] **Phase 2** — API endpoint discovery (network sniffing)
- [ ] **Phase 3** — Payload extraction & validation
- [ ] **Phase 4** — CLI implementation
  - [ ] `zoom meetings list` — View upcoming meetings
  - [ ] `zoom meetings create` — Schedule a new meeting
  - [ ] `zoom meetings view <id>` — Get meeting details
  - [ ] `zoom meetings update <id>` — Edit a meeting
  - [ ] `zoom meetings delete <id>` — Cancel a meeting
  - [ ] `zoom join <id>` — Get join URL
- [ ] **Phase 5** — Auto-reauth & error handling
- [ ] **Phase 6** — Comprehensive testing

---

## 📚 Project Structure

```
zoom-cli/
├── scripts/
│   ├── grab-cookies.ts      # Phase 1: Capture cookies via Okta
│   └── sniff-api.ts         # Phase 2: Discover API endpoints
├── src/
│   ├── cookies.ts           # Cookie utilities (parsing, validation)
│   ├── http-client.ts       # HTTP client with auth handling
│   ├── zoom-api.ts          # Zoom API models & endpoints
│   └── index.ts             # CLI entry point (TBD)
├── tests/
│   ├── cookies.test.ts      # ✅ Cookie tests
│   ├── http-client.test.ts  # ✅ HTTP client tests
│   ├── zoom-api.test.ts     # ✅ API model tests
│   ├── offline/             # 🔲 Mocked HTTP integration tests
│   └── e2e/                 # 🔲 Real API tests
├── docs/
│   ├── api-discovery.json   # Discovered endpoints (generated)
│   ├── agents.md            # API findings for Claude
│   └── captured-requests.jsonl
├── TESTING_STRATEGY.md      # Test strategy & checklist
├── package.json
├── tsconfig.json
└── jest.config.js

.cookies/                     # 🔐 (gitignored)
├── .raw_cookies            # Raw cookie string
└── cookies.txt             # Netscape format
```

---

## 🔐 How It Works

### Phase 1: Session Capture

```bash
┌─ Your Machine ─────────────────────────────────────────┐
│                                                         │
│  npm run capture-cookies                               │
│           ↓                                             │
│  ┌─ Browser (Playwright) ────────────────────┐         │
│  │                                           │         │
│  │  zoom.us → Okta Login → SSO → MFA       │         │
│  │                                           │         │
│  │  ✓ Login complete                         │         │
│  └───────────────────────────────────────────┘         │
│           ↓                                             │
│  context.cookies() ← captures httpOnly cookies         │
│           ↓                                             │
│  .cookies/.raw_cookies ← saved                         │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

**Why this works:**
- `document.cookie` (JavaScript) can't access httpOnly cookies
- Playwright's `context.cookies()` can (it's the browser)
- SSO is handled automatically (browser does it)
- Playwright waits for auth to complete

### Phase 2: API Discovery

```bash
npm run sniff-api
  ↓
Playwright loads zoom.us with captured cookies
  ↓
You navigate: "View meetings" → "Schedule meeting" → etc.
  ↓
Every XHR/fetch call is intercepted & logged
  ↓
Generate: api-discovery.json with:
  - endpoints (URL, method, required headers)
  - request payloads (what fields are needed)
  - response structures (what you get back)
  - error patterns (what expired auth looks like)
```

### Phase 3-6: Building the CLI

Once we have the API catalog, we'll:
1. **Extract payload templates** from discovered requests
2. **Build CLI commands** that map to API calls
3. **Add auto-reauth** — detect expired sessions, re-login automatically
4. **Full test coverage** — unit tests, mocked integration tests, real E2E tests
5. **Documentation** — `agents.md` for future AI automation

---

## 🧪 Testing

All tests run **without network access**. See `TESTING_STRATEGY.md` for details.

### Test Coverage

```
✅ Phase 1: Unit Tests (100% coverage)
   - Cookie parsing & validation
   - HTTP client with auth detection
   - API model validation

🔲 Phase 2: Offline Integration Tests (pending)
   - Full workflows with mocked HTTP
   - Auth expiry & recovery
   - Error handling

🔲 Phase 3: E2E Tests (pending)
   - Real Zoom API calls
   - Real credentials required
```

### Run Tests

```bash
# All tests
npm test

# Watch mode (for development)
npm run test:watch

# Coverage report
npm run test:coverage

# Specific test file
npm test -- cookies.test.ts
```

---

## 🛠️ Commands Reference

### Setup & Discovery

```bash
npm run capture-cookies   # Phase 1: Get authenticated session
npm run sniff-api         # Phase 2: Discover API endpoints
npm run build             # Compile TypeScript
```

### Testing

```bash
npm test                  # Run all tests
npm run test:watch       # Watch mode
npm run test:coverage    # With coverage report
npm run test:e2e         # E2E tests (requires credentials)
npm run test:offline     # Offline integration tests
```

### Development

```bash
npm run dev              # Run CLI in dev mode
npm run lint             # TypeScript check
```

---

## 📖 Documentation

- **[TESTING_STRATEGY.md](./TESTING_STRATEGY.md)** — Complete testing approach & checklist
- **[docs/api-discovery.json](./docs/api-discovery.json)** — Discovered Zoom API endpoints (auto-generated)
- **[docs/agents.md](./docs/agents.md)** — API findings formatted for Claude (TBD)
- **[docs/DEVELOPMENT.md](./docs/DEVELOPMENT.md)** — Development guide (TBD)

---

## ⚠️ Important Notes

### Security

- Cookies are stored in `.cookies/` (git-ignored)
- Never commit credentials or cookie files
- Cookies expire — re-run `npm run capture-cookies` if needed
- CSRF tokens are session-specific

### Okta SSO

- You must complete login in the browser (script can't automate MFA)
- If you have U2F/hardware key, approve in the security key
- Cookies capture works even with complex auth flows

### macOS Compatibility

- No `grep -P` (use `grep -oE` or Python instead)
- `date` flags differ (use `date -v` not `date -d`)
- Ensure `/bin/bash` not `/bin/sh`

---

## 🤝 Contributing

1. Add tests for any new functionality
2. Ensure `npm test` passes before committing
3. Update documentation (`TESTING_STRATEGY.md`, `README.md`)
4. See `TESTING_STRATEGY.md` for test coverage expectations

---

## 📊 Progress

| Phase | Task | Status | Tests |
|-------|------|--------|-------|
| 1 | Cookie capture (Okta) | ✅ Done | ✅ 100% |
| 2 | API discovery (sniffing) | ✅ Done | 📝 todo |
| 3 | Payload extraction | 📋 Next | 📝 todo |
| 4 | CLI implementation | 🔲 TBD | 📝 todo |
| 5 | Auto-reauth & errors | 🔲 TBD | 📝 todo |
| 6 | Full E2E testing | 🔲 TBD | 📝 todo |

---

## 🔗 References

- [Web-to-CLI Skill](/.agents/skills/web-to-cli/SKILL.md)
- [Zoom API Docs](https://developers.zoom.us/docs/api/) (reference only; we're reverse-engineering)
- [Playwright Docs](https://playwright.dev/)
- [Jest Testing](https://jestjs.io/)

---

## 📝 License

TBD

---

**Next**: See [TESTING_STRATEGY.md](./TESTING_STRATEGY.md) for detailed testing plan.

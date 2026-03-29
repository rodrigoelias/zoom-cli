# Headless Cookie Capture & Login

## Overview

The `auto-login` script intelligently handles cookie capture in two modes:

1. **Headless Mode** (default when already authenticated)
   - Fast, non-interactive
   - Perfect for CI/CD and automation
   - Automatically used after first successful login

2. **Visible Browser Mode** (when not authenticated)
   - Opens a visible browser
   - User completes Okta SSO manually
   - Captures cookies once authenticated

## Usage

### Simple: Auto-detect everything

```bash
npm run auto-login
```

The script will:
1. Check if already authenticated with Okta (headless check)
2. If yes → run headless, capture cookies, exit
3. If no → open visible browser, wait for user to login, capture cookies

### With Credentials: Automated login (headless)

```bash
OKTA_USERNAME=your@email.com OKTA_PASSWORD=yourpass npm run auto-login
```

If already authenticated, uses headless mode. If not, automatically enters credentials.

### After Initial Login: Refresh cookies

```bash
npm run refresh-cookies
```

Always runs headless. Loads existing cookies, validates them on zoom.us, captures any updates.

## Decision Flow

```
npm run auto-login
  ↓
Check auth (headless) ← 30 second timeout
  ↓
  ├─ Authenticated? YES
  │   └─ Open headless browser
  │       └─ Capture cookies (15-28 cookies)
  │
  └─ Authenticated? NO
      ├─ Credentials provided?
      │   ├─ YES → Headless + auto-login attempt
      │   └─ NO  → Open visible browser
      │
      └─ Wait for user (5 min timeout)
          └─ Capture cookies when logged in
```

## Examples

### Scenario 1: First time (user not authenticated)

```bash
$ npm run auto-login

🔐 Zoom Cookie Capture

🔍 Checking authentication status (headless)...
❌ Not authenticated with Okta

📖 Opening browser for manual Okta SSO login...
(browser opens → user completes SSO)
✅ Login detected!
🍪 Captured 28 cookies
✅ Headless login complete!
```

### Scenario 2: Subsequent run (user already authenticated)

```bash
$ npm run auto-login

🔐 Zoom Cookie Capture

🔍 Checking authentication status (headless)...
✅ Already authenticated with Okta (using headless mode)

🌐 Opening zoom.us (headless)...
✅ Authenticated!
🍪 Captured 15 cookies
✅ Headless login complete!
```

### Scenario 3: CI/CD with credentials

```bash
$ OKTA_USERNAME=bot@company.com OKTA_PASSWORD=secretpass npm run auto-login

🔍 Checking authentication status (headless)...
✅ Already authenticated with Okta (using headless mode)
🌐 Opening zoom.us (headless)...
✅ Authenticated!
🍪 Captured 15 cookies
✅ Headless login complete!
```

## Cookie Refresh Flow

After initial login, cookies can expire. Use refresh to keep them fresh:

```bash
npm run refresh-cookies
```

This is **always headless** and:
1. Loads existing cookies from disk
2. Opens zoom.us in headless browser
3. Waits for JavaScript to settle
4. Captures expanded cookie set
5. Updates `.cookies/.raw_cookies` and `.cookies/cookies.txt`

## Environment Variables

| Variable | Purpose | Example |
|---|---|---|
| `OKTA_USERNAME` | Email for auto-login | `user@company.com` |
| `OKTA_PASSWORD` | Password for auto-login | `mypassword123` |

⚠️ **Warning**: Do not commit credentials to version control. Use:
- CI/CD secrets (GitHub Actions, GitLab CI, etc.)
- `.env.local` (not committed)
- Environment setup scripts

## Troubleshooting

### "Not authenticated with Okta" but browser shows I'm logged in?

The script checks for specific UI elements (`text=Schedule`, `text=Join`, etc.). If Zoom's UI changes, these selectors may fail. Open an issue with your browser's dev tools screenshot.

### Timeout after 5 minutes in visible browser

You took too long to complete Okta SSO. Run again:
```bash
npm run auto-login
```

### Cookies work once then fail next time

Cookies expire (1-2 hours). Refresh them:
```bash
npm run refresh-cookies
```

Or create a cron job:
```bash
*/30 * * * * cd /path/to/zoom-cli && npm run refresh-cookies
```

## Architecture

### Headless Check (30s)
1. Launch Chromium headless
2. Navigate to zoom.us
3. Check for logged-in indicators
4. Close browser
5. Return true/false

### Main Flow
1. If authenticated → headless mode
2. If not authenticated → visible browser
3. Capture cookies from either path
4. Save to disk in two formats

### Formats
- **Raw**: `name=value; name=value;...` (curl-friendly)
- **Netscape**: Tab-separated (wget-friendly, cookiejar-compatible)

## Next Steps

Once you have cookies:

```bash
# Discover Zoom API endpoints (interactive)
npm run sniff-api

# Refresh cookies before they expire
npm run refresh-cookies

# Use in your automation
curl -b .cookies/.raw_cookies https://skyscanner.zoom.us/rest/meeting/list ...
```

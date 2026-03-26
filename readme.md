# zoom-cli

> ⚠️ **Work in progress.** Only tested creating meetings (recurring, single, with invitees, etc). Everything else is experimental. Use at your own risk.

A command-line tool for managing Zoom meetings. It talks directly to Zoom's internal web API using your browser session cookies — no OAuth app or API keys needed.

## Prerequisites

- **bash** (macOS/Linux)
- **curl**
- **jq** — `brew install jq`
- **Node.js** (for SSO login) — `brew install node`
- **Playwright** — installed via `npm install`

## Install

```bash
git clone git@github.com:rodrigoelias/zoom-cli.git
cd zoom-cli
npm install
chmod +x zoom-cli.sh
```

## Authentication

The CLI uses your Zoom web session cookies. There are two ways to set them up:

### Option A: Automated login (recommended)

Opens a browser window for SSO login, then captures the cookies automatically:

```bash
./zoom-cli.sh login
```

### Option B: Manual cookie paste

1. Sign into [skyscanner.zoom.us](https://skyscanner.zoom.us) in your browser
2. Open DevTools (F12) → Console → run: `copy(document.cookie)`
3. Paste into the CLI:

```bash
./zoom-cli.sh set-cookies "<paste>"
./zoom-cli.sh refresh-csrf
```

> **Note:** Session cookies expire after a few hours of inactivity. The CLI will automatically re-launch the browser for SSO if it detects an expired session (interactive terminals only).

## Usage

### List meetings

```bash
./zoom-cli.sh list
```

### View a meeting

```bash
./zoom-cli.sh view <meeting_id>
```

### Create a meeting

```bash
# Simple meeting
./zoom-cli.sh create -t "Standup" -d 03/28/2026 --time 9:00 --ampm AM --duration 30

# Recurring weekly meeting
./zoom-cli.sh create -t "Weekly Sync" --recurring --recurrence-type WEEKLY --recurrence-days SA --time 10:00 --ampm AM

# With invitees
./zoom-cli.sh create -t "1:1" -i alice@example.com -i bob@example.com
```

#### Create options

| Flag | Description | Default |
|---|---|---|
| `--topic`, `-t` | Meeting topic | `"My Meeting"` |
| `--agenda`, `--desc` | Meeting description | |
| `--date`, `-d` | Start date `MM/DD/YYYY` | today |
| `--time` | Time `H:MM` | next round hour |
| `--ampm` | `AM` or `PM` | `PM` |
| `--duration` | Duration in minutes | `60` |
| `--timezone`, `-tz` | Timezone | `Europe/London` |
| `--invite`, `-i` | Invitee email (repeatable) | |
| `--recurring`, `-r` | Enable recurrence | |
| `--recurrence-type` | `DAILY`, `WEEKLY`, or `MONTHLY` | |
| `--recurrence-interval` | Every N periods | `1` |
| `--recurrence-days` | Day(s): `MO,TU,WE,TH,FR,SA,SU` | |
| `--recurrence-end` | End date `MM/DD/YYYY` | |

### Update a meeting

```bash
./zoom-cli.sh update <meeting_id> --topic "New Name" --time 2:00 --ampm PM
```

### Delete a meeting

```bash
./zoom-cli.sh delete <meeting_id>
```

### Debug: raw API call

```bash
./zoom-cli.sh raw POST /rest/meeting/list "listType=upcoming&page=1&pageSize=10"
```

## Running tests

All tests run offline with mocked HTTP — no Zoom account needed:

```bash
./test-zoom-cli.sh
```

## License

ISC

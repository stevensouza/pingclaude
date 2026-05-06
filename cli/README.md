# PingClaude Lite

A single-file, cross-platform Python script that pings Claude once and exits.
Designed for ad-hoc terminal use or scheduled execution under cron / Task
Scheduler. It is a lightweight companion to the macOS PingClaude menu-bar app
in the parent directory and shares no code with it.

## What it does

Sends one tiny message (`hi`, model `claude-haiku-4-5-20251001`) to your
**claude.ai web account** so the rolling **5-hour usage window starts on a
schedule you choose**. You'd typically run this from cron a few minutes before
you start working, so the window resets at, say, 1:55pm instead of whenever
you happen to send your first real prompt.

Prints whether the ping succeeded plus the reset time and percent used for
each usage window.

## What credentials it uses (read this first)

This tool uses your **claude.ai consumer/web account** — the same one you sign
into in the browser — authenticated by:

- **`sessionKey`** — a cookie value (looks like `sk-ant-sid01-...`)
- **`orgId`** — your claude.ai organization UUID

It does **NOT** use the developer API at `api.anthropic.com` and does **NOT**
use `sk-ant-...` API keys. Those won't work and aren't what governs the
5-hour window.

### How to obtain `sessionKey` and `orgId`

1. Sign in to <https://claude.ai> in your browser.
2. Open dev tools (Cmd-Option-I / Ctrl-Shift-I) → **Application** →
   **Cookies** → `https://claude.ai`. Copy the `sessionKey` value.
3. Still in dev tools, open **Network**, send any message, and look at any
   request URL containing `/api/organizations/<UUID>/...`. That UUID is your
   `orgId`.

The Mac GUI app already stores both — the CLI will pick them up automatically
from the plist (see below) so on a Mac you usually don't need to do this
again.

## Install

Requires **Python 3.8+** and **`curl_cffi`** (one pip dependency).

### Why curl_cffi is required

claude.ai sits behind Cloudflare, which TLS-fingerprints every connection
(JA3/JA4) and serves a 403 challenge page to anything that doesn't look
like a real browser — including Python's stdlib `urllib`, `requests`, and
even system `curl`. The Mac GUI app gets through because Apple's
`URLSession` uses Apple's TLS stack, which Cloudflare recognizes as Safari.

`curl_cffi` is a Python wrapper around libcurl-impersonate that produces a
TLS handshake byte-for-byte identical to a real Safari/Chrome. From
Cloudflare's edge, the script is indistinguishable from a real browser. It
ships as pre-built wheels for macOS, Linux, and Windows; install is a
single command.

### Recommended setup (macOS / Linux)

macOS Homebrew Python and most modern Linux distros block system-wide pip
installs (PEP 668). Use a venv:

```bash
python3 -m venv ~/.pingclaude/venv
~/.pingclaude/venv/bin/pip install curl_cffi
chmod +x cli/pingclaude.py
~/.pingclaude/venv/bin/python3 cli/pingclaude.py            # prints help
~/.pingclaude/venv/bin/python3 cli/pingclaude.py ping       # send the ping
```

Or, if your Python doesn't object:

```bash
pip install curl_cffi
chmod +x cli/pingclaude.py
cli/pingclaude.py            # prints help
cli/pingclaude.py ping       # send the ping
```

(`pipx install curl_cffi` does **not** help here because pipx isolates
applications, not libraries — the script needs `curl_cffi` importable in
the same interpreter that runs it. Use the venv approach.)

### Windows

```powershell
py -m venv %USERPROFILE%\.pingclaude\venv
%USERPROFILE%\.pingclaude\venv\Scripts\pip install curl_cffi
%USERPROFILE%\.pingclaude\venv\Scripts\python cli\pingclaude.py ping
```

### If curl_cffi is missing

The script exits with code **5** and prints the install command. It does
**not** silently fall back to `urllib`, because that would always fail on
Cloudflare-fronted endpoints anyway.

## Configure

The script looks for credentials in this order. **First match wins.**

### 1. Environment variables (recommended for shells)

```bash
export PINGCLAUDE_SESSION_KEY="sk-ant-sid01-...."
export PINGCLAUDE_ORG_ID="00000000-0000-0000-0000-000000000000"
pingclaude.py ping
```

Put the exports in `~/.zshenv` or `~/.bash_profile` so they're inherited by
cron-spawned shells too (depending on your cron and shell).

### 2. Config file (recommended for cron)

Copy `config.example.json` and fill in real values:

```bash
mkdir -p ~/.config/pingclaude
cp cli/config.example.json ~/.config/pingclaude/config.json
chmod 600 ~/.config/pingclaude/config.json
$EDITOR ~/.config/pingclaude/config.json
```

Format:

```json
{
  "session_key": "sk-ant-sid01-...",
  "org_id": "00000000-0000-0000-0000-000000000000"
}
```

`~/.pingclaude/config.json` is checked as a secondary fallback.

If claude.ai issues a refreshed `sessionKey` cookie during a ping, the script
silently writes the new value back to this file. (It does **not** rewrite the
plist or override env vars.)

### 3. macOS plist (zero-config on Macs that already use the GUI app)

If `~/Library/Preferences/com.pingclaude.app.plist` exists and contains valid
credentials, the script reads them automatically. This is read-only — the
script never modifies the plist.

### Why no `--session-key` / `--org-id` CLI flags?

CLI arguments are visible in `ps`/process listings to anyone on the system who
can list processes — the worst place to put a secret. Env vars aren't shown
there by default; a `chmod 600` config file is most private. The script
deliberately offers no flag for the credential values.

## Usage

```text
pingclaude.py                       # prints help (no-arg behavior)
pingclaude.py ping                  # ping, human-readable output
pingclaude.py ping --json           # ping, single JSON line
pingclaude.py ping --quiet          # silent on success, error to stderr on failure
pingclaude.py ping --no-usage       # skip usage parsing, just verify the ping
pingclaude.py ping --config PATH    # explicit config file path
```

Default human output:

```
✓ Ping ok (1.42s) — said "hi", got "Hi! How can I help you today?"
  creds source: env

  5-hour window:  23.4% used  →  resets in 4h 12m  (2026-05-06 18:42 EDT)
  7-day window :  11.8% used  →  resets in 6d 03h  (2026-05-12 00:00 EDT)
```

JSON output (one line, JSONL-friendly):

```json
{"ts":"2026-05-06T08:55:01-04:00","ok":true,"duration_s":1.42,"model":"claude-haiku-4-5-20251001","creds_source":"env","reply":"Hi! How can I help you today?","windows":{"5h":{"util":0.234,"resets_at":"2026-05-06T18:42:00-04:00"},"7d":{"util":0.118,"resets_at":"2026-05-12T00:00:00-04:00"}}}
```

## Schedule

### macOS / Linux cron

Use the **full path to your venv's python** (the one that has `curl_cffi`
installed). cron does not inherit your shell's `$PATH` or activate venvs.

```cron
# Quiet — silent on success, default cron behavior emails on failure.
55 8 * * 1-5 /Users/you/.pingclaude/venv/bin/python3 /path/to/pingclaude/cli/pingclaude.py ping --quiet

# JSON history log — one record per run, append-only.
55 8 * * 1-5 /Users/you/.pingclaude/venv/bin/python3 /path/to/pingclaude/cli/pingclaude.py ping --json >> ~/.pingclaude/history.jsonl
```

cron also runs with a near-empty environment, so prefer the **config file**
route for cron (env vars from your shell rc aren't loaded).

### History via append

Want the equivalent of the GUI app's history log? Use the JSON pattern above.
Each line is a self-contained JSON object — tail it, grep it, feed it to `jq`:

```bash
tail -f ~/.pingclaude/history.jsonl
jq 'select(.ok==false)' ~/.pingclaude/history.jsonl  # only failures
jq -r '[.ts, (.windows."5h".util // 0)] | @tsv' ~/.pingclaude/history.jsonl
```

### Windows Task Scheduler

```cmd
schtasks /create /sc daily /tn PingClaude /st 08:55 ^
  /tr "python C:\path\to\cli\pingclaude.py ping --quiet"
```

## Exit codes

| Code | Meaning                              |
|------|--------------------------------------|
|  0   | success                              |
|  1   | auth error (HTTP 401/403)            |
|  2   | network or other HTTP error          |
|  3   | configuration error (no credentials) |
|  4   | unexpected response / parse error    |
|  5   | missing `curl_cffi` dependency       |

Useful in cron wrappers:

```bash
pingclaude.py ping --quiet || \
  case $? in
    1) notify-send "PingClaude: re-extract sessionKey" ;;
    2) ;;  # transient network — ignore
    *) echo "PingClaude failed with code $?" ;;
  esac
```

## Troubleshooting

**Exit 5 / "missing dependency: curl_cffi"** — install it (see Install
above). For cron, make sure the cron line uses the venv's full
`python3` path; cron doesn't activate venvs.

**Exit 1 / "auth expired"** — the `sessionKey` has been invalidated (logout,
password change, long inactivity). Re-extract it from the browser and update
your env var or config file.

**Exit 3 / "no credentials found"** — the script lists every source it
checked. Set env vars *or* create a config file. On Macs, also confirm the
GUI app has been launched once and configured.

**Exit 2 / network error or HTTP 429** — DNS, offline, or claude.ai is
throttling. The script does not retry on its own; let cron run again on the
next tick.

**HTTP 403 with body containing `<title>Just a moment...`** — that's the
Cloudflare challenge page. It means `curl_cffi` failed to impersonate (or
isn't being used). Make sure you're running the venv's Python, not the
system Python. Run `your-venv/bin/python -c 'import curl_cffi; print(curl_cffi.__version__)'`
to confirm.

**Output shows `creds source: plist` but you wanted env vars** — env vars are
checked first, so this means your env vars weren't set at the time the
process ran. cron in particular doesn't inherit your interactive shell's env;
use a config file for cron.

### Note on VPNs (Surfshark, Mullvad, etc.)

Cloudflare flags traffic from commercial VPN IP ranges more aggressively.
The Mac GUI app, system `curl`, and Python's `urllib` all routinely get 403
challenge pages from those ranges. `curl_cffi` with Safari impersonation
sails through anyway because Cloudflare's TLS-fingerprint check passes
before its IP-reputation check matters here. If you ever do get blocked
even with `curl_cffi`, try briefly disconnecting the VPN, running the ping,
then reconnecting — that gets you a fresh Cloudflare clearance bound to
your real IP.

## Files

| File                              | Purpose                          |
|-----------------------------------|----------------------------------|
| `pingclaude.py`                   | the script                       |
| `config.example.json`             | sample config (no real creds)    |
| `~/.config/pingclaude/config.json`| your config (you create this)    |
| `~/.pingclaude/venv/`             | suggested venv with `curl_cffi`  |
| `~/.pingclaude/history.jsonl`     | suggested location for cron logs |

## Limits / scope

- Single-shot. No daemon, no schedule of its own — that's what cron is for.
- Burn-rate, plan tier, weekly per-model breakdowns: not collected. The GUI
  app does those. The CLI's job is to start the clock and tell you where it
  stands.

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

pingclaude.py schedule              # always-on loop; pings at the times in your config
pingclaude.py schedule --json       # print a JSON record on each fire
pingclaude.py schedule --history PATH  # also append each fire's JSON record to a file
```

The `ping` command is single-shot. The `schedule` command is a long-running
loop that fires `ping` at the wall-clock times you put in the config file — see
**[Scheduling via JSON config](#scheduling-via-json-config-recommended)** below.

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

## Scheduling via JSON config (recommended)

The cron/Task-Scheduler routes above work, but they put the *when* in a
crontab. If you'd rather control the schedule by editing **one JSON file** — the
same one that holds your credentials — use the built-in `schedule` command.

`pingclaude.py schedule` is a small, always-on loop that pings at the local
wall-clock times listed in your config, **7 days a week by default**. It:

- re-reads the config **every cycle**, so edits take effect within ~60s with no
  restart (add a time, change the timezone, flip it off);
- fires each slot **exactly once per day** (safe across sleep/resume and clock
  changes);
- reuses the same ping path as `ping`, so every ping uses **Haiku**
  (`claude-haiku-4-5-20251001`);
- logs each fire to stdout (captured by systemd/launchd) and, with `--history`,
  appends the same one-line JSON record used by `ping --json`.

### Why an always-on host (and not a sleeping laptop)

Because `schedule` is a process that's **already running** at 06:00, it needs
**no cron, no `pmset`, and no wake-from-sleep magic** — it just notices the slot
is due. That's why the ideal host is an always-on machine (a **Linux Mint /
Linux box**, a Mac mini, or any Mac you keep awake). A **clamshell / lid-closed
laptop deep-sleeps and will not fire on time**, so it's a poor host for
unattended early-morning pings.

### The `schedule` config block

Add a `schedule` object to `~/.config/pingclaude/config.json` (alongside
`session_key` / `org_id`):

```json
{
  "session_key": "sk-ant-sid01-...",
  "org_id": "00000000-0000-0000-0000-000000000000",
  "schedule": {
    "enabled": true,
    "times": ["06:00", "11:00"],
    "weekdays": ["mon", "tue", "wed", "thu", "fri", "sat", "sun"],
    "timezone": "America/New_York",
    "catch_up": false
  }
}
```

| Key        | Meaning                                                                 |
|------------|-------------------------------------------------------------------------|
| `enabled`  | Master on/off. When `false`, the loop idles but keeps running (flip it back on with a live edit — no restart). |
| `times`    | Local `HH:MM` (24-hour) fire times. Empty ⇒ nothing fires.              |
| `weekdays` | 3-letter day names. **Omit or leave empty to run all 7 days.**           |
| `timezone` | IANA name (e.g. `America/New_York`). Omit ⇒ the host's local zone.       |
| `catch_up` | If `true`, on startup fire once for a slot earlier *today* that hasn't fired yet. Default `false`. |

> **Python version:** `schedule` prefers **Python 3.9+** (for `zoneinfo`, so the
> `timezone` field is DST-correct). On 3.8 it falls back to the host's local
> time and ignores `timezone` (with a warning). `ping` remains 3.8-compatible.
> Any current Linux Mint / macOS ships 3.9+, so this is a non-issue in practice.

### Linux Mint / Linux setup (recommended host)

End-to-end, on your always-on box:

```bash
# 1. venv with curl_cffi
python3 -m venv ~/.pingclaude/venv
~/.pingclaude/venv/bin/pip install curl_cffi

# 2. config with creds + schedule (see block above), locked down
mkdir -p ~/.config/pingclaude
cp cli/config.example.json ~/.config/pingclaude/config.json
chmod 600 ~/.config/pingclaude/config.json
$EDITOR ~/.config/pingclaude/config.json      # paste real session_key/org_id, set times

# 3. verify one ping works
~/.pingclaude/venv/bin/python3 /path/to/pingclaude/cli/pingclaude.py ping

# 4. install the systemd USER service (edit the two paths inside it first)
mkdir -p ~/.config/systemd/user
cp cli/service/pingclaude.service ~/.config/systemd/user/pingclaude.service
$EDITOR ~/.config/systemd/user/pingclaude.service   # set venv + checkout paths
loginctl enable-linger "$USER"                # run without an interactive login
systemctl --user daemon-reload
systemctl --user enable --now pingclaude.service

# 5. watch it
systemctl --user status pingclaude.service
journalctl --user -u pingclaude.service -f
```

`loginctl enable-linger` is what keeps the user service alive when you're not
logged in — essential for a headless always-on box.

### macOS setup

Best on a Mac you keep awake (see the wake caveat above). A sample LaunchAgent
lives at `cli/service/com.pingclaude.schedule.plist`:

```bash
$EDITOR cli/service/com.pingclaude.schedule.plist       # set the /Users/you paths
cp cli/service/com.pingclaude.schedule.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.pingclaude.schedule.plist
launchctl list | grep pingclaude
tail -f ~/.pingclaude/scheduler.out.log
```

On macOS the scheduler can also read credentials straight from the GUI app's
plist, so you may only need the `schedule` block in the JSON config.

### Watching the log

```bash
journalctl --user -u pingclaude -f            # Linux (systemd)
tail -f ~/.pingclaude/scheduler.out.log       # macOS (launchd)
tail -f ~/.pingclaude/history.jsonl           # the per-fire JSON records (--history)
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

| File                                        | Purpose                                   |
|---------------------------------------------|-------------------------------------------|
| `pingclaude.py`                             | the script (`ping` + `schedule`)          |
| `config.example.json`                       | sample config, incl. the `schedule` block |
| `service/pingclaude.service`                | sample systemd user service (Linux)       |
| `service/com.pingclaude.schedule.plist`     | sample launchd agent (macOS)              |
| `~/.config/pingclaude/config.json`          | your config (you create this)             |
| `~/.pingclaude/venv/`                       | suggested venv with `curl_cffi`           |
| `~/.pingclaude/history.jsonl`               | suggested location for history records    |

## Limits / scope

- `ping` is single-shot — no schedule of its own; drive it from cron/Task
  Scheduler, or use the built-in **`schedule`** command for a JSON-config-driven,
  always-on scheduler (see [Scheduling via JSON config](#scheduling-via-json-config-recommended)).
- Burn-rate, plan tier, weekly per-model breakdowns: not collected. The GUI
  app does those. The CLI's job is to start the clock and tell you where it
  stands.

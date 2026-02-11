# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

PingClaude is a macOS menu bar app that automatically pings Claude to manage the rolling 5-hour token usage window. It features:
- Scheduled pings via Claude API or CLI fallback
- Live usage tracking from claude.ai Web API
- Usage velocity tracking (burn rate in %/hr)
- Menu bar status display with percentage
- SwiftUI-based settings, history, and dashboard views

**Platform:** macOS 12+ (Monterey minimum)
**Language:** Swift 5.7.2+
**Frameworks:** AppKit (menu bar), SwiftUI (views), Combine (reactive updates)
**Build:** Swift Package Manager + Makefile (no Xcode project)

## Build Commands

```bash
# Build binary only
make build

# Build + assemble .app bundle
make bundle

# Build + launch
make run

# Install to /Applications (copies bundle)
make install

# Deploy: kill running app, install, verify hash, launch
make deploy

# Code quality scan (custom Swift scanner)
make lint

# Clean build artifacts
make clean
```

**First launch:** macOS Gatekeeper may block. Either right-click → Open, or run:
```bash
xattr -cr /Applications/PingClaude.app
```

## Architecture

### Service-Based Design

The app uses a **dependency injection pattern** where `AppDelegate` initializes all services in a specific order and wires them together:

```
AppDelegate (lifecycle coordinator)
├── SettingsStore (UserDefaults-backed @Published config)
├── LogStore (file-backed event log)
├── PingHistoryStore (JSON-backed ping records)
├── PingService (API + CLI ping execution)
├── UsageService (polls claude.ai for usage metrics)
├── UsageVelocityTracker (burn rate tracking with persistent samples)
├── SchedulerService (timer + sleep/wake handling)
└── StatusBarController (menu bar UI + Combine observers)
```

**Key dependencies:**
- All services depend on `SettingsStore`
- `SchedulerService` depends on `PingService`, `PingHistoryStore`, `LogStore`, `UsageService`
- `StatusBarController` depends on all services for UI updates
- Services communicate via `@Published` properties and Combine

### Critical Patterns

**1. Implicitly Unwrapped Optional (IUO) Properties**

The codebase uses IUOs extensively for Cocoa/AppKit properties initialized in `init()`:

```swift
private var statusMenuItem: NSMenuItem!  // Initialized before use
```

This is **intentional and standard** for AppKit code. The quality scanner flags these but they are documented in `.swiftlint-baseline.txt`. Only fix if initialization logic changes.

**2. No App Sandbox**

The app runs **without sandbox** to execute the `claude` CLI as a subprocess. This is intentional:
- Required for `Process` to spawn `claude` CLI
- Default when building with `swiftc` (not Xcode)
- Documented security trade-off

**3. Dual Ping Methods**

`PingService` has two execution paths:
- **API mode** (preferred): Direct HTTP POST to claude.ai API with SSE parsing
- **CLI mode** (fallback): Spawns `claude` CLI via `Process` with 30s timeout

Check `canPingViaAPI` to determine which path. API mode requires `orgId` + `sessionKey` from settings.

**4. App Nap Prevention**

`AppDelegate` calls `ProcessInfo.beginActivity(.userInitiated)` to prevent macOS App Nap from suspending timers. Critical for reliable ping scheduling.

**5. Usage Polling is Free**

`UsageService` polls claude.ai usage API without consuming tokens or starting sessions. Runs on configurable interval (default: 1 min).

**6. Reset-Triggered Ping**

When usage API reports a session reset time and utilization > 20%, `SchedulerService` automatically schedules a ping at the exact reset moment (with retry logic). Works independently of regular schedule.

### Data Flow

**Ping execution:**
```
User/Timer → PingService.ping()
           → pingViaAPI() or pingViaCLI()
           → PingResult with usage data
           → PingHistoryStore.addPingResult()
           → StatusBarController updates via Combine
```

**Usage tracking:**
```
Timer → UsageService.poll()
      → Parse API response
      → Update @Published properties
      → UsageVelocityTracker.recordSample()
      → StatusBarController updates menu bar icon with %
```

**Settings changes:**
```
SettingsView changes @Published property
→ SettingsStore publishes change
→ All services observe via Combine
→ SchedulerService restarts if needed
→ UI updates reactively
```

## Code Quality

### Quality Scanner

Custom Swift-based scanner (SwiftLint requires macOS 13+, we're Monterey-compatible):

**Run scan:**
```bash
make lint
```

**Key rules:**
- `force_unwrapping` — Flags direct force unwraps (errors)
- `force_cast` — Unsafe `as!` casts (warnings)
- `weak_delegate` — Missing weak self in Combine (errors)
- `empty_count` — Use `.isEmpty` vs `.count == 0` (info)

**Baseline:** `.swiftlint-baseline.txt` captures 48 pre-existing issues (mostly intentional IUOs). New violations fail CI.

### CI/CD

GitHub Actions workflow (`.github/workflows/quality.yml`):
- Runs `make lint` on all pushes/PRs
- Runs `make bundle` to verify build
- Fails PR if quality errors detected
- Uploads quality report as artifact

## File Locations

**Runtime files** (all in `~/Library/`):
- Event log: `Logs/PingClaude/pingclaude.log`
- Ping history: `Logs/PingClaude/ping_history.json`
- Usage samples: `Logs/PingClaude/usage_samples.json`
- Settings: `Preferences/` (via UserDefaults)
- LaunchAgent: `LaunchAgents/com.pingclaude.app.plist` (macOS 12 only)

**Build artifacts:**
- Binary: `.build/PingClaude`
- App bundle: `.build/PingClaude.app`
- Build version: `.build/BuildVersion.swift` (generated on each build)

## Key Technical Details

### API Ping Implementation

`PingService.pingViaAPI()` uses streaming API:
1. POST to `https://api.claude.ai/api/organizations/{orgId}/chat_conversations`
2. Parse Server-Sent Events (SSE) stream
3. Extract `message_limit` event for usage data
4. Extract `message_delta` for response text
5. Update session key from `Set-Cookie` response header

### Usage Velocity Tracking

`UsageVelocityTracker`:
- Samples usage % at regular intervals
- Persists to `usage_samples.json`
- Calculates burn rate (%/hr) via linear regression
- Provides session, weekly, and all-time velocity
- Estimates time until rate limit hit
- Color codes: green (>2h), orange (<2h), red (<1h)

### Launch at Login

**macOS 13+:** Uses native `SMAppService` API (toggle in Settings)

**macOS 12:** Install LaunchAgent plist manually:
```bash
./Scripts/install-launchagent.sh
./Scripts/uninstall-launchagent.sh  # to remove
```

### Window Management

**Single tabbed window** shared by Settings, Ping History, and Claude Info:
- `MainWindow.swift` — NSWindow hosting TabView
- `EditableWindow.swift` — Adds Cmd+C/V/X/A support
- `MainTabView.swift` — SwiftUI TabView container

Opening any view from menu bar brings window forward and switches tabs.

## Security Considerations

**API credentials:**
- Stored in UserDefaults (not Keychain due to Monterey compatibility)
- Session key auto-refreshes on each API call
- No credentials in code or logs

**Force unwraps:**
- Tracked in baseline file
- Acceptable for IUO properties initialized in `init()`
- Must fix if found in runtime logic (parsing, network calls)

**Process execution:**
- CLI spawned with 30s timeout
- No shell injection (direct `Process` execution)
- Path validated from settings

## Development Notes

**Testing:** No automated test suite currently. Manual testing required:
1. Build with `make bundle`
2. Test ping via menu bar "Ping Now"
3. Verify settings persistence
4. Check usage tracking if API configured
5. Verify schedule behavior

**Debugging:**
- Check event log: `~/Library/Logs/PingClaude/pingclaude.log`
- Monitor Console.app for NSLog output
- Verify API calls in Network tab (Charles/Proxyman)

**Model names:**
Available models from settings (default: haiku):
- `claude-haiku-4-5-20251001` (recommended: low cost)
- `claude-sonnet-4-5-20250929`
- `claude-opus-4-6-20250121`

**Deployment workflow:**
```bash
# Development: quick iteration
make run

# Production: verify hash, kill existing, install, launch
make deploy
```

## Common Pitfalls

1. **App Nap suspension:** If timers don't fire, verify `beginActivity()` is called in `AppDelegate`
2. **Gatekeeper blocking:** Run `xattr -cr` on first install
3. **API 401 errors:** Session key expired, user must re-enter from browser
4. **CLI timeout:** If `claude` hangs, 30s timeout will kill process
5. **Baseline drift:** Run `make lint` and diff against baseline to catch new issues
6. **Launch at login (macOS 12):** Must use LaunchAgent script, settings toggle only works on macOS 13+

## References

- README.md — Full user documentation
- QUALITY.md — Quality scanning details and how to fix issues
- IMPLEMENTATION_SUMMARY.md — Code quality scanner implementation notes
- .swiftlint.yml — Linting rules configuration

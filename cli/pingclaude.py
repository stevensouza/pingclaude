#!/usr/bin/env python3
"""
PingClaude Lite — cross-platform CLI ping for the claude.ai 5-hour window.

Sends one short message to Claude via the claude.ai web API so the rolling
5-hour usage window starts at a time you choose (e.g. via cron at 8:55am)
rather than whenever you happen to send your first real prompt.

Uses your claude.ai *web account* (sessionKey + orgId from the browser),
NOT the developer API (api.anthropic.com / sk-ant-... keys).

Run with no arguments to see help. To actually ping: `pingclaude.py ping`.

Requires `curl_cffi` (see cli/README.md). claude.ai is fronted by Cloudflare,
which TLS-fingerprints clients; curl_cffi impersonates Safari's TLS handshake
so the ping isn't blocked at the edge.
"""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import sys
import time
import uuid
from datetime import datetime, timedelta, timezone

try:
    from curl_cffi import requests as cffi_requests
    from curl_cffi.requests.exceptions import RequestException as CffiError
except ImportError:
    cffi_requests = None  # checked at runtime
    CffiError = Exception  # noqa: N816

# ---- constants -------------------------------------------------------------

API_BASE = "https://claude.ai/api/organizations"
MODEL = "claude-haiku-4-5-20251001"
PROMPT = "hi"
TIMEOUT_SECONDS = 45
ROOT_PARENT_UUID = "00000000-0000-4000-8000-000000000000"
IMPERSONATE = "safari17_0"

EXIT_OK = 0
EXIT_AUTH = 1
EXIT_NETWORK = 2
EXIT_CONFIG = 3
EXIT_PARSE = 4
EXIT_MISSING_DEP = 5

ENV_SESSION_KEY = "PINGCLAUDE_SESSION_KEY"
ENV_ORG_ID = "PINGCLAUDE_ORG_ID"

CONFIG_PATHS = [
    os.path.expanduser("~/.config/pingclaude/config.json"),
    os.path.expanduser("~/.pingclaude/config.json"),
]
MACOS_PLIST = os.path.expanduser(
    "~/Library/Preferences/com.pingclaude.app.plist"
)

# ---- config resolution -----------------------------------------------------


class Config:
    __slots__ = ("session_key", "org_id", "source", "config_path")

    def __init__(self, session_key: str, org_id: str, source: str,
                 config_path: str | None = None):
        self.session_key = session_key
        self.org_id = org_id
        self.source = source  # "env", "config", or "plist"
        self.config_path = config_path


def load_config(explicit_path: str | None = None) -> tuple[Config | None, list[str]]:
    """Return (config, attempted_sources). config is None if no source had creds."""
    attempted: list[str] = []

    env_session = os.environ.get(ENV_SESSION_KEY, "").strip()
    env_org = os.environ.get(ENV_ORG_ID, "").strip()
    attempted.append(f"env vars ({ENV_SESSION_KEY}, {ENV_ORG_ID})")
    if env_session and env_org:
        return Config(env_session, env_org, "env"), attempted

    paths = [explicit_path] if explicit_path else CONFIG_PATHS
    for path in paths:
        if not path:
            continue
        attempted.append(f"config file {path}")
        if os.path.isfile(path):
            try:
                with open(path, "r") as f:
                    data = json.load(f)
                sk = (data.get("session_key") or "").strip()
                org = (data.get("org_id") or "").strip()
                if sk and org:
                    return Config(sk, org, "config", path), attempted
            except (OSError, ValueError) as e:
                print(f"warning: could not read {path}: {e}", file=sys.stderr)

    attempted.append(f"macOS plist {MACOS_PLIST}")
    if os.path.isfile(MACOS_PLIST):
        try:
            with open(MACOS_PLIST, "rb") as f:
                data = plistlib.load(f)
            sk = (data.get("claudeSessionKey") or "").strip()
            org = (data.get("claudeOrgId") or "").strip()
            if sk and org:
                return Config(sk, org, "plist"), attempted
        except (OSError, plistlib.InvalidFileException) as e:
            print(f"warning: could not read {MACOS_PLIST}: {e}",
                  file=sys.stderr)

    return None, attempted


def save_session_key(config: Config, new_key: str) -> None:
    """Persist a refreshed session key — only when the config file was used."""
    if config.source != "config" or not config.config_path:
        return
    try:
        with open(config.config_path, "r") as f:
            data = json.load(f)
        data["session_key"] = new_key
        tmp = config.config_path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(data, f, indent=2)
        os.replace(tmp, config.config_path)
        try:
            os.chmod(config.config_path, 0o600)
        except OSError:
            pass
    except (OSError, ValueError) as e:
        print(f"warning: could not save refreshed session key: {e}",
              file=sys.stderr)


# ---- environment helpers ---------------------------------------------------


def _local_iana_tz() -> str:
    """Return the IANA tz name (e.g. America/New_York). Falls back to UTC.

    /etc/localtime is typically a symlink into the zoneinfo db on both macOS
    and Linux, so the last two path components are the IANA name. Honor the
    TZ env var if it looks IANA.
    """
    tz_env = os.environ.get("TZ", "").strip()
    if tz_env and "/" in tz_env:
        return tz_env
    try:
        target = os.readlink("/etc/localtime")
        parts = target.replace("\\", "/").split("/")
        if len(parts) >= 2:
            candidate = "/".join(parts[-2:])
            # accept things like "America/New_York"; reject "etc/UTC"
            if "/" in candidate and candidate != "etc/UTC":
                return candidate
    except (OSError, ValueError):
        pass
    return "UTC"


def _system_locale() -> str:
    """Return a locale string with hyphens (e.g. en-US). Falls back to en-US."""
    raw = (os.environ.get("LC_ALL")
           or os.environ.get("LANG")
           or "").split(".")[0]
    if raw and raw not in ("C", "POSIX"):
        return raw.replace("_", "-")
    return "en-US"


# ---- HTTP layer (curl_cffi with Safari TLS impersonation) ------------------


class APIError(Exception):
    def __init__(self, message: str, exit_code: int = EXIT_NETWORK):
        super().__init__(message)
        self.exit_code = exit_code


def _make_session():
    """Build a curl_cffi Session that impersonates Safari's TLS handshake.

    claude.ai sits behind Cloudflare, which checks the TLS fingerprint
    (JA3/JA4) of every connection. Stdlib urllib and OpenSSL-based clients
    get blocked at the edge with a 403 challenge page regardless of cookies.
    curl_cffi uses libcurl-impersonate to mimic a real browser handshake.
    """
    return cffi_requests.Session(impersonate=IMPERSONATE)


def _extract_session_key_from_cookies(cookies) -> str | None:
    """curl_cffi exposes response cookies as a Cookies-like object."""
    try:
        val = cookies.get("sessionKey")
        if val:
            return val
    except Exception:
        pass
    return None


def _maybe_auth_error(status: int) -> bool:
    return status in (401, 403)


# ---- ping flow -------------------------------------------------------------


def create_conversation(session, org_id: str, cookie: str, conv_uuid: str
                        ) -> str | None:
    """POST a new conversation. Returns refreshed sessionKey or None."""
    url = f"{API_BASE}/{org_id}/chat_conversations"
    body = {
        "uuid": conv_uuid,
        "name": "",
        "include_conversation_preferences": True,
        "is_temporary": True,
    }
    try:
        r = session.post(
            url,
            json=body,
            headers={"Cookie": cookie},
            timeout=TIMEOUT_SECONDS,
        )
    except CffiError as e:
        raise APIError(f"network error: {e}", EXIT_NETWORK) from e

    if _maybe_auth_error(r.status_code):
        raise APIError("auth expired — update session key", EXIT_AUTH)
    if r.status_code not in (200, 201):
        snippet = (r.text or "")[:200]
        raise APIError(
            f"create conversation: HTTP {r.status_code}: {snippet}",
            EXIT_NETWORK,
        )
    return _extract_session_key_from_cookies(r.cookies)


def send_message_streaming(session, org_id: str, cookie: str, conv_uuid: str,
                           parse_usage: bool
                           ) -> tuple[str, dict | None, str | None]:
    """POST the prompt and parse the SSE stream line-by-line.

    Returns (reply_text, usage_dict_or_None, refreshed_session_key_or_None).
    """
    url = f"{API_BASE}/{org_id}/chat_conversations/{conv_uuid}/completion"
    tz_name = _local_iana_tz()
    locale = _system_locale()
    body = {
        "prompt": PROMPT,
        "parent_message_uuid": ROOT_PARENT_UUID,
        "model": MODEL,
        "timezone": tz_name,
        "attachments": [],
        "files": [],
        "tools": [],
        "rendering_mode": "messages",
        "sync_sources": [],
        "locale": locale,
    }
    headers = {
        "Cookie": cookie,
        "Accept": "text/event-stream",
    }

    reply = ""
    usage: dict | None = None
    new_key: str | None = None

    try:
        r = session.post(
            url, json=body, headers=headers,
            stream=True, timeout=TIMEOUT_SECONDS,
        )
    except CffiError as e:
        raise APIError(f"network error: {e}", EXIT_NETWORK) from e

    try:
        if _maybe_auth_error(r.status_code):
            raise APIError("auth expired — update session key", EXIT_AUTH)
        if r.status_code != 200:
            snippet = (r.text or "")[:200]
            raise APIError(
                f"send message: HTTP {r.status_code}: {snippet}",
                EXIT_NETWORK,
            )

        new_key = _extract_session_key_from_cookies(r.cookies)
        current_event = ""
        expecting_data = False
        for raw in r.iter_lines():
            line = (raw.decode("utf-8", errors="replace")
                    if isinstance(raw, (bytes, bytearray)) else raw)
            stripped = line.strip() if line else ""
            if stripped.startswith("event:"):
                current_event = stripped[len("event:"):].strip()
                expecting_data = False
            elif stripped.startswith("data:"):
                payload = stripped[len("data:"):]
                if payload.startswith(" "):
                    payload = payload[1:]
                if not payload:
                    expecting_data = True
                else:
                    reply, usage = _process_sse_event(
                        current_event, payload, reply, usage, parse_usage)
                    expecting_data = False
            elif expecting_data and stripped:
                reply, usage = _process_sse_event(
                    current_event, stripped, reply, usage, parse_usage)
                expecting_data = False
            elif not stripped:
                expecting_data = False
    finally:
        try:
            r.close()
        except Exception:
            pass

    return reply, usage, new_key


def _process_sse_event(event: str, json_payload: str,
                       reply: str, usage: dict | None,
                       parse_usage: bool
                       ) -> tuple[str, dict | None]:
    try:
        obj = json.loads(json_payload)
    except ValueError:
        return reply, usage

    if event == "content_block_delta":
        delta = obj.get("delta") or {}
        text = delta.get("text")
        if isinstance(text, str):
            reply += text
    elif event == "message_limit" and parse_usage:
        usage = _parse_message_limit(obj) or usage
    elif event == "error":
        msg = obj.get("error") or obj.get("message")
        if isinstance(msg, str):
            reply = f"Error: {msg}"
    return reply, usage


def _normalize_resets_at(raw) -> str | None:
    """Coerce resets_at (unix timestamp int/float/str OR ISO string) to ISO."""
    if raw is None:
        return None
    if isinstance(raw, str):
        # try numeric-string
        try:
            return datetime.fromtimestamp(float(raw),
                                          tz=timezone.utc).isoformat()
        except ValueError:
            return raw  # already ISO
    if isinstance(raw, (int, float)):
        try:
            return datetime.fromtimestamp(float(raw),
                                          tz=timezone.utc).isoformat()
        except (OverflowError, OSError, ValueError):
            return None
    return None


def _parse_message_limit(obj: dict) -> dict | None:
    """Pull the windows shape out of a message_limit event payload."""
    limit_obj = obj.get("message_limit") if isinstance(
        obj.get("message_limit"), dict) else obj
    windows = limit_obj.get("windows") if isinstance(
        limit_obj.get("windows"), dict) else None
    if not windows:
        return None

    def window(key: str) -> dict | None:
        w = windows.get(key)
        if not isinstance(w, dict):
            return None
        util = w.get("utilization")
        resets_at_raw = w.get("resets_at")
        if util is None and resets_at_raw is None:
            return None
        return {
            "util": float(util) if util is not None else None,
            "resets_at": _normalize_resets_at(resets_at_raw),
        }

    out: dict = {}
    for key in ("5h", "7d", "overage"):
        w = window(key)
        if w:
            out[key] = w
    return out or None


def delete_conversation(session, org_id: str, cookie: str,
                        conv_uuid: str) -> None:
    """Best-effort cleanup. Swallow all errors."""
    url = f"{API_BASE}/{org_id}/chat_conversations/{conv_uuid}"
    try:
        session.delete(url, headers={"Cookie": cookie}, timeout=10)
    except Exception:
        pass


# ---- formatting ------------------------------------------------------------


def _fmt_relative(target_iso: str | None) -> str | None:
    if not target_iso:
        return None
    try:
        # tolerate trailing "Z"
        s = target_iso.replace("Z", "+00:00")
        target = datetime.fromisoformat(s)
    except ValueError:
        return None
    now = datetime.now(timezone.utc)
    if target.tzinfo is None:
        target = target.replace(tzinfo=timezone.utc)
    delta = target - now
    secs = int(delta.total_seconds())
    if secs < 0:
        return "now"
    days, rem = divmod(secs, 86400)
    hours, rem = divmod(rem, 3600)
    minutes = rem // 60
    if days:
        return f"{days}d {hours:02d}h"
    return f"{hours}h {minutes:02d}m"


def _fmt_local(target_iso: str | None) -> str | None:
    if not target_iso:
        return None
    try:
        s = target_iso.replace("Z", "+00:00")
        target = datetime.fromisoformat(s)
    except ValueError:
        return None
    if target.tzinfo is None:
        target = target.replace(tzinfo=timezone.utc)
    local = target.astimezone()
    tz = local.tzname() or ""
    return local.strftime("%Y-%m-%d %H:%M") + (f" {tz}" if tz else "")


def print_human(ok: bool, duration_s: float, reply: str,
                usage: dict | None, error: str | None,
                source: str) -> None:
    if not ok:
        print(f"✗ Ping failed: {error}")
        return

    snippet = reply.strip().splitlines()[0] if reply.strip() else ""
    if len(snippet) > 60:
        snippet = snippet[:57] + "…"
    extra = f' — said "{PROMPT}", got "{snippet}"' if snippet else \
        f' — said "{PROMPT}"'
    print(f"✓ Ping ok ({duration_s:.2f}s){extra}")
    print(f"  creds source: {source}")

    if not usage:
        return
    print()
    labels = {"5h": "5-hour window", "7d": "7-day window ",
              "overage": "Overage      "}
    for key in ("5h", "7d", "overage"):
        w = usage.get(key)
        if not w:
            continue
        util = w.get("util")
        pct = f"{util * 100:5.1f}% used" if util is not None else "    n/a"
        rel = _fmt_relative(w.get("resets_at"))
        absolute = _fmt_local(w.get("resets_at"))
        when = ""
        if rel and absolute:
            when = f"  →  resets in {rel}  ({absolute})"
        print(f"  {labels[key]}: {pct}{when}")


def _build_result_record(ok: bool, duration_s: float, reply: str,
                         usage: dict | None, error: str | None,
                         source: str) -> dict:
    out = {
        "ts": datetime.now().astimezone().isoformat(timespec="seconds"),
        "ok": ok,
        "duration_s": round(duration_s, 3),
        "model": MODEL,
        "creds_source": source,
    }
    if ok:
        out["reply"] = reply.strip()
        if usage:
            out["windows"] = usage
    else:
        out["error"] = error or "unknown"
    return out


def print_json(ok: bool, duration_s: float, reply: str,
               usage: dict | None, error: str | None,
               source: str) -> None:
    record = _build_result_record(ok, duration_s, reply, usage, error, source)
    print(json.dumps(record, separators=(",", ":")))


# ---- ping execution (shared by `ping` and `schedule`) ----------------------


class PingOutcome:
    """Result of one ping attempt. Carries data only — never prints."""

    __slots__ = ("ok", "duration_s", "reply", "usage", "error",
                 "exit_code", "source", "unexpected")

    def __init__(self, ok: bool, duration_s: float, reply: str,
                 usage: dict | None, error: str | None,
                 exit_code: int, source: str, unexpected: bool = False):
        self.ok = ok
        self.duration_s = duration_s
        self.reply = reply
        self.usage = usage
        self.error = error
        self.exit_code = exit_code
        self.source = source
        self.unexpected = unexpected


def execute_ping(config: Config, parse_usage: bool) -> PingOutcome:
    """Run one ping end-to-end and return a PingOutcome. Pure: no printing.

    Shared by `cmd_ping` (one-shot CLI) and `cmd_schedule` (the scheduler),
    so there is a single network/ping code path. Callers must ensure
    curl_cffi is available (cffi_requests is not None) before calling.
    """
    cookie = f"sessionKey={config.session_key}"
    conv_uuid = uuid.uuid4().hex
    # claude.ai conversation UUIDs are typically formatted; the GUI uses lowercase
    # standard form. Either works, but match the Swift impl.
    conv_uuid = str(uuid.UUID(conv_uuid)).lower()

    started = time.monotonic()
    session = _make_session()
    try:
        new_key = create_conversation(session, config.org_id, cookie, conv_uuid)
        if new_key:
            cookie = f"sessionKey={new_key}"
        reply, usage, refreshed_key = send_message_streaming(
            session, config.org_id, cookie, conv_uuid,
            parse_usage=parse_usage,
        )
        delete_conversation(session, config.org_id, cookie, conv_uuid)
        duration = time.monotonic() - started

        latest_key = refreshed_key or new_key
        if latest_key:
            save_session_key(config, latest_key)

        return PingOutcome(True, duration, reply, usage, None,
                           EXIT_OK, config.source)
    except APIError as e:
        duration = time.monotonic() - started
        return PingOutcome(False, duration, "", None, str(e),
                           e.exit_code, config.source)
    except Exception as e:  # pragma: no cover — last-ditch safety net
        duration = time.monotonic() - started
        msg = f"unexpected error: {e.__class__.__name__}: {e}"
        return PingOutcome(False, duration, "", None, msg,
                           EXIT_PARSE, config.source, unexpected=True)


# ---- top level -------------------------------------------------------------


def cmd_ping(args: argparse.Namespace) -> int:
    if cffi_requests is None:
        msg = (
            "missing dependency: curl_cffi.\n"
            "claude.ai is fronted by Cloudflare, which blocks stdlib HTTP\n"
            "clients on TLS fingerprint. Install curl_cffi to fix:\n"
            "\n"
            "  python3 -m venv ~/.pingclaude/venv\n"
            "  ~/.pingclaude/venv/bin/pip install curl_cffi\n"
            "  ~/.pingclaude/venv/bin/python3 cli/pingclaude.py ping\n"
            "\n"
            "or, if your Python allows it:  pip install curl_cffi\n"
            "see cli/README.md for details."
        )
        if args.json:
            print_json(False, 0.0, "", None, msg, source="none")
        else:
            print(f"✗ {msg}", file=sys.stderr)
        return EXIT_MISSING_DEP

    config, attempted = load_config(args.config)
    if config is None:
        msg = (
            "no claude.ai credentials found. Tried:\n  - "
            + "\n  - ".join(attempted)
            + "\n\nset the env vars or create a config file. "
              "See cli/README.md for details."
        )
        if args.json:
            print_json(False, 0.0, "", None, msg, source="none")
        elif not args.quiet:
            print(f"✗ {msg}", file=sys.stderr)
        else:
            print(f"pingclaude: {msg.splitlines()[0]}", file=sys.stderr)
        return EXIT_CONFIG

    outcome = execute_ping(config, parse_usage=not args.no_usage)

    if outcome.ok:
        if args.json:
            print_json(True, outcome.duration_s, outcome.reply, outcome.usage,
                       None, source=outcome.source)
        elif not args.quiet:
            print_human(True, outcome.duration_s, outcome.reply, outcome.usage,
                        None, source=outcome.source)
        return EXIT_OK

    if args.json:
        print_json(False, outcome.duration_s, "", None, outcome.error,
                   source=outcome.source)
    elif outcome.unexpected:
        print(f"✗ {outcome.error}", file=sys.stderr)
    elif args.quiet:
        print(f"pingclaude: {outcome.error}", file=sys.stderr)
    else:
        print_human(False, outcome.duration_s, "", None, outcome.error,
                    source=outcome.source)
    return outcome.exit_code


# ---- scheduler (JSON-config-driven, always-on) -----------------------------

WEEKDAY_NAMES = {
    "mon": 0, "tue": 1, "wed": 2, "thu": 3, "fri": 4, "sat": 5, "sun": 6,
}


class ScheduleSettings:
    __slots__ = ("enabled", "times", "weekdays", "timezone", "catch_up", "path")

    def __init__(self, enabled: bool, times: list, weekdays: set,
                 timezone: str, catch_up: bool, path: str | None):
        self.enabled = enabled
        self.times = times          # list of (hour, minute)
        self.weekdays = weekdays    # set of ints 0-6 (Mon=0), matches datetime.weekday()
        self.timezone = timezone    # IANA name string
        self.catch_up = catch_up
        self.path = path


def _log(msg: str) -> None:
    """Timestamped line to stdout (captured by journald / launchd). Flushed."""
    ts = datetime.now().astimezone().isoformat(timespec="seconds")
    print(f"{ts} {msg}", flush=True)


def _parse_hhmm(value) -> tuple | None:
    if not isinstance(value, str):
        return None
    parts = value.strip().split(":")
    if len(parts) != 2:
        return None
    try:
        h, m = int(parts[0]), int(parts[1])
    except ValueError:
        return None
    if 0 <= h <= 23 and 0 <= m <= 59:
        return (h, m)
    return None


def load_schedule(explicit_path: str | None = None
                  ) -> tuple[ScheduleSettings, list[str]]:
    """Read the 'schedule' block from the JSON config. Lenient — returns safe
    defaults (disabled) on any problem and never raises, since this is re-read
    on every loop iteration and a half-saved edit must not kill the daemon."""
    attempted: list[str] = []
    default_tz = _local_iana_tz()
    disabled = ScheduleSettings(False, [], set(range(7)), default_tz, False, None)

    paths = [explicit_path] if explicit_path else CONFIG_PATHS
    data = None
    used_path = None
    for path in paths:
        if not path:
            continue
        attempted.append(path)
        if os.path.isfile(path):
            try:
                with open(path, "r") as f:
                    data = json.load(f)
                used_path = path
                break
            except (OSError, ValueError) as e:
                _log(f"warning: could not read {path}: {e}")

    if not isinstance(data, dict):
        return disabled, attempted

    block = data.get("schedule")
    if not isinstance(block, dict):
        return ScheduleSettings(False, [], set(range(7)), default_tz, False,
                                used_path), attempted

    enabled = bool(block.get("enabled", True))
    catch_up = bool(block.get("catch_up", False))

    times: list = []
    raw_times = block.get("times")
    if isinstance(raw_times, list):
        for entry in raw_times:
            hm = _parse_hhmm(entry)
            if hm is None:
                _log(f"warning: ignoring invalid schedule time {entry!r}")
            else:
                times.append(hm)

    raw_days = block.get("weekdays")
    if not raw_days:
        weekdays = set(range(7))            # default: all 7 days
    elif isinstance(raw_days, list):
        weekdays = set()
        for d in raw_days:
            idx = WEEKDAY_NAMES.get(str(d).strip().lower()[:3])
            if idx is None:
                _log(f"warning: ignoring invalid weekday {d!r}")
            else:
                weekdays.add(idx)
        if not weekdays:
            weekdays = set(range(7))
    else:
        weekdays = set(range(7))

    tz = block.get("timezone")
    if not isinstance(tz, str) or not tz.strip():
        tz = default_tz

    return ScheduleSettings(enabled, times, weekdays, tz.strip(), catch_up,
                            used_path), attempted


def _get_zoneinfo_class():
    try:
        from zoneinfo import ZoneInfo
        return ZoneInfo
    except ImportError:
        pass
    try:
        from backports.zoneinfo import ZoneInfo  # type: ignore
        return ZoneInfo
    except ImportError:
        return None


def _load_zoneinfo(tz_name: str):
    """Resolve tz_name to a tzinfo. Prefer stdlib zoneinfo (3.9+), then the
    backport, then fall back to the fixed system-local offset with a warning."""
    zi = _get_zoneinfo_class()
    if zi is None:
        _log(f"warning: zoneinfo unavailable (Python < 3.9); ignoring configured "
             f"timezone {tz_name!r} and using system-local time")
        return datetime.now().astimezone().tzinfo
    try:
        return zi(tz_name)
    except Exception as e:
        _log(f"warning: could not load timezone {tz_name!r} ({e}); "
             f"using system-local time")
        return datetime.now().astimezone().tzinfo


def _slot_key(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%d@%H:%M")


def _prune_fired(fired: set, now: datetime) -> None:
    """Drop fired keys older than yesterday (keep today + yesterday)."""
    cutoff = (now.date() - timedelta(days=1)).isoformat()
    stale = {k for k in fired if k.split("@", 1)[0] < cutoff}
    fired -= stale


def _due_slots_today(now: datetime, settings: ScheduleSettings, tz) -> list:
    """Allowed slot datetimes for now's local date whose time is <= now."""
    d = now.date()
    out: list = []
    if d.weekday() in settings.weekdays:
        for (h, m) in settings.times:
            cand = datetime(d.year, d.month, d.day, h, m, tzinfo=tz)
            if cand <= now:
                out.append(cand)
    return out


def _next_fire(now: datetime, settings: ScheduleSettings, tz) -> datetime | None:
    """Earliest scheduled datetime strictly after now, or None."""
    if not settings.enabled or not settings.times:
        return None
    best = None
    base = now.date()
    for offset in range(0, 9):
        d = base + timedelta(days=offset)
        if d.weekday() not in settings.weekdays:
            continue
        for (h, m) in settings.times:
            cand = datetime(d.year, d.month, d.day, h, m, tzinfo=tz)
            if cand > now and (best is None or cand < best):
                best = cand
    return best


def _append_history(path: str, line: str) -> None:
    try:
        p = os.path.expanduser(path)
        with open(p, "a") as f:
            f.write(line + "\n")
    except OSError as e:
        _log(f"warning: could not append history to {path}: {e}")


def _fire(slot: datetime, args: argparse.Namespace, fired: set) -> None:
    """Send one ping for a due slot. Never raises — a failure logs and the
    loop continues. Always marks the slot fired so it won't repeat today."""
    key = _slot_key(slot)
    if cffi_requests is None:
        _log(f"skip {key}: curl_cffi not installed — see cli/README.md")
        fired.add(key)
        return

    config, _attempted = load_config(args.config)
    if config is None:
        _log(f"skip {key}: no claude.ai credentials found")
        fired.add(key)
        return

    try:
        outcome = execute_ping(config, parse_usage=not args.no_usage)
    except Exception as e:  # pragma: no cover — execute_ping is already guarded
        _log(f"fire {key} crashed: {e.__class__.__name__}: {e}")
        fired.add(key)
        return

    record = json.dumps(
        _build_result_record(outcome.ok, outcome.duration_s, outcome.reply,
                             outcome.usage, outcome.error, outcome.source),
        separators=(",", ":"))
    if args.json:
        print(record, flush=True)
    if getattr(args, "history", None):
        _append_history(args.history, record)

    status = "ok" if outcome.ok else f"FAILED: {outcome.error}"
    _log(f"fired {key} -> {status}")
    fired.add(key)


def cmd_schedule(args: argparse.Namespace) -> int:
    _log(f"pingclaude scheduler starting (model {MODEL})")
    if cffi_requests is None:
        _log("warning: curl_cffi is not installed — pings will be skipped until "
             "it is available. See cli/README.md for install instructions.")

    fired: set = set()
    startup = True  # stays True until the first iteration while enabled+active
    last_next_key = None  # so we log "next fire" only when it changes
    try:
        while True:
            settings, _attempted = load_schedule(args.config)
            tz = _load_zoneinfo(settings.timezone)
            now = datetime.now(tz)
            _prune_fired(fired, now)

            if not settings.enabled or not settings.times:
                reason = "disabled" if not settings.enabled else "no times set"
                _log(f"scheduler idle ({reason}); re-checking config in 60s")
                time.sleep(60)
                continue

            due_unfired = [s for s in _due_slots_today(now, settings, tz)
                           if _slot_key(s) not in fired]

            if startup:
                if settings.catch_up and due_unfired:
                    latest = max(due_unfired)
                    _log(f"startup catch-up: firing most recent missed slot "
                         f"{_slot_key(latest)}")
                    for s in due_unfired:
                        if s is not latest:
                            fired.add(_slot_key(s))
                    _fire(latest, args, fired)
                elif due_unfired:
                    for s in due_unfired:
                        fired.add(_slot_key(s))
                    _log(f"startup: {len(due_unfired)} earlier slot(s) today "
                         f"already passed; skipping (catch_up is off)")
                startup = False
            elif due_unfired:
                latest = max(due_unfired)
                for s in due_unfired:
                    if s is not latest:
                        fired.add(_slot_key(s))
                _fire(latest, args, fired)

            nxt = _next_fire(now, settings, tz)
            if nxt is not None:
                nxt_key = _slot_key(nxt)
                if nxt_key != last_next_key:
                    _log(f"next fire scheduled for {nxt_key}")
                    last_next_key = nxt_key
                delay = (nxt - now).total_seconds()
            else:
                delay = 60.0
            # Cap at 60s so we stay resilient to suspend/resume, clock jumps,
            # and DST shifts; re-reads config and re-checks slots each wake.
            time.sleep(max(1.0, min(delay, 60.0)))
    except KeyboardInterrupt:
        _log("scheduler stopping (interrupt)")
        return EXIT_OK


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="pingclaude",
        description=(
            "Lightweight cross-platform ping for the claude.ai 5-hour usage "
            "window. Sends one short message to claude.ai (using your web "
            "account, NOT the developer API) and prints the result."
        ),
        epilog=(
            "commands:\n"
            "  ping      send one ping and exit (for cron / ad-hoc use)\n"
            "  schedule  always-on loop that pings at the times in your config's\n"
            "            \"schedule\" block (run under systemd / launchd)\n"
            "\ncredentials (priority high → low):\n"
            f"  1. env vars  {ENV_SESSION_KEY}, {ENV_ORG_ID}\n"
            "  2. config    ~/.config/pingclaude/config.json (chmod 600)\n"
            "  3. macOS     ~/Library/Preferences/com.pingclaude.app.plist\n"
            "\nSee cli/README.md for setup, scheduling, and exit codes."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = parser.add_subparsers(dest="command", metavar="COMMAND")
    p_ping = sub.add_parser(
        "ping",
        help="send one ping and print the result",
        description="Send one ping to claude.ai and print the result.",
    )
    p_ping.add_argument("--json", action="store_true",
                        help="emit a single JSON line (for cron logs)")
    p_ping.add_argument("--quiet", action="store_true",
                        help="silent on success; print + non-zero exit on failure")
    p_ping.add_argument("--no-usage", action="store_true",
                        help="skip parsing usage windows; just verify the ping")
    p_ping.add_argument("--config", metavar="PATH",
                        help="explicit config file path")
    p_ping.set_defaults(func=cmd_ping)

    p_sched = sub.add_parser(
        "schedule",
        help="run the always-on scheduler driven by the JSON config",
        description=(
            "Long-running loop that pings at the local wall-clock times listed "
            "in your config file's \"schedule\" block (7 days a week by "
            "default). Re-reads the config each cycle, so edits take effect "
            "within ~60s with no restart. Intended to run as a systemd or "
            f"launchd service on an always-on machine. Every ping uses {MODEL}."
        ),
        epilog=(
            "example \"schedule\" block in ~/.config/pingclaude/config.json:\n"
            '  "schedule": {\n'
            '    "enabled": true,\n'
            '    "times": ["06:00", "11:00"],\n'
            '    "weekdays": ["mon","tue","wed","thu","fri","sat","sun"],\n'
            '    "timezone": "America/New_York"\n'
            "  }\n"
            "\nSee cli/README.md → \"Scheduling via JSON config\"."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p_sched.add_argument("--json", action="store_true",
                         help="print a JSON record to stdout on each fire")
    p_sched.add_argument("--no-usage", action="store_true",
                         help="skip parsing usage windows on each fire")
    p_sched.add_argument("--config", metavar="PATH",
                         help="explicit config file path")
    p_sched.add_argument("--history", metavar="PATH",
                         help="also append each fire's JSON record to this file")
    p_sched.set_defaults(func=cmd_schedule)
    return parser


def main(argv: list[str]) -> int:
    parser = build_parser()
    if not argv:
        parser.print_help()
        return EXIT_OK
    args = parser.parse_args(argv)
    if not getattr(args, "func", None):
        parser.print_help()
        return EXIT_OK
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

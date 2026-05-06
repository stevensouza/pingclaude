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
from datetime import datetime, timezone

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


def print_json(ok: bool, duration_s: float, reply: str,
               usage: dict | None, error: str | None,
               source: str) -> None:
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
    print(json.dumps(out, separators=(",", ":")))


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
            parse_usage=not args.no_usage,
        )
        delete_conversation(session, config.org_id, cookie, conv_uuid)
        duration = time.monotonic() - started

        latest_key = refreshed_key or new_key
        if latest_key:
            save_session_key(config, latest_key)

        if args.json:
            print_json(True, duration, reply, usage, None,
                       source=config.source)
        elif not args.quiet:
            print_human(True, duration, reply, usage, None,
                        source=config.source)
        return EXIT_OK

    except APIError as e:
        duration = time.monotonic() - started
        if args.json:
            print_json(False, duration, "", None, str(e),
                       source=config.source)
        elif args.quiet:
            print(f"pingclaude: {e}", file=sys.stderr)
        else:
            print_human(False, duration, "", None, str(e),
                        source=config.source)
        return e.exit_code
    except Exception as e:  # pragma: no cover — last-ditch safety net
        duration = time.monotonic() - started
        msg = f"unexpected error: {e.__class__.__name__}: {e}"
        if args.json:
            print_json(False, duration, "", None, msg, source=config.source)
        else:
            print(f"✗ {msg}", file=sys.stderr)
        return EXIT_PARSE


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="pingclaude",
        description=(
            "Lightweight cross-platform ping for the claude.ai 5-hour usage "
            "window. Sends one short message to claude.ai (using your web "
            "account, NOT the developer API) and prints the result."
        ),
        epilog=(
            "credentials (priority high → low):\n"
            f"  1. env vars  {ENV_SESSION_KEY}, {ENV_ORG_ID}\n"
            "  2. config    ~/.config/pingclaude/config.json (chmod 600)\n"
            "  3. macOS     ~/Library/Preferences/com.pingclaude.app.plist\n"
            "\nSee cli/README.md for setup, cron examples, and exit codes."
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

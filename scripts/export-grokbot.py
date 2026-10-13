#!/usr/bin/env python3
"""Export the local Grok Bot app cache to an agentapp-bot-bundle/v1 folder.

Reads `~/Library/Application Support/Grok Bot/sand-client-persistence/*.blob` (read-only) and writes
`~/Documents/Torvli Grok Export/` (dirs 0700, files 0600). Python 3 stdlib only; no network.
Only counts are printed; message text never leaves the export files.
"""
import argparse
import base64
import binascii
import json
import os
import re
import shutil
import sys
import tempfile
from datetime import datetime, timezone

FORMAT = "agentapp-bot-bundle/v1"
DEFAULT_CACHE = "~/Library/Application Support/Grok Bot/sand-client-persistence"
DEFAULT_OUT = "~/Documents/Torvli Grok Export"
HIDDEN_MARKER = re.compile(r"\[GROK_BOT_HIDDEN[A-Z_]*\]")
MARKER = "[REDACTED]"

# Ported from GrokTemplateParser.secretValuePatterns (Sources/AgentApp/TemplateImport/TemplateImport.swift).
SECRET_PATTERNS = [
    ("private_key", re.compile(r"(?s)-----BEGIN ([A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?)-----.*?(?:-----END \1-----[^\r\n]*(?:\r?\n|\Z)|\Z)")),
    ("bearer", re.compile(r"(?i)\b(bearer\s+)[A-Za-z0-9._~+/=-]{8,}")),
    ("vendor_token", re.compile(r"\b(sk|xox[baprs]|gh[pousr])[-_][A-Za-z0-9_-]{12,}\b")),
    ("github_pat", re.compile(r"github_pat_[A-Za-z0-9_-]+")),
    ("jwt", re.compile(r"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}")),
    ("aws_key", re.compile(r"AKIA[0-9A-Z]{16}")),
    ("google_key", re.compile(r"AIza[0-9A-Za-z_-]{35}")),
    ("slack_app_token", re.compile(r"xapp-[A-Za-z0-9_-]+")),
    ("slack_webhook", re.compile(r"https?://hooks\.slack\.com/services/[^\s]+")),
    ("url_credentials", re.compile(r"://[^/\s:@]+:[^/\s@]+@")),
    ("credential_assignment", re.compile(r"(?i)(?<![A-Za-z0-9])(api[_ -]?key|token|secret|password|credential|auth[_-]?token|access[_-]?token|client[_-]?secret|authorization)\s*[:=]\s*\S+")),
]
BASIC_AUTH = re.compile(r"(?i)\bBasic\s+([A-Za-z0-9+/]{4,}={0,2})(?![A-Za-z0-9+/=])")


class Redactor:
    def __init__(self):
        self.counts = {}

    @property
    def total(self):
        return sum(self.counts.values())

    def _hit(self, category, n=1):
        if n:
            self.counts[category] = self.counts.get(category, 0) + n

    def __call__(self, text):
        if text is None:
            return None

        def basic(match):
            try:
                decoded = base64.b64decode(match.group(1), validate=True).decode("utf-8")
            except (binascii.Error, UnicodeDecodeError, ValueError):
                return match.group(0)
            if ":" not in decoded:
                return match.group(0)
            self._hit("basic_auth")
            return MARKER

        text = BASIC_AUTH.sub(basic, text)
        for category, pattern in SECRET_PATTERNS:
            # Re-apply until stable, like the Swift loop: a replacement can expose a new match.
            for _ in range(50):
                text, n = pattern.subn(MARKER, text)
                self._hit(category, n)
                if not n or category != "credential_assignment":
                    break
        return text

    def report(self):
        return {"total": self.total, "counts": dict(sorted(self.counts.items()))}


def decode_name(file_name):
    stem = file_name[: -len(".blob")]
    try:
        return base64.b32decode(stem.upper() + "=" * (-len(stem) % 8)).decode("utf-8")
    except (binascii.Error, UnicodeDecodeError, ValueError):
        return None


def slugify(name):
    return "-".join(re.findall(r"[a-z0-9]+", name.lower())) or "bot"


def profile_slug(name):
    """Roster name -> Hermes profile slug: lowercased, spaces to '-'."""
    return name.strip().lower().replace(" ", "-")


def iso(ms):
    if not isinstance(ms, int):
        return None
    return datetime.fromtimestamp(ms / 1000, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (ms % 1000)


def load_cache(cache_dir):
    if os.path.islink(cache_dir) or not os.path.isdir(cache_dir):
        raise SystemExit("Grok Bot cache not found: %s" % cache_dir)
    roster, transcripts = None, {}
    for file_name in sorted(os.listdir(cache_dir)):
        path = os.path.join(cache_dir, file_name)
        if not file_name.endswith(".blob") or os.path.islink(path):
            continue
        key = decode_name(file_name)
        if not key or not key.startswith("sand.client.slice.account."):
            continue
        if not (key.endswith(".roster.last-roster") or ".transcript.replicas." in key):
            continue
        with open(path, "r", encoding="utf-8") as handle:
            blob = json.load(handle)
        value = blob.get("value") if isinstance(blob, dict) else None
        if not isinstance(value, dict):
            raise SystemExit("Unexpected blob shape in %s" % file_name)
        if key.endswith(".roster.last-roster"):
            roster = value.get("rows") or []
        else:
            transcripts[key.rsplit(".", 1)[1]] = value.get("entries") or []
    if roster is None:
        raise SystemExit("No roster blob found in the Grok Bot cache.")
    return roster, transcripts


def card_text(message):
    """Visible text for a bot send-message card, or None when it is an internal card."""
    kind = message.get("type")
    if kind == "text":
        return message.get("content") or ""
    if kind == "widget":
        widget = message.get("widget") or {}
        lines = [widget.get("prompt") or message.get("content") or ""]
        lines += ["• " + (o.get("label") or o.get("value") or "") for o in widget.get("options") or []]
        return "\n".join(line for line in lines if line)
    if kind == "email-draft":
        draft = message.get("draft") or {}
        return "Email draft — %s\n\n%s" % (draft.get("subject") or "", draft.get("body") or "")
    if kind == "attachment":
        return "Attachment: %s" % (os.path.basename(message.get("file_name") or "") or message.get("alt") or "file")
    return None


def attachment_ref(message):
    name = message.get("file_name")
    if message.get("type") != "attachment" or not name:
        return []
    safe = re.sub(r"[^A-Za-z0-9._-]+", "_", os.path.basename(name)).lstrip(".") or "file"
    return [{"file": "attachments/" + safe, "available": False}]


def map_entries(bot_id, bot_name, entries, names, redact, stats):
    messages, events = [], []
    for entry in entries:
        kind, seq, entry_id = entry.get("kind"), entry.get("seq"), entry.get("id")
        if not isinstance(seq, int) or not isinstance(entry_id, str):
            stats["tool_entries_dropped"] += 1
            continue
        base = {"id": entry_id, "seq": seq, "timestamp": iso(entry.get("timestampMs")), "thread": None,
                "reply_to": entry.get("replyTo") if isinstance(entry.get("replyTo"), str) else None,
                "attachments": [], "hidden": False, "channel": "chat", "to": None}
        if kind == "message" and entry.get("role") == "user" and "fromAgent" not in entry:
            base.update(role="user", author=None, text=redact(entry.get("content") or ""))
        elif kind == "message" and entry.get("role") == "user":
            sender = entry["fromAgent"]
            base.update(role="assistant", channel="agent", text=redact(entry.get("content") or ""),
                        author=redact(names.get(sender.get("id"), sender.get("name") or "Agent")), to=redact(bot_name))
        elif kind == "message" and entry.get("role") == "assistant" and "toAgent" in entry:
            target = entry["toAgent"]
            base.update(role="assistant", channel="agent", author=redact(bot_name), text=redact(entry.get("content") or ""),
                        to=redact(names.get(target.get("id"), target.get("name") or "Agent")))
        elif kind == "send-message":
            message = entry.get("message") or {}
            text = card_text(message)
            if text is None:
                stats["cards_dropped"] += 1
                continue
            author = entry.get("author") or {}
            base.update(role="assistant", text=redact(text), attachments=attachment_ref(message),
                        author=redact(names.get(author.get("id"), author.get("name")) if author else bot_name))
        elif kind == "notice":
            base.update(role="system", author=None, text=redact(entry.get("text") or ""))
        elif kind == "event":
            event = entry.get("event") or {}
            if event.get("type") == "name-changed" and isinstance(event.get("from"), str) and isinstance(event.get("to"), str):
                events.append({"id": entry_id, "seq": seq, "timestamp_ms": entry.get("timestampMs"),
                               "event": {"type": "name-changed", "from": redact(event["from"]), "to": redact(event["to"])}})
            else:
                stats["events_dropped"] += 1
            continue
        else:
            # Tool calls, reasoning and injected context are internal; never exported.
            stats["tool_entries_dropped"] += 1
            continue
        if not base["text"].strip() and not base["attachments"]:
            stats["tool_entries_dropped"] += 1
            continue
        base["hidden"] = bool(HIDDEN_MARKER.search(base["text"]))
        messages.append(base)
    messages.sort(key=lambda m: m["seq"])
    events.sort(key=lambda e: e["seq"])
    return messages, events


def avatar_value(value):
    return value.strip() if isinstance(value, str) and value.strip() else None


def build_bundle(row, entries, names, slugs):
    redact = Redactor()
    stats = {"transcript_rows": len(entries), "messages": 0, "events": 0, "tool_entries_dropped": 0,
             "events_dropped": 0, "cards_dropped": 0, "hidden_messages": 0}
    name = redact(row.get("name") or "Grok bot")
    is_group = bool(row.get("isGroup"))
    messages, events = map_entries(row["id"], name, entries, names, redact, stats)
    stats["messages"], stats["events"] = len(messages), len(events)
    stats["hidden_messages"] = sum(1 for m in messages if m["hidden"])
    description = redact(row.get("description") or "")
    profile = None if is_group else "grok-" + slugs[row["id"]]
    members = [{"source_id": mid, "name": redact(names.get(mid, "Unknown bot")),
                "profile": ("grok-" + slugs[mid]) if mid in slugs else None} for mid in row.get("memberIds") or []]
    limitations = ["The Grok Bot app cache holds only the latest entries of each conversation; older history stays on Grok's servers."]
    if stats["cards_dropped"]:
        limitations.append("Interactive cards (secret requests, connectors, forms, approvals) were not exported.")
    if stats["events_dropped"]:
        limitations.append("Automation lifecycle events were not exported.")
    bundle = {
        "format": FORMAT, "source_id": row["id"], "slug": slugs.get(row["id"]) or slugify(name), "name": name,
        "description": description, "title": redact(row.get("title") or ""),
        "avatar": {"shape": avatar_value(row.get("avatarShape")), "colour": avatar_value(row.get("avatarColor"))},
        "instructions": description or None, "instructions_source": "profile.description" if description else None,
        "profile": profile, "is_group": is_group, "members": members,
        "memory_facts": [], "routines": [], "skills": [], "messages": messages, "events": events,
        "source": {"created_at_ms": row.get("createdAt") if isinstance(row.get("createdAt"), int) else None,
                   "harness": row.get("harness") if isinstance(row.get("harness"), str) else None,
                   "notify_on_agent_updates": row.get("notifyOnUpdatesEnabled") if isinstance(row.get("notifyOnUpdatesEnabled"), bool) else None,
                   "hidden_from_sidebar": bool(row.get("isHiddenFromSidebar"))},
        "limitations": limitations, "statistics": stats, "redactions": redact.report(),
    }
    return bundle


def write_json(path, value):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(value, handle, ensure_ascii=False, indent=1)
        handle.write("\n")


def export(cache_dir, out_dir):
    roster, transcripts = load_cache(cache_dir)
    rows = [r for r in roster if isinstance(r, dict) and isinstance(r.get("id"), str)]
    names = {r["id"]: r.get("name") or "Grok bot" for r in rows}
    slugs = {r["id"]: profile_slug(r.get("name") or "") for r in rows if not r.get("isGroup")}
    parent = os.path.dirname(os.path.abspath(out_dir))
    os.makedirs(parent, exist_ok=True)
    tmp = tempfile.mkdtemp(prefix=".torvli-grok-export-", dir=parent)
    os.chmod(tmp, 0o700)
    try:
        index = {"format": FORMAT, "generator": "export-grokbot.py", "source": "grok-bot-app-cache",
                 "bots": [], "skills": [], "skill_redactions": {"total": 0, "counts": {}}}
        report = {"bots": {}}
        for row in rows:
            bundle = build_bundle(row, transcripts.get(row["id"], []), names, slugs)
            directory = "%s-%s" % (slugify(row.get("name") or "bot"), row["id"])
            os.mkdir(os.path.join(tmp, directory), 0o700)
            write_json(os.path.join(tmp, directory, "bundle.json"), bundle)
            index["bots"].append({"source_id": row["id"], "name": bundle["name"], "bundle": directory + "/bundle.json",
                                  "profile": bundle["profile"], "is_group": bundle["is_group"],
                                  "messages": len(bundle["messages"]), "events": len(bundle["events"]),
                                  "redactions": bundle["redactions"]["total"]})
            report["bots"][row["id"]] = {"redactions": bundle["redactions"], "statistics": bundle["statistics"]}
        write_json(os.path.join(tmp, "index.json"), index)
        write_json(os.path.join(tmp, "redaction-report.json"), report)
        old = None
        if os.path.lexists(out_dir):
            old = out_dir.rstrip("/") + ".old-%d" % os.getpid()
            os.rename(out_dir, old)
        os.rename(tmp, out_dir)
        if old:
            shutil.rmtree(old)
    except BaseException:
        shutil.rmtree(tmp, ignore_errors=True)
        raise
    return index


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--cache", default=os.path.expanduser(DEFAULT_CACHE))
    parser.add_argument("--out", default=os.path.expanduser(DEFAULT_OUT))
    args = parser.parse_args(argv)
    index = export(args.cache, args.out)
    for bot in index["bots"]:
        print("%-24s profile=%-26s messages=%4d events=%d redactions=%d" % (
            bot["name"][:24], bot["profile"] or "(group)", bot["messages"], bot["events"], bot["redactions"]))
    print("bots=%d messages=%d -> %s" % (len(index["bots"]), sum(b["messages"] for b in index["bots"]), args.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())

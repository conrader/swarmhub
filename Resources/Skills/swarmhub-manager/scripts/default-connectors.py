#!/usr/bin/env python3
"""Swarm Hub's new-bot defaults, explicit per-bot opt-in, and read-only audit/diagnostics.

Optional ~/.config/swarmhub/default-connectors.json adds references, never credentials:
{"connectors": [{"name": "docs", "source": "~/.hermes/config.yaml",
                 "server": "docs", "tools": ["search", "read_page"]}]}
Sources may be Hermes YAML or MCPorter JSON. Only explicit tool names are accepted.
SB always uses the existing forced-command wiki SSH identity, never the messaging MCP.
"""
import argparse
import copy
from contextlib import closing
import json
import os
from pathlib import Path
import re
import sqlite3
import shutil
import subprocess
import tempfile
import threading
import sys
from datetime import datetime, timezone


SB_TOOLS = ["wiki_list", "wiki_page", "wiki_search", "wiki_semantic_search", "wiki_status"]
SLUG = re.compile(r"[a-z0-9][a-z0-9_-]{0,63}\Z")
# Hermes state.db drifts: schema 14 and 26 (0.20.x) have no sessions.tool_names; 31 stores a hash into system_prompts.
CATALOG_UNAVAILABLE = "This Hermes version does not record tool catalogs; load state comes from its logs only."
CATALOG_UNREADABLE = "This bot's session database could not be read (locked or changed format); load state comes from its logs only."
CATALOG_UNRECOGNISED = "This bot's latest tool catalog has an unrecognised format; load state comes from its logs only."


def read_config(path):
    if path.suffix in (".json", ".jsonc", ".json5"):
        try:
            return json.loads(path.read_text())
        except json.JSONDecodeError:
            import json5  # OpenClaw permits JSON5. Missing optional support fails closed in the CLI.
            return json5.loads(path.read_text())
    import yaml
    return yaml.safe_load(path.read_text()) or {}


def atomic_write(path, text):
    # Credentials in unrelated existing config fields must remain private too.
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".swarmhub-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def defaults(home):
    ssh = home / ".ssh"
    sb = {"command": "ssh", "args": [
        "-T", "-i", str(ssh / "sb_mcp_ed25519"), "-p", "49123",
        "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes",
        "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=" + str(ssh / "known_hosts"),
        "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=30", "ubuntu@145.239.94.119"],
        "connect_timeout": 60, "tools": {"include": SB_TOOLS}}
    result = {"sb": sb}
    policy = home / ".config/swarmhub/default-connectors.json"
    if not policy.exists():
        return result
    for item in json.loads(policy.read_text())["connectors"]:
        name, tools = item["name"], item["tools"]
        if not SLUG.fullmatch(name) or name == "sb" or name in result:
            raise ValueError("Invalid or duplicate default connector name")
        if not tools or not all(isinstance(t, str) and re.fullmatch(r"[A-Za-z0-9_-]+", t) for t in tools):
            raise ValueError("Default connectors require explicit read-only tool names")
        raw = item["source"]
        source = home / raw[2:] if raw.startswith("~/") else Path(raw)
        # Only the reference: the upstream entry (env, headers, args) stays in its source file.
        result[name] = {"_source": str(source.resolve()), "_server": item["server"], "_tools": tools}
    return result


def reference(entry, root):
    """The stdio adapter entry for an additional default, or (None, visible reason). Credentials are never copied."""
    try:
        config = read_config(Path(entry["_source"]))
        upstream = config.get("mcp_servers", config.get("mcpServers", {}))[entry["_server"]]
    except Exception:
        # Source errors can echo secrets; report a fixed reason.
        return None, "Default connector source or server cannot be read on this computer."
    if not isinstance(upstream, dict) or not upstream.get("command") or upstream.get("url"):
        return None, "Not copied: only stdio default connectors can be referenced without copying their credentials."
    return {"command": "python3", "args": [str(root / "swarmhub-connectors.py"), "proxy",
            entry["_source"], entry["_server"], json.dumps(entry["_tools"])]}, None


def openclaw_workspaces(home):
    """Read both current and legacy local inventories; never query or edit the Gateway."""
    state = home / ".openclaw"
    result = {p.name[len("workspace-"):]: p for p in state.glob("workspace-*")
              if p.is_dir() and SLUG.fullmatch(p.name[len("workspace-"):])}
    path = state / "openclaw.json"
    agents = read_config(path).get("agents", {}) if path.exists() else {}
    defaults_config = agents.get("defaults", {})
    entries = dict(agents.get("entries", {}))
    for item in agents.get("list", []):
        entries.setdefault(item["id"], item)
    if any(not isinstance(name, str) or not SLUG.fullmatch(name) or not isinstance(item, dict)
           for name, item in entries.items()):
        raise ValueError("Invalid agent inventory")

    def workspace(raw):
        if not isinstance(raw, str):
            raise ValueError("Invalid workspace path")
        value = home / raw[2:] if raw.startswith("~/") else Path(raw)
        if not value.is_absolute():
            raise ValueError("Workspace paths must be absolute or home-relative")
        return value

    default_workspace = workspace(defaults_config["workspace"]) if "workspace" in defaults_config else state / "workspace"
    marked = [name for name, item in entries.items() if item.get("default") is True]
    if "entries" in agents:
        # Current keyed inventories have no implicit first/main owner when several agents exist.
        owner = (marked[0] if agents.get("ownership") != "explicit" and len(marked) == 1 else
                 next(iter(entries)) if len(entries) == 1 else None)
    else:
        # Older list inventories used the marked, main, or first agent as their default owner.
        owner = marked[0] if len(marked) == 1 else "main" if "main" in entries else next(iter(entries), "main")
    for name, item in entries.items():
        result[name] = (workspace(item["workspace"]) if "workspace" in item else
                        default_workspace if name == owner else
                        default_workspace / name if "workspace" in defaults_config else state / ("workspace-" + name))
    if not entries and "entries" not in agents and "list" not in agents and default_workspace.is_dir():
        result.setdefault("main", default_workspace)
    return result


def location(home, backend, bot):
    if not SLUG.fullmatch(bot):
        raise ValueError("Invalid bot name")
    if backend == "hermes":
        return home / ".hermes" if bot == "default" else home / ".hermes/profiles" / bot
    return openclaw_workspaces(home).get(bot, home / (".openclaw/workspace-" + bot))


def config_path(home, backend, bot):
    return location(home, backend, bot) / ("config.yaml" if backend == "hermes" else "config/mcporter.json")


def writable_root(home, backend, bot):
    root = location(home, backend, bot)
    # A bot/workspace symlink must not redirect a one-bot write into another bot's directory.
    if root.is_symlink() or (backend == "openclaw" and (root / "config").is_symlink()):
        raise ValueError("Bot directory must not redirect to another workspace")
    if backend == "openclaw" and any(name != bot and other.resolve() == root.resolve()
                                     for name, other in openclaw_workspaces(home).items()):
        raise ValueError("Shared workspaces cannot be modified for only one bot")
    return root


def create(home, backend, bot, description=""):
    """Create without cloning manager config, .env, auth files or skills containing credentials."""
    root = writable_root(home, backend, bot)
    if bot == "default" or root.exists():
        raise ValueError("Only a fresh bot may be created")
    defaults(home)  # Validate policy before invoking either backend.
    command = (["hermes", "profile", "create", bot, "--no-alias", "--description", description]
               if backend == "hermes" else
               ["openclaw", "agents", "add", bot, "--workspace", str(root), "--non-interactive", "--json"])
    # CLI errors/output can include configuration; never forward them to a model reply.
    subprocess.run(command, check=True, capture_output=True, cwd=home)
    if not root.is_dir() or root.is_symlink():
        raise ValueError("Backend did not create the expected bot directory")
    atomic_write(root / ".swarmhub-new-bot", "defaults-only-v1\n")
    return provision(home, backend, bot)


def provision(home, backend, bot):
    if bot == "default":
        raise ValueError("Connector defaults provision new bots only")
    root = writable_root(home, backend, bot)
    if not root.is_dir():
        raise ValueError("New bot directory does not exist")
    marker = root / ".swarmhub-connectors.json"
    pending = root / ".swarmhub-new-bot"
    # Old bots (including bots provisioned before this policy) are never migrated or narrowed.
    # A retry after successful provisioning also preserves subsequent explicit opt-ins.
    if not pending.is_file():
        if marker.is_file():
            return json.loads(marker.read_text())
        raise ValueError("Existing bots are not reprovisioned; use explicit opt-in")
    entries = defaults(home)
    # SB is enforced read-only by the remote forced command. Additional defaults run through our narrow stdio
    # adapter, which reads the upstream entry from its source at launch and filters listing and calls.
    configured, skipped = {}, {}
    for name, entry in entries.items():
        if name == "sb":
            configured[name] = dict(entry) if backend == "hermes" else {k: v for k, v in entry.items() if k in ("command", "args")}
            continue
        server, reason = reference(entry, root)
        if server is None:
            skipped[name] = reason
            continue
        if backend == "hermes":
            server["tools"] = {"include": entry["_tools"]}
        configured[name] = server
    if len(configured) > 1:
        atomic_write(root / "swarmhub-connectors.py", Path(__file__).read_text())
    if backend == "hermes":
        import yaml
        path = root / "config.yaml"
        config = read_config(path) if path.exists() else {}
        servers = config.setdefault("mcp_servers", {})
    else:
        # OpenClaw's MCPorter skill resolves config relative to the agent's workspace.
        # This does not touch the Gateway config, auth profiles, or another agent's workspace.
        path = root / "config/mcporter.json"
        config = read_config(path) if path.exists() else {"mcpServers": {}, "imports": []}
        servers = config.setdefault("mcpServers", {})
    for name in skipped:
        # A clone may also carry a full copy of a default we refused to reference, with its credentials and
        # every tool, under either the default's name or its source server's name. Remove both inherited
        # entries before installing defaults: an alias may share its name with a successfully narrowed default.
        removed = False
        for inherited_name in (name, entries[name]["_server"]):
            if isinstance(inherited_name, str) and servers.pop(inherited_name, None) is not None:
                removed = True
        if removed:
            skipped[name] += " The copy inherited from the manager was removed from this bot."
    # Replace the complete connector map for a newly created bot, never merge manager connectors.
    # Clear MCPorter's imported catalogs too; they can otherwise reintroduce manager credentials.
    config["mcp_servers" if backend == "hermes" else "mcpServers"] = configured
    if backend == "openclaw":
        config["imports"] = []
    if backend == "hermes":
        atomic_write(path, yaml.safe_dump(config, sort_keys=False, allow_unicode=True))
    else:
        atomic_write(path, json.dumps(config, indent=2) + "\n")
    report = {"op": "connectors", "name": bot, "policy": "defaults-only-v1", "isolated_config": backend == "openclaw", "list": [
        {"name": name, "state": "never_attempted", "detail": "Configured; awaiting the bot's first tool load."}
        if name not in skipped else {"name": name, "state": "failed", "detail": skipped[name]}
        for name in entries]}
    for row in report["list"]:
        if row["name"] in skipped:
            continue
        if row["name"] == "sb" and not (home / ".ssh/sb_mcp_ed25519").is_file():
            row.update(state="failed", detail="Existing read-only SB SSH identity is missing on this computer.")
        elif row["name"] == "sb" and not (home / ".ssh/known_hosts").is_file():
            row.update(state="failed", detail="SB SSH known_hosts file is missing on this computer.")
        if backend == "openclaw" and not shutil.which("mcporter"):
            row.update(state="failed", detail="MCPorter is not installed on this computer.")
    atomic_write(marker, json.dumps(report) + "\n")
    pending.unlink()
    return report


def environment_values(paths):
    """Read dotenv values for explicit connector references, without copying a whole credentials file."""
    values = dict(os.environ)
    for path in paths:
        if not path.is_file():
            continue
        for line in path.read_text().splitlines():
            match = re.fullmatch(r"\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*", line)
            if not match:
                continue
            value = match[2]
            if value[:1] in ("'", '"'):
                if len(value) < 2 or value[-1] != value[0]:
                    raise ValueError("Unsupported dotenv quoting")
                value = value[1:-1]
            else:
                value = re.split(r"\s+#", value, maxsplit=1)[0]
            values[match[1]] = value
    return values


def connector_copy(entry, values):
    """Materialize only variables named by the selected connector. Never expand shell commands."""
    variable = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}|\$env:([A-Za-z_][A-Za-z0-9_]*)|\$([A-Za-z_][A-Za-z0-9_]*)")

    def expand(value):
        if isinstance(value, dict):
            return {key: expand(item) for key, item in value.items()}
        if isinstance(value, list):
            return [expand(item) for item in value]
        if isinstance(value, str):
            def replace(match):
                name = match[1] or match[3] or match[4]
                if match[2] is not None and not values.get(name):
                    return match[2]
                if name not in values:
                    raise ValueError("Selected connector references an unavailable variable")
                return values[name]
            return variable.sub(replace, value)
        return value
    return expand(copy.deepcopy(entry))


def opt_in(home, backend, bot, manager, connector, source_path=None):
    """Copy exactly one explicitly selected manager connector, including its own credentials."""
    if bot in ("default", manager) or not connector or not isinstance(connector, str):
        raise ValueError("Select one other bot and one connector")
    root = writable_root(home, backend, bot)
    path, source = config_path(home, backend, bot), config_path(home, backend, manager)
    if source_path is not None:
        raw = str(source_path)
        source = home / raw[2:] if raw.startswith("~/") else Path(raw)
    if not path.is_file() or path.resolve() == source.resolve():
        raise ValueError("Target bot configuration must already exist and differ from the manager")
    entries = defaults(home)
    if connector in entries or any(entry.get("_source") == str(source.resolve()) and
                                   entry.get("_server") == connector for entry in entries.values()):
        raise ValueError("Defaults must retain their read-only policy, including source aliases")
    key = "mcp_servers" if backend == "hermes" else "mcpServers"
    source_config = read_config(source)
    entry = source_config.get("mcp_servers", source_config.get("mcpServers", {}))[connector]
    endpoints = ("command", "url") if backend == "hermes" else ("command", "url", "baseUrl", "serverUrl")
    if not isinstance(entry, dict) or not any(entry.get(field) for field in endpoints):
        raise ValueError("Selected manager connector is not supported")
    values = environment_values([home / (".hermes/.env" if backend == "hermes" else ".openclaw/.env"),
                                 location(home, backend, manager) / ".env", source.parent / ".env"])
    selected = connector_copy(entry, values)
    config = read_config(path)
    servers = config.setdefault(key, {})
    if connector in servers:
        raise ValueError("Connector already exists on this bot; no overwrite performed")
    provenance = root / ".swarmhub-connector-sources.json"
    origins = json.loads(provenance.read_text()) if provenance.exists() else {}
    origins[connector] = str(source)
    servers[connector] = selected
    if backend == "hermes":
        import yaml
        text = yaml.safe_dump(config, sort_keys=False, allow_unicode=True)
    else:
        text = json.dumps(config, indent=2) + "\n"
    atomic_write(path, text)
    # Provenance contains paths and names only; credentials remain in this bot's private config.
    atomic_write(provenance, json.dumps(origins) + "\n")
    return {"op": "connectors", "name": bot, "list": [{"name": connector, "state": "never_attempted",
            "detail": "Explicitly added from the manager for this bot only; awaiting tool load."}]}


def audit(home, backend):
    """List non-default connector holdings. No discovery, subprocesses, writes, or live tool calls."""
    entries = defaults(home)
    bots = (["default"] + sorted(p.name for p in (home / ".hermes/profiles").glob("*") if SLUG.fullmatch(p.name))
            if backend == "hermes" else
            sorted(openclaw_workspaces(home)))
    rows, unresolved = [], []
    home_path = None
    if backend == "openclaw":
        directories = [home / ".mcporter"]
        xdg = os.environ.get("XDG_CONFIG_HOME", "")
        if xdg and Path(xdg).is_absolute():
            directories.insert(0, Path(xdg) / "mcporter")
        home_path = next((directory / file for directory in directories for file in ("mcporter.json", "mcporter.jsonc")
                          if (directory / file).is_file()), None)
    home_config = read_config(home_path) if home_path else {}
    for bot in bots:
        path = config_path(home, backend, bot)
        if not path.is_file() and backend == "hermes":
            continue
        config = read_config(path) if path.is_file() else {}
        root = location(home, backend, bot)
        provenance = root / ".swarmhub-connector-sources.json"
        origins = json.loads(provenance.read_text()) if provenance.exists() else {}
        servers = config.get("mcp_servers" if backend == "hermes" else "mcpServers", {})
        marker = root / ".swarmhub-connectors.json"
        isolated = (json.loads(marker.read_text()).get("isolated_config") is True) if marker.exists() else False
        if backend == "openclaw" and not isolated:
            for name in sorted(set(home_config.get("mcpServers", {})) - set(servers) - set(entries)):
                rows.append({"bot": bot, "connector": name, "source": str(home_path),
                             "config": str(path), "origin_known": False})
        for name in sorted(set(servers) - set(entries)):
            rows.append({"bot": bot, "connector": name, "source": origins.get(name, str(path)),
                         "config": str(path), "origin_known": name in origins})
        # Imported editor catalogs may contain secrets in their paths. Flag unresolved layers without echoing them.
        if backend == "openclaw":
            layers = [(path, config)] + ([(home_path, home_config)] if home_path and not isolated else [])
            for source, layer in layers:
                if layer.get("imports", ["defaults"]):
                    unresolved.append({"bot": bot, "source": str(source), "reason": "Imported editor catalogs were not expanded; review their connector holdings separately."})
            if not isolated:
                unresolved.append({"bot": bot, "source": str(path), "reason": "Legacy MCPorter invocation may use other environment-selected catalogs; only local and home files were inventoried."})
    return {"backend": backend, "bots_with_non_defaults": rows, "unresolved_catalogs": unresolved}


def catalog_tools(payload):
    # Schema 31 pin: {"version", "tools": [definitions]}; legacy inline pin: a JSON list of names or definitions.
    tools = payload.get("tools") if isinstance(payload, dict) else payload
    if not isinstance(tools, list):
        raise ValueError("Unrecognised tool catalog")
    names = set()
    for tool in tools:
        if isinstance(tool, str):
            tool = {"name": tool}
        if not isinstance(tool, dict):
            continue
        function = tool.get("function", tool)
        if not isinstance(function, dict):
            continue
        name = function.get("name", "")
        if not isinstance(name, str):
            continue
        if name.startswith("mcp__"):
            names.add(name)
        if name == "tool_search" and isinstance(function.get("description"), str):
            # Deferred tools appear in this description, not in the top-level array.
            names.update(re.findall(r"\bmcp__[A-Za-z0-9_-]+__[A-Za-z0-9_-]+", function["description"]))
    return names


def columns(connection, table):
    return {row[1] for row in connection.execute("SELECT * FROM pragma_table_info(?)", (table,))}


def catalog(root):
    """(per-server tool counts, catalog time, note). The note explains a missing catalog; it never raises on drift."""
    db = root / "state.db"
    if not db.exists():
        return {}, None, None
    try:
        # Read-only URI; never create or modify a production database.
        with closing(sqlite3.connect(db.resolve().as_uri() + "?mode=ro", uri=True)) as connection:
            if not {"tool_names", "started_at"} <= columns(connection, "sessions"):
                return {}, None, CATALOG_UNAVAILABLE
            # Schema 31 stores tool_names as the hash of a pin in system_prompts; older rows hold the list inline.
            joined = {"hash", "prompt"} <= columns(connection, "system_prompts")
            rows = connection.execute(
                ("SELECT s.tool_names, s.started_at, p.prompt FROM sessions s "
                 "LEFT JOIN system_prompts p ON p.hash = s.tool_names " if joined else
                 "SELECT s.tool_names, s.started_at, NULL FROM sessions s ") +
                "WHERE s.tool_names IS NOT NULL ORDER BY s.started_at DESC LIMIT 20").fetchall()
    except sqlite3.Error:
        return {}, None, CATALOG_UNREADABLE
    for names, timestamp, content in rows:
        # A pin hash whose row was swept resolves to itself and is skipped, as Hermes does.
        try:
            tools = catalog_tools(json.loads(content if content is not None else names))
            at = float(timestamp)
        except (TypeError, ValueError):
            continue
        servers = {n.split("__")[1] for n in tools}
        return {name: len([n for n in tools if n.startswith("mcp__" + name + "__")]) for name in servers}, at, None
    return {}, None, CATALOG_UNRECOGNISED if rows else None


def failure_reason(line):
    # Never return raw log text: remote exceptions can contain URLs, headers and tokens.
    text = line.lower()
    for needle, reason in [
        ("permission denied", "SSH authentication was rejected."),
        ("host key verification", "SSH host key verification failed."),
        ("timed out", "Connector connection timed out."),
        ("timeout", "Connector connection timed out."),
        ("no such file", "Connector executable or credential file is missing."),
        ("401", "Connector authentication was rejected (HTTP 401)."),
        ("403", "Connector access was refused (HTTP 403).")]:
        if needle in text:
            return reason
    return "Connector load failed. Check this bot's MCP logs on its computer."


def log_events(root):
    path = root / "logs/agent.log"
    if not path.exists():
        return {}
    events = {}
    with path.open(errors="replace") as stream:
        # Bounded tail; ordinary logs are not copied into the app or model reply.
        stream.seek(max(0, path.stat().st_size - 2_000_000))
        for line in stream:
            match = re.search(r"MCP server ['\"]([a-z0-9_-]+)['\"]", line)
            if not match:
                continue  # In particular, ignore the misleading aggregate '0 tools / cooldown' summary.
            try:
                stamp = datetime.strptime(line[:23], "%Y-%m-%d %H:%M:%S,%f").replace(tzinfo=timezone.utc).timestamp()
            except ValueError:
                continue
            name = match[1]
            registered = re.search(r"registered (\d+) tool", line)
            if registered:
                events[name] = (stamp, {"state": "loaded", "tool_count": int(registered[1]), "detail": "Last bot registration."})
            elif re.search(r"failed|error|could not|couldn't", line, re.I):
                events[name] = (stamp, {"state": "failed", "detail": failure_reason(line)})
    return events


def inspect(home, backend, bot):
    root = location(home, backend, bot)
    path = root / ("config.yaml" if backend == "hermes" else "config/mcporter.json")
    config = read_config(path)
    servers = config.get("mcp_servers", config.get("mcpServers", {}))
    names = sorted(set(servers) | set(defaults(home)))
    counts, at, note = catalog(root) if backend == "hermes" else ({}, None, None)
    events = log_events(root) if backend == "hermes" else {}
    initial = {}
    marker = root / ".swarmhub-connectors.json"
    if marker.exists() and not (root / "state.db").exists() and not (root / "logs/agent.log").exists():
        initial = {row["name"]: row for row in json.loads(marker.read_text())["list"]}
    rows = []
    for name in names:
        row = {"name": name, "state": "unknown", "detail": "No bot load evidence is available."}
        entry = servers.get(name)
        if entry is None:
            row.update(state="failed", detail="Default connector is missing from this bot's configuration.")
        elif entry.get("enabled") is False:
            row.update(state="disabled", detail="Connector is disabled for this bot.")
        else:
            if name in initial:
                row.update(initial[name])
            if name in events:
                event_at, event = events[name]
                row.update(event, observed_at=event_at)
            if name in counts and (name not in events or at >= events[name][0]):
                row.update(state="loaded", tool_count=counts[name], observed_at=at, detail="Last bot catalog (including deferred tools).")
            if backend == "openclaw":
                row.update(mcporter_status(root, name))
            if name == "sb" and row["state"] in ("unknown", "never_attempted"):
                if not (home / ".ssh/sb_mcp_ed25519").is_file():
                    row.update(state="failed", detail="Existing read-only SB SSH identity is missing on this computer.")
                elif not (home / ".ssh/known_hosts").is_file():
                    row.update(state="failed", detail="SB SSH known_hosts file is missing on this computer.")
            if note and row["state"] == "unknown":
                row["detail"] = note
        rows.append(row)
    return {"op": "connectors", "name": bot, "list": rows}


def mcporter_status(root, name):
    # Same path the new OpenClaw bot is instructed to use; discovery only, no tool calls.
    if not shutil.which("mcporter"):
        return {"state": "failed", "detail": "MCPorter is not installed on this computer."}
    try:
        result = subprocess.run(["mcporter", "--config", str(root / "config/mcporter.json"),
                                 "list", name, "--json", "--no-oauth", "--timeout", "15000"],
                                cwd=root, capture_output=True, text=True, check=False)
        payload = json.loads(result.stdout)
        if result.returncode == 0 and payload.get("status") == "ok" and isinstance(payload.get("tools"), list):
            return {"state": "loaded", "tool_count": len(payload["tools"]),
                    "observed_at": datetime.now(timezone.utc).timestamp(), "detail": "MCPorter discovery in this bot's workspace."}
        return {"state": "failed", "detail": failure_reason(str(payload.get("error", "")))}
    except (OSError, ValueError):
        return {"state": "failed", "detail": "MCPorter discovery failed. Check this bot's MCPorter setup."}


def proxy(source, server, tools):
    """MCPorter stdio adapter: schema filtering AND invocation enforcement, no shell."""
    config = read_config(Path(source))
    entry = config.get("mcp_servers", config.get("mcpServers", {}))[server]
    allowed = set(json.loads(tools))
    environment = os.environ.copy()
    environment.update({key: os.path.expandvars(str(value)) for key, value in entry.get("env", {}).items()})
    child = subprocess.Popen([entry["command"]] + entry.get("args", []), stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
                             cwd=os.path.expanduser(entry.get("cwd", str(Path(source).parent))), env=environment)
    lock = threading.Lock()

    def emit(message):
        with lock:
            print(json.dumps(message), flush=True)

    def responses():
        for line in child.stdout:
            try:
                message = json.loads(line)
                if isinstance(message.get("result"), dict) and "tools" in message["result"]:
                    message["result"]["tools"] = [tool for tool in message["result"]["tools"] if tool.get("name") in allowed]
                # Do not forward server-initiated sampling or elicitation requests.
                if "method" not in message or "id" not in message:
                    emit(message)
            except (ValueError, BrokenPipeError):
                continue

    threading.Thread(target=responses, daemon=True).start()
    safe_methods = {"initialize", "notifications/initialized", "notifications/cancelled", "ping", "tools/list"}
    try:
        for line in sys.stdin:
            message = json.loads(line)
            method = message.get("method")
            permitted = method in safe_methods or (method == "tools/call" and message.get("params", {}).get("name") in allowed)
            if permitted:
                child.stdin.write(json.dumps(message) + "\n")
                child.stdin.flush()
            elif "id" in message:
                emit({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32601, "message": "Tool is outside this connector's read-only allowlist."}})
    finally:
        child.stdin.close()
        # The upstream receives EOF. Never signal arbitrary processes or a process group.
        child.wait()


def main():
    if len(sys.argv) == 5 and sys.argv[1] == "proxy":
        try:
            proxy(*sys.argv[2:])
        except Exception:
            pass  # Upstream configs and errors may contain secrets; MCPorter reports the closed transport.
        return
    parser = argparse.ArgumentParser()
    parser.add_argument("--home", type=Path, default=Path.home(), help="Configuration home (use fixtures for offline audit)")
    parser.add_argument("action", choices=["create", "provision", "opt-in", "audit", "inspect"])
    parser.add_argument("backend", choices=["hermes", "openclaw"])
    parser.add_argument("bot", nargs="?")
    parser.add_argument("--manager")
    parser.add_argument("--connector")
    parser.add_argument("--source", type=Path, help="Explicit manager source config for a connector inherited from another catalog")
    parser.add_argument("--description", default="")
    args = parser.parse_args()
    try:
        if args.action == "audit":
            result = audit(args.home, args.backend)
        elif args.action == "opt-in":
            result = opt_in(args.home, args.backend, args.bot, args.manager, args.connector, args.source)
        elif args.action == "create":
            result = create(args.home, args.backend, args.bot, args.description)
        else:
            result = (provision if args.action == "provision" else inspect)(args.home, args.backend, args.bot)
    except Exception:
        # Config/SQLite/YAML errors can echo secrets. Fail closed with a fixed, actionable reason.
        result = {"op": "connectors", "name": args.bot, "list": [
            {"name": "defaults", "state": "failed", "detail": "Cannot read or apply connectors. Check names, existing bot state, config format, file permissions and Python YAML support."}]}
        print(json.dumps(result))
        return 1
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())

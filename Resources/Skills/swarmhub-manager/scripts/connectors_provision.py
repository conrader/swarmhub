"""New-bot creation, defaults provisioning and explicit per-bot opt-in for default-connectors.py."""
import json
from pathlib import Path
import shutil
import subprocess

import connectors_core
from connectors_core import config_path, defaults, location, openclaw_workspaces, read_config
from connectors_files import atomic_write, connector_copy, environment_values
from connectors_model_auth import apply_hermes_model_auth, hermes_model_auth


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


def writable_root(home, backend, bot):
    root = location(home, backend, bot)
    # A bot/workspace symlink must not redirect a one-bot write into another bot's directory.
    if root.is_symlink() or (backend == "openclaw" and (root / "config").is_symlink()):
        raise ValueError("Bot directory must not redirect to another workspace")
    if backend == "openclaw" and any(name != bot and other.resolve() == root.resolve()
                                     for name, other in openclaw_workspaces(home).items()):
        raise ValueError("Shared workspaces cannot be modified for only one bot")
    return root


def create(home, backend, bot, description="", manager=None):
    """Create fresh connector state, with only the selected model provider's credentials."""
    root = writable_root(home, backend, bot)
    if bot == "default" or root.exists():
        raise ValueError("Only a fresh bot may be created")
    defaults(home)  # Validate policy before invoking either backend.
    plan = hermes_model_auth(home, manager) if backend == "hermes" else None
    command = (["hermes", "profile", "create", bot, "--no-alias", "--description", description]
               if backend == "hermes" else
               ["openclaw", "agents", "add", bot, "--workspace", str(root), "--non-interactive", "--json"])
    # CLI errors/output can include configuration; never forward them to a model reply.
    subprocess.run(command, check=True, capture_output=True, cwd=home)
    if not root.is_dir() or root.is_symlink():
        raise ValueError("Backend did not create the expected bot directory")
    if plan is not None:
        apply_hermes_model_auth(root, plan)
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
        atomic_write(root / "swarmhub-connectors.py", Path(connectors_core.__file__).read_text())
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

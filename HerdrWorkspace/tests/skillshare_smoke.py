"""Exercise `/api/skillshare` against the real skillshare program and a scratch library. No Herdr Core, no model
calls, no network: the repositories it installs from are made here and reached through `file://`.

    python3 tests/skillshare_smoke.py target/debug/swarmhub-herdr [path/to/skillshare]

Nothing of the account's own skillshare library is read or changed. The workspace under test and every skillshare
it starts get a home folder of their own (`HOME` and the four `XDG_*_HOME` folders, which is how skillshare is
pointed at another configuration, data and state), so the source, the Targets and the agent programs' settings
files all live under one scratch folder that is removed at the end. skillshare is reached through a small
launcher that refuses to run with any other home and stands in for `skillshare upgrade`, which would replace the
real program.
"""

import json
import os
from pathlib import Path
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

SECRETS = ("sk-live-ARGSECRET", "debug-LOGVALUE", "team-HEADERVALUE", "QUERYVALUE")


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


class Workspace:
    def __init__(self, port, token):
        self.base, self.token = f"http://127.0.0.1:{port}", token

    def call(self, path, body=None, timeout=200, **query):
        if query:
            path += "?" + urllib.parse.urlencode(query, doseq=True)
        data = None if body is None else json.dumps(body).encode()
        request = urllib.request.Request(self.base + path, data=data, headers={
            "Authorization": f"Bearer {self.token}", "Origin": self.base, "Content-Type": "application/json"})
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        try:
            with opener.open(request, timeout=timeout) as response:
                text = response.read().decode()
                code = response.status
        except urllib.error.HTTPError as error:
            text, code = error.read().decode(), error.code
        for secret in SECRETS:
            assert secret not in text, (path, secret)
        return code, json.loads(text or "{}")

    def get(self, path, **query):
        code, answer = self.call(path, **query)
        assert code == 200, (path, code, answer)
        return answer

    def post(self, path, body=None, expect=200):
        code, answer = self.call(path, body if body is not None else {})
        assert code == expect, (path, code, answer)
        return answer

    def wait(self, process):
        for _ in range(200):
            assert process.poll() is None, "the workspace ended"
            try:
                return self.call("/api/update", timeout=2)
            except OSError:
                time.sleep(0.1)
        raise AssertionError("the workspace did not start")


class Scratch:
    """One home folder with a skillshare library in it, and the repositories to install from."""

    def __init__(self, root, skillshare):
        self.root, self.home = root, root / "home"
        for folder in (".claude", ".config", ".local/share", ".local/state", ".cache"):
            (self.home / folder).mkdir(parents=True)
        self.env = {
            "HOME": str(self.home), "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "XDG_CONFIG_HOME": str(self.home / ".config"), "XDG_DATA_HOME": str(self.home / ".local/share"),
            "XDG_STATE_HOME": str(self.home / ".local/state"), "XDG_CACHE_HOME": str(self.home / ".cache"),
            "GIT_CONFIG_GLOBAL": str(self.home / ".gitconfig"), "GIT_CONFIG_NOSYSTEM": "1",
            "NO_COLOR": "1", "SKILLSHARE_AUTO_UPDATE_CHECK": "false", "GIT_TERMINAL_PROMPT": "0",
        }
        self.config = self.home / ".config/skillshare"
        self.source = self.config / "skills"
        # The launcher the workspace is given as its skillshare.
        self.launcher = root / "skillshare"
        self.launcher.write_text(
            "#!/bin/sh\n"
            f'case "$HOME" in {self.home}) ;; *) echo "refusing to run outside the scratch home" >&2; exit 97;; esac\n'
            'if [ "$1" = upgrade ]; then echo "$*" >> "$HOME/upgrade.log"; echo "Upgraded skillshare"; exit 0; fi\n'
            'if [ "$1" = version ] && [ -s "$HOME/upgrade.log" ]; then echo "skillshare v99.0.0"; exit 0; fi\n'
            f'exec {skillshare} "$@"\n')
        self.launcher.chmod(0o755)

    def run(self, *args, cwd="/", check=True):
        ran = subprocess.run([str(self.launcher), *args], env=self.env, cwd=cwd, capture_output=True, text=True,
                             timeout=120)
        assert not check or ran.returncode == 0, (args, ran.stdout, ran.stderr)
        return ran.stdout

    def git(self, *args, cwd):
        subprocess.run(["git", *args], env=self.env, cwd=cwd, check=True, capture_output=True, timeout=60)

    def skill(self, folder, name, description, body="Do the thing.\n", extra=None):
        folder.mkdir(parents=True)
        (folder / "SKILL.md").write_text(f"---\nname: {name}\ndescription: {description}\n---\n\n# {name}\n\n{body}")
        for path, text in (extra or {}).items():
            (folder / path).parent.mkdir(parents=True, exist_ok=True)
            (folder / path).write_text(text)

    def build(self):
        self.git("config", "--global", "user.name", "Check", cwd="/")
        self.git("config", "--global", "user.email", "check@example.com", cwd="/")
        self.git("config", "--global", "init.defaultBranch", "main", cwd="/")
        self.run("init", "--no-copy", "--git", "--no-skill", "--all-targets")
        status = json.loads(self.run("status", "--json", "-g"))
        assert status["source"]["path"] == str(self.source), status["source"]
        assert sorted(target["name"] for target in status["targets"]) == ["claude", "universal"], status["targets"]
        self.skill(self.source / "alpha", "alpha", "Use when testing alpha things.", extra={"scripts/run.sh": "echo hi\n"})
        self.skill(self.source / "beta", "beta", "Beta skill.")
        self.skill(self.source / "group/nested", "nested", "Nested skill.")
        (self.config / "agents/reviewer.md").write_text("---\nname: reviewer\ndescription: Reviews code.\n---\n\nYou review code.\n")
        self.run("disable", "beta", "-g")
        self.run("mcp", "add", "docs", "--url", "https://example.com/mcp", "--target", "claude", "-g", "--no-tui")
        self.run("mcp", "add", "local", "--target", "claude", "-g", "--no-tui", "--",
                 "company-mcp", "--api-key", "sk-live-ARGSECRET", "--workspace", "/srv/work")
        # Values the workspace must never pass on. skillshare itself only lets names that do not look secret hold
        # a plain value, so these stand in for anything private that ends up there.
        config = self.config / "config.yaml"
        text = config.read_text()
        assert "      command: company-mcp\n" in text and "      url: https://example.com/mcp\n" in text, text
        text = text.replace("      command: company-mcp\n",
                            "      command: company-mcp\n      env:\n        LOG_LEVEL: debug-LOGVALUE\n"
                            "        API_KEY:\n          fromEnv: COMPANY_API_KEY\n")
        text = text.replace("      url: https://example.com/mcp\n",
                            "      url: https://example.com/mcp\n      headers:\n        X-Team: team-HEADERVALUE\n"
                            "      bearerToken:\n        fromEnv: DOCS_TOKEN\n")
        config.write_text(text)
        hook = self.root / "hook.yaml"
        hook.write_text("description: Run the check after the agent finishes\nenabled: true\nbindings:\n  claude:\n"
                        "    events:\n      Stop:\n        - hooks:\n            - type: command\n"
                        "              command: \"make check QUERYVALUE\"\n              timeout: 120\n")
        self.run("hooks", "add", "check", "--file", str(hook), "-g")


def by_id(library):
    return {item["id"]: item for item in library["items"]}


def library_and_previews(workspace, scratch):
    """Step a: the library with its five kinds, previews, the switch, and the sync of everything."""
    library = workspace.get("/api/skillshare/library")
    assert library["installed"] and library["problem"] is None and library["unread"] == [], library
    assert (library["scope"], library["project"]) == ("global", None), library
    assert library["source"] == str(scratch.source), library["source"]
    assert library["counts"] == {"skills": 3, "agents": 1, "mcp": 2, "plugins": 0, "hooks": 1}, library["counts"]
    assert library["item_count"] == 7 and library["updates_checked"] is None and library["sync_blocked"] is None
    items = by_id(library)
    assert sorted(items) == ["agents:reviewer.md", "hooks:check", "mcp:docs", "mcp:local", "skills:alpha",
                             "skills:beta", "skills:group/nested"], sorted(items)
    alpha = items["skills:alpha"]
    assert (alpha["state"], alpha["enabled"], alpha["origin"]) == ("waiting", True, "local"), alpha
    assert alpha["description"] == "Use when testing alpha things." and alpha["targets"] == ["claude", "universal"], alpha
    assert alpha["waiting"] == [{"target": "claude", "action": "add"}, {"target": "universal", "action": "add"}], alpha
    assert alpha["actions"] == ["disable", "uninstall", "diff"], alpha
    assert (items["skills:beta"]["state"], items["skills:beta"]["actions"]) == ("off", ["enable", "uninstall"])
    assert (items["skills:group/nested"]["name"], items["skills:group/nested"]["title"]) == ("group__nested", "nested")
    assert items["agents:reviewer.md"]["description"] == "Reviews code." and items["agents:reviewer.md"]["targets"] == ["claude"]
    assert items["mcp:local"]["description"] == "Runs company-mcp on the server", items["mcp:local"]
    assert items["mcp:docs"]["description"] == "Connects to example.com" and items["mcp:docs"]["actions"] == []
    assert items["hooks:check"]["description"] == "Run the check after the agent finishes", items["hooks:check"]
    assert items["hooks:check"]["actions"] == ["disable", "uninstall"] and items["hooks:check"]["state"] == "waiting"
    assert library["waiting"] == 6, library["waiting"]
    assert {target["name"]: target["waiting"] for target in library["targets"]} == {"claude": 6, "universal": 2}

    # A preview: a skill's files and one of them, an agent's file, and settings without their values.
    preview = workspace.get("/api/skillshare/preview", id="skills:alpha")
    assert preview["files"] == ["SKILL.md", "scripts/run.sh"] and preview["file"] == "SKILL.md", preview
    assert preview["meta"] == [{"key": "name", "value": "alpha"}, {"key": "description", "value": "Use when testing alpha things."}]
    assert preview["text"] == "\n# alpha\n\nDo the thing.\n" and not preview["truncated"], preview["text"]
    assert preview["folder"] == str(scratch.source / "alpha"), preview["folder"]
    assert preview["targets"] == [{"name": "claude", "state": "waiting", "action": "add"},
                                  {"name": "universal", "state": "waiting", "action": "add"}], preview["targets"]
    script = workspace.get("/api/skillshare/preview", id="skills:alpha", file="scripts/run.sh")
    assert (script["text"], script["meta"]) == ("echo hi\n", []), script
    assert workspace.call("/api/skillshare/preview", id="skills:alpha", file="../beta/SKILL.md")[0] == 422
    assert workspace.call("/api/skillshare/preview", id="skills:nothing")[0] == 404
    assert workspace.call("/api/skillshare/preview", id="nonsense")[0] == 422
    agent = workspace.get("/api/skillshare/preview", id="agents:reviewer.md")
    assert agent["text"] == "\nYou review code.\n" and agent["files"] == ["reviewer.md"], agent
    local = workspace.get("/api/skillshare/preview", id="mcp:local")
    assert local["settings"] == [
        {"key": "command", "value": "company-mcp", "hidden": False},
        {"key": "env", "value": "LOG_LEVEL, API_KEY", "hidden": True},
        {"key": "args", "value": "--api-key ••• --workspace /srv/work", "hidden": False}], local["settings"]
    docs = workspace.get("/api/skillshare/preview", id="mcp:docs")
    assert docs["settings"] == [
        {"key": "url", "value": "https://example.com/mcp", "hidden": False},
        {"key": "headers", "value": "X-Team", "hidden": True},
        {"key": "bearer_token", "value": "", "hidden": True}], docs["settings"]
    hook = workspace.get("/api/skillshare/preview", id="hooks:check")
    assert hook["settings"] == [
        {"key": "description", "value": "Run the check after the agent finishes", "hidden": False},
        {"key": "agent", "value": "claude: Stop", "hidden": False}], hook["settings"]

    changes = workspace.get("/api/skillshare/diff", id="skills:alpha")
    assert "alpha" in changes["text"] and "SKILL.md" in changes["text"] and changes["title"], changes
    assert "reviewer" in workspace.get("/api/skillshare/diff", id="agents:reviewer.md")["text"]
    assert workspace.call("/api/skillshare/diff", id="mcp:docs")[0] == 422

    # The switch, for a skill, an agent and a hook, by id; and the first route's switch by name still works.
    off = workspace.post("/api/skillshare/disable", {"id": "skills:alpha"})
    assert off["changed"] == ["skills:alpha"] and by_id(off["library"])["skills:alpha"]["state"] == "off", off["changed"]
    assert workspace.post("/api/skillshare/disable", {"id": "skills:alpha"})["changed"] == []
    assert workspace.post("/api/skillshare/enable", {"id": "skills:alpha"})["changed"] == ["skills:alpha"]
    off = workspace.post("/api/skillshare/disable", {"id": "agents:reviewer.md"})
    assert off["changed"] == ["agents:reviewer.md"] and not by_id(off["library"])["agents:reviewer.md"]["enabled"]
    workspace.post("/api/skillshare/enable", {"id": "agents:reviewer.md"})
    off = workspace.post("/api/skillshare/disable", {"id": "hooks:check"})
    assert off["changed"] == ["hooks:check"] and by_id(off["library"])["hooks:check"]["actions"] == ["enable", "uninstall"]
    workspace.post("/api/skillshare/enable", {"id": "hooks:check"})
    workspace.post("/api/skillshare/disable", {"id": "mcp:docs"}, expect=422)
    workspace.post("/api/skillshare/disable", {"id": "skills:nothing"}, expect=404)
    workspace.post("/api/skillshare/disable", {"nothing": 1}, expect=422)
    named = workspace.post("/api/skillshare/enable", {"name": "beta"})
    assert named["changed"] == ["beta"] and "library" not in named and named["skill_count"] == 3, named
    workspace.post("/api/skillshare/disable", {"name": "beta"})

    # A dry run changes nothing; a sync of everything brings every kind to the agent programs.
    dry = workspace.post("/api/skillshare/sync", {"all": True, "dry_run": True})
    assert dry["dry_run"] and dry["library"]["waiting"] == 6, dry
    assert not (scratch.home / ".claude/skills/alpha").exists()
    done = workspace.post("/api/skillshare/sync", {"all": True})
    assert not done["dry_run"] and done["problem"] is None, done
    assert done["library"]["waiting"] == 0 and done["library"]["unread"] == [], done["library"]
    assert all(item["state"] in ("in_sync", "off") for item in done["library"]["items"]), done["library"]["items"]
    assert sorted(target["name"] for target in done["targets"]) == ["claude", "universal"]
    assert (scratch.home / ".claude/skills/alpha/SKILL.md").is_file()
    assert (scratch.home / ".agents/skills/group__nested/SKILL.md").is_file()
    assert not (scratch.home / ".claude/skills/beta").exists()
    assert (scratch.home / ".claude/agents/reviewer.md").is_file()
    assert "company-mcp" in (scratch.home / ".claude.json").read_text()
    assert "make check" in (scratch.home / ".claude/settings.json").read_text()
    preview = workspace.get("/api/skillshare/preview", id="skills:alpha")
    assert [line["state"] for line in preview["targets"]] == ["in_sync", "in_sync"], preview["targets"]
    # The first routes answer as before, and a sync without `all` is the skills' own.
    first = workspace.get("/api/skillshare")
    assert first["skill_count"] == 3 and [skill["name"] for skill in first["skills"]] == ["group__nested", "alpha", "beta"]
    plain = workspace.post("/api/skillshare/sync", {})
    assert "library" not in plain and plain["linked"] == 4, plain
    workspace.post("/api/skillshare/sync", {"everything": True}, expect=422)
    workspace.post("/api/skillshare/sync", {"all": True, "project": "/nonexistent"}, expect=422)
    wrong = workspace.get("/api/skillshare/library", project="/nonexistent")
    assert wrong["installed"] and "skillshare project" in wrong["problem"] and wrong["items"] == [], wrong


def main(bridge, skillshare):
    assert Path(bridge).is_file() and Path(skillshare).is_file(), (bridge, skillshare)
    with tempfile.TemporaryDirectory(prefix="shskill-", dir=os.environ.get("SWARMHUB_TEST_TMPDIR", "/tmp")) as temp:
        root = Path(temp).resolve()
        scratch = Scratch(root, skillshare)
        scratch.build()
        port, token = free_port(), secrets.token_hex(32)
        (root / "agents").mkdir()
        env = {**scratch.env, "SWARMHUB_PORT": str(port), "SWARMHUB_ACCESS_TOKEN": token,
               "SWARMHUB_AGENT_CWD": str(root / "agents"), "SWARMHUB_SKILLSHARE": str(scratch.launcher),
               # These routes never ask Herdr Core for anything: there is none here.
               "HC_SOCKET": str(root / "no-core.sock")}
        log = open(root / "workspace.log", "w")
        process = subprocess.Popen([str(Path(bridge).resolve())], env=env, cwd=root, stdout=log, stderr=log)
        try:
            workspace = Workspace(port, token)
            code, update = workspace.wait(process)
            assert code == 200 and update["bridge"]["api"] >= 2, update
            library_and_previews(workspace, scratch)
            print("skillshare smoke: ok")
        except BaseException:
            log.flush()
            print((root / "workspace.log").read_text()[-4000:], file=sys.stderr)
            raise
        finally:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
            log.close()


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else shutil.which("skillshare"))

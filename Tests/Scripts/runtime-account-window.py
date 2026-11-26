#!/usr/bin/env python3
"""Verify that the open Mac inspector follows both the bot’s workspace and its live CLI."""
import json
import plistlib
import runpy
import sys
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Thread

qa = runpy.run_path(str(Path(__file__).with_name("chat-window-smoke.py")))
bots = [dict(id=str(uuid.uuid4()), name=name, backend="Herdr")
        for name in ("Patch", "Scout", "Offline", "Legacy")]
token = uuid.uuid4().hex


class Workspace(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.headers.get("Authorization") != "Bearer " + token:
            self.send_error(403)
            return
        if self.path.startswith("/api/workspace"):
            body = dict(core=self.server.identity, templates=[], agents=self.server.agents)
        elif self.path.startswith("/api/runtime-account/"):
            template = self.path.rsplit("/", 1)[1]
            self.server.probes.append(template)
            if template == "legacy":
                self.send_error(404)
                return
            body = self.server.answers.get(template, {"state":"unreported"})
        elif self.path.startswith("/api/approvals"):
            body = {"pending":[]}
        else:
            self.send_error(404)
            return
        self.reply(body)

    def do_POST(self):
        if self.path == "/api/bots":
            self.rfile.read(int(self.headers.get("Content-Length", 0)))
            self.reply({})
        else:
            self.send_error(404)

    def reply(self, body):
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


def exercise(app):
    with qa["private_workspace"](app) as (app, home, store), ThreadingHTTPServer(("127.0.0.1", 0), Workspace) as mac, ThreadingHTTPServer(("127.0.0.1", 0), Workspace) as remote:
        prefs = {}
        servers = []
        for instance, identity in [(mac, "default"), (remote, "studio")]:
            instance.identity, instance.probes, instance.agents = identity, [], []
            servers.append(dict(id=identity, name=identity, kind="local", address=f"http://127.0.0.1:{instance.server_port}"))
            Thread(target=instance.serve_forever, daemon=True).start()
        mac.answers = {"codex":{"state":"signed_in","billing":"Subscription · Plus"},
                       "next":{"state":"signed_in","billing":"API key"}}
        remote.answers = {"codex":{"state":"signed_out"}}
        mac.agents = [dict(name="patch-"+bots[0]["id"][:6], created_ms=80, address="session",
                           state="live", template="codex", session_usage=dict(total_tokens=621))]
        for bot, server, template in zip(bots, ["default","studio","studio","studio"], ["next","codex","other","legacy"]):
            prefs["herdrServer."+bot["id"].lower()] = server
            prefs["herdrTemplate."+bot["id"].lower()] = template
        token_file = home / ".config/swarmhub-herdr/token"
        token_file.parent.mkdir(parents=True)
        token_file.write_text(token)
        prefs["herdrServers"] = json.dumps(servers)
        prefs["appearance"] = "dark"
        domain = plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleIdentifier"]
        settings = home / "Library/Preferences" / (domain+".plist")
        settings.parent.mkdir(parents=True, exist_ok=True)
        settings.write_bytes(plistlib.dumps(prefs))
        store.write_text(json.dumps(dict(version=2, bots=bots, groups=[])))
        try:
            with qa["open_workspace"](app, home, servers[0]["address"], token) as window:
                def values():
                    return [qa["attribute"](e, "AXValue") for e in qa["descendants"](window)
                            if qa["attribute"](e, "AXRole") == "AXStaticText"]
                def select(name):
                    qa["wait_for"](name+" in sidebar", lambda: any(qa["label"](b).startswith(name+",") for b in qa["buttons"](window)))
                    qa["press"](window, name, sidebar=True)
                    qa["open_detail_section"](window, "Overview")
                select("Patch")
                qa["wait_for"]("the running Codex account", lambda: "Subscription · Plus" in values() and "CLI signed in" in values(), seconds=15)
                select("Scout")
                qa["wait_for"]("the other workspace account", lambda: "CLI signed out" in values())
                assert "Subscription · Plus" not in values()
                select("Offline")
                qa["wait_for"]("unknown CLI", lambda: "CLI account unreported" in values())
                select("Legacy")
                qa["wait_for"]("older workspace was checked", lambda: "legacy" in remote.probes)
                assert not any(str(v).startswith("CLI ") for v in values())
                select("Patch")
                qa["wait_for"]("back on the local account", lambda: "Subscription · Plus" in values())
                assert "codex" in mac.probes and "codex" in remote.probes
                print("Verified live AI, two workspaces using the same CLI, signed-out, unreported, older workspace and switching back.")
        finally:
            mac.shutdown()
            remote.shutdown()


if __name__ == "__main__":
    exercise(Path(sys.argv[1]).resolve(strict=True))

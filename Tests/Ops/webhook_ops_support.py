"""Shared fixtures for the PR 6 webhook ops tests (imports sim_isolation first)."""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "sim"))
import sim_isolation  # noqa: E402,F401

import base64
import importlib.machinery
import importlib.util
import json

sys.path.insert(0, str(ROOT / "ops"))
sys.path.insert(0, str(ROOT / "Resources/Skills/swarmhub-messages/scripts"))
import webhook_ops as ops
import webhook_probe as probe
import swarm_webhook as webhook

loader = importlib.machinery.SourceFileLoader("wake_enroll", str(ROOT / "ops/wake-enroll"))
spec = importlib.util.spec_from_loader(loader.name, loader)
enroll = importlib.util.module_from_spec(spec)
loader.exec_module(enroll)


def config(port=8746, host="hooks.test"):
    return '''events {} http {
      map $http_x_swarmhub_key $swh_key { "" absent; default present; }
      log_format swh_probe '$http_cf_ray $swh_key';
      server { listen 443 ssl; server_name HOST;
        location = /swarmhub/webhook/health { return 404; }
        location /swarmhub/webhook/pilot/ {
          limit_except POST { deny all; }
          client_max_body_size 32k;
          proxy_request_buffering on;
          proxy_pass http://127.0.0.1:PORT;
        }
      }
    }'''.replace("HOST", host).replace("PORT", str(port))


def response(code, body, kind="application/json", **headers):
    raw = body.encode() if isinstance(body, str) else json.dumps(body).encode()
    return {"status": code, "headers": {"content-type": kind, **headers},
            "body_b64": base64.b64encode(raw).decode(), "raw_headers": ""}


class FakeBox:
    checkout = str(ROOT)

    def __init__(self):
        self.actions, self.logs = [], {"access": "", "error": "", "presence": "ray-a present\nray-e present\n"}
        self.receipts = [["delivered", "received"]]

    def system(self, *argv):
        return config()

    def read(self, path):
        return self.logs[path]

    def rpc(self, action, **fields):
        self.actions.append((action, fields))
        if action == "register":
            return {"slug": "fixture-slug", "key": "fixture-private-key-long-enough"}
        if action == "receipts":
            return self.receipts * len(fields["deliveries"])
        return {}

    def run(self, argv):
        return json.dumps(response(400, {"error": "bad request"})).encode()

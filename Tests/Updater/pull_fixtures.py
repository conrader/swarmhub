"""Shared fixtures for the P3a pull tests (test_pull.py, test_fetch.py): a local `http.server` that serves a staged
folder with the update service's layout (and can redirect, lie about sizes, stall or answer an error), and a CliCase
that pulls from it. Loopback only, TEST keys only; nothing reaches the real network. Not a test module itself."""

import http.server
import io
import json
from pathlib import Path
import socket
import sys
import threading
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
from cli_fixtures import NOW, PROFILES_DOC, CliCase, box_snapshot, changed, cli, ref_jcs, statefile  # noqa: E402

from swarmhub_update import fetch  # noqa: E402

STATE = ".local/state/swarmhub-update/"
STATUS = STATE + "status.json"


class _Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802 - http.server API
        service = self.server.service
        path = self.path.split("?", 1)[0].lstrip("/")
        service.log.append((path, {k.lower(): v for k, v in self.headers.items()}))
        if path in service.redirects:
            self.send_response(302)
            self.send_header("Location", service.redirects[path])
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        status, body, headers = 404, b"not found", {}
        if path in service.responses:
            status, body, headers = service.responses[path]
        elif service.root is not None and (service.root / path).is_file():
            status, body = 200, (service.root / path).read_bytes()
        self.send_response(status)
        for name, value in ({"Content-Length": str(len(body))} if "Content-Length" not in headers else {}).items():
            self.send_header(name, value)
        for name, value in headers.items():
            if value is not None:
                self.send_header(name, value)
        self.end_headers()
        if service.stall:
            time.sleep(service.stall)
        try:
            self.wfile.write(body)
        except OSError:
            pass  # the client gave up (timeout or size cap): expected in those tests

    def log_message(self, *args):
        pass


class Service:
    """A local static host. `root`: a folder with the service layout; `redirects`: {path: Location};
    `responses`: {path: (status, body, headers)}; `stall`: seconds to wait before sending a body; `log`: requests."""

    def __init__(self, root=None, host="127.0.0.1"):
        self.root, self.redirects, self.responses, self.stall, self.log = root, {}, {}, 0, []
        self.server = http.server.ThreadingHTTPServer((host, 0), _Handler)
        self.server.daemon_threads = True
        self.server.service = self
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    @property
    def port(self):
        return self.server.server_address[1]

    @property
    def url(self):
        return "http://127.0.0.1:%d/" % self.port

    def paths(self):
        return [path for path, _ in self.log]

    def close(self):
        self.server.shutdown()
        self.server.server_close()


def closed_port():
    """A loopback port nothing listens on (the host is down)."""
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def local_fetcher(origins, hosts=(), **kwargs):
    """The tests' fetcher: plain http to loopback, no proxies from the environment, short timeouts."""
    kwargs.setdefault("timeout", 5)
    return fetch.Fetcher(origins, hosts, allow_loopback_http=True, proxies={}, **kwargs)


def resign_broken(path):
    """Flip one hex digit of the envelope's signature (the signed body is unchanged)."""
    doc = json.loads(path.read_bytes())
    sig = doc["signatures"][0]["sig"]
    doc["signatures"][0]["sig"] = ("1" if sig[0] == "0" else "0") + sig[1:]
    path.write_bytes(ref_jcs.canonical(doc))


class PullCase(CliCase):
    """A CliCase with a local update service (`self.service`) and the profiles recorded in the state, as the
    operator bootstrap leaves them, so a pull knows which profiles get which skills."""

    def setUp(self):
        super().setUp()
        self.service = self.serve()
        statefile.State(str(self.state)).write_json(PROFILES_DOC, "profiles.json")

    def serve(self):
        service = Service()
        self.addCleanup(service.close)
        return service

    def publish(self, version, components, service=None, **kwargs):
        """Serve bundle `version` ([(component, blob)]) from `service` (default self.service); returns the folder."""
        kwargs.setdefault("profiles", None)
        folder = self.stage(version, components, **kwargs)
        (service or self.service).root = folder
        return folder

    def pull(self, *origins, now=NOW, fetcher=local_fetcher):
        out = io.StringIO()
        argv = ["--state-dir", str(self.state), "--hermes-home", str(self.hermes), "--max-wait", "0", "pull"]
        for origin in origins:
            argv += ["--origin", origin]
        code = cli.main(argv, str(self.pins_path), now=now, out=out, fetcher=fetcher)
        return code, json.loads(out.getvalue())

    def set_config(self, **values):
        st = statefile.State(str(self.state))
        config = st.config()
        config.update(values)
        st.write_json(config, "config.json")

    def runtime(self, floors=True):
        """Everything under HOME except the status file (which reports each run), the run lock and config.json (its
        install_id is created on first use); without `floors`, also floors.json (a verified key manifest or index
        raises it even when a later stage refuses)."""
        snapshot = box_snapshot(str(self.home))
        for name in [STATUS, STATE + "cli.lock", STATE + "config.json"] + ([] if floors else [STATE + "floors.json"]):
            snapshot.pop(name, None)
        return snapshot

    def assert_runtime_unchanged(self, before, floors=True):
        self.assertEqual(changed(before, self.runtime(floors)), [])

    def start(self):
        """Bundle 11 pulled from the local service: data at once, code after the local confirm."""
        v1, comps = self.release("v1")
        self.publish(11, comps)
        code, out = self.pull(self.service.url)
        self.assertEqual((code, out["state"]), (0, "pending_confirm"), out)
        code, out = self.update("apply", "--version", "11")
        self.assertEqual((code, out["state"]), (0, "current"), out["detail"])
        self.assert_live(v1)
        return v1, comps


__all__ = ["NOW", "STATUS", "PullCase", "Service", "closed_port", "local_fetcher", "resign_broken"]

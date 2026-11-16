#!/usr/bin/env python3
"""Exercise the disposable launcher, including scratch cleanup."""
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request


def check_interrupted_startup(workspace, hc, root, scratch):
    marker = root / "partial-startup"
    stub = root / "partial-bridge"
    stub.write_text(
        f"#!{sys.executable}\nimport os, time\nfrom pathlib import Path\n"
        f"os.write(1, b'Partial startup')\nPath({str(marker)!r}).write_text(os.getcwd())\n"
        "time.sleep(120)\n"
    )
    stub.chmod(0o700)
    proc = subprocess.Popen([sys.executable, str(workspace / "dev/preview.py"), "--hc", hc,
                             "--bridge", str(stub), "--tmpdir", scratch], stdout=subprocess.PIPE)
    assert proc.stdout is not None
    try:
        deadline = time.monotonic() + 28
        while not marker.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        assert marker.exists(), "The partial-output bridge did not start"
        workdir = Path(marker.read_text())
        proc.send_signal(signal.SIGTERM)
        assert proc.wait(timeout=38) == 0, "Interrupting a partial startup failed"
        assert not workdir.exists(), "Interrupted preview left its scratch directory"
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=5)
        proc.stdout.close()


def main(hc, bridge, chrome=None):
    workspace = Path(__file__).resolve().parents[1]
    parent = os.environ.get("SWARMHUB_TEST_TMPDIR", "/var/tmp")
    with tempfile.TemporaryDirectory(prefix="preview-test-", dir=parent) as temp:
        root = Path(temp)
        # Prove this launcher ignores the caller's actual Core and bridge inputs.
        ambient = root / "ambient-workspace"
        proc = subprocess.Popen([
            sys.executable, str(workspace / "dev/preview.py"), "--hc", hc, "--bridge", bridge,
            "--tmpdir", parent,
        ], stdout=subprocess.PIPE, text=True, env={
            **os.environ, "HC_SOCKET": str(root / "ambient.sock"), "SWARMHUB_DATA_DIR": str(ambient),
        })
        assert proc.stdout is not None
        try:
            assert select.select([proc.stdout], [], [], 75)[0], "The preview did not become ready"
            start = proc.stdout.readline().strip()
            token_file = proc.stdout.readline().strip()
            assert start.startswith("Preview ready: http://127.0.0.1:")
            assert token_file.startswith("Workspace token file: ")
            base = start.split(": ", 1)[1]
            path = Path(token_file.split(": ", 1)[1])
            assert path.stat().st_mode & 0o777 == 0o600 and path.parent.stat().st_mode & 0o777 == 0o700
            token = path.read_text().strip()
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

            def request(endpoint, body=None, authorized=True):
                headers = {"Authorization": "Bearer " + token} if authorized else {}
                data = None if body is None else json.dumps(body).encode()
                if data is not None:
                    headers.update({"Content-Type": "application/json", "Origin": base})
                with opener.open(urllib.request.Request(base + endpoint, data=data, headers=headers), timeout=15) as reply:
                    return json.load(reply)

            try:
                request("/api/workspace", authorized=False)
                raise AssertionError("Preview API accepted an unauthenticated request")
            except urllib.error.HTTPError as error:
                assert error.code == 401
            overview = request("/api/workspace")
            assert overview["demo"] and len(overview["agents"]) == 2
            assert {row["name"] for row in request("/api/profiles")} == {"Briefing agent", "Planning agent"}
            assert any(row["name"] == "Launch planning" for row in request("/api/groups"))
            assert any(row["title"] == "Release checklist" for row in request("/api/pages"))
            agent = overview["agents"][0]
            key = f"{agent['address']}/{agent['created_ms']}"
            history = f"/api/history/{overview['core']}/{key}"
            request(f"/api/agents/{key}/messages", {"text":"A preview follow-up"})
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                if any(item["kind"] == "reply" and "A preview follow-up" in item["text"] for item in request(history)["items"]):
                    break
                time.sleep(0.05)
            else:
                raise AssertionError("The preview agent did not record its follow-up")
            if chrome:
                subprocess.run(["node", str(Path(__file__).with_name("browser.mjs")), chrome, base, token, temp],
                               env={**os.environ,"SWARMHUB_TEST_FOCUS":"demo-preview"}, check=True, timeout=90)
        finally:
            if proc.poll() is None:
                proc.send_signal(signal.SIGTERM)
            assert proc.wait(timeout=60) == 0
            proc.stdout.close()
        assert not path.parent.exists(), "Preview scratch files survived shutdown"
        assert not ambient.exists(), "Preview touched the workspace from its caller's environment"
        try:
            request("/api/workspace")
            raise AssertionError("Preview bridge survived shutdown")
        except urllib.error.URLError:
            pass
        check_interrupted_startup(workspace, hc, root, parent)
    print("Disposable Herdr preview smoke passed.")


if __name__ == "__main__":
    main(*sys.argv[1:])

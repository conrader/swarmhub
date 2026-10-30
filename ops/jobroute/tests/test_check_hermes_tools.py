"""check-hermes-tools: fails loudly when an allowlisted profile can read files or run a shell.

Local mode reads DIR/<profile>/config.yaml; remote mode is driven through a fake `ssh` that runs
the remote command locally, so the tar path is exercised without touching the Hermes box.
"""
from __future__ import annotations

import pathlib
import subprocess

import pytest

HERE = pathlib.Path(__file__).resolve().parent
CHECK = HERE.parent / "check-hermes-tools"
SECRET = "Bearer sk-test-SECRET-must-not-print"
SAFE = """agent:
  max_turns: 30
  disabled_toolsets: [terminal, file, code_execution]
mcp_servers:
  sb:
    command: ssh
    args: [-T, -i, /home/hermes/.ssh/sb_ed25519, ubuntu@145.239.94.119]
  noband:
    url: https://example.invalid/mcp
    headers: {Authorization: "%s"}
""" % SECRET


def setup(tmp, configs: dict[str, str | None]) -> tuple[pathlib.Path, pathlib.Path]:
    allow = tmp / "allowlist.toml"
    allow.write_text("".join(f'[profiles.{p}]\nagent = "X"\nbot = "X"\n' for p in configs))
    root = tmp / "profiles"
    for p, text in configs.items():
        if text is not None:
            (root / p).mkdir(parents=True)
            (root / p / "config.yaml").write_text(text)
    return allow, root


def run(*args):
    p = subprocess.run([str(CHECK), *map(str, args)], capture_output=True, text=True, timeout=60)
    assert SECRET not in p.stdout + p.stderr
    return p.returncode, p.stdout, p.stderr


def test_all_profiles_safe_passes(tmp_path):
    allow, root = setup(tmp_path, {"grok-admin": SAFE, "grok-doc": SAFE})
    rc, out, err = run("--allowlist", allow, "--config-dir", root)
    assert rc == 0 and "ok: none of 2" in out and err == ""


def test_hermes_default_bundle_fails_loudly(tmp_path):
    allow, root = setup(tmp_path, {"grok-admin": SAFE, "grok-doc": "agent:\n  max_turns: 30\n"})
    rc, out, err = run("--allowlist", allow, "--config-dir", root)
    assert rc == 1
    assert "FAIL grok-doc: enabled: terminal, file, code_execution" in out and "ok   grok-admin" in out
    assert "JOBROUTE PRECONDITION BROKEN: 1/2 profiles" in err and "grok-doc" in err


@pytest.mark.parametrize("disabled,missing", [("[terminal]", "file, code_execution"),
                                              ("[file, code_execution]", "terminal"),
                                              ("[memory]", "terminal, file, code_execution")])
def test_partial_disable_fails(tmp_path, disabled, missing):
    allow, root = setup(tmp_path, {"grok-admin": f"agent:\n  disabled_toolsets: {disabled}\n"})
    rc, out, _ = run("--allowlist", allow, "--config-dir", root)
    assert rc == 1 and f"enabled: {missing} " in out


def test_list_literal_string_form_accepted(tmp_path):
    cfg = "agent:\n  disabled_toolsets: \"['terminal', 'file', 'code_execution']\"\n"
    allow, root = setup(tmp_path, {"grok-admin": cfg})
    assert run("--allowlist", allow, "--config-dir", root)[0] == 0


@pytest.mark.parametrize("server,why", [
    ("{command: /bin/bash, args: [-c, x]}", "command is a shell"),
    ("{command: npx, args: [-y, '@modelcontextprotocol/server-filesystem', /home/hermes]}", "filesystem"),
])
def test_shell_or_filesystem_mcp_server_fails(tmp_path, server, why):
    allow, root = setup(tmp_path, {"grok-admin": SAFE + f"  extra: {server}\n"})
    rc, out, _ = run("--allowlist", allow, "--config-dir", root)
    assert rc == 1 and "mcp_servers.extra" in out and why in out


def test_missing_config_cannot_check(tmp_path):
    allow, root = setup(tmp_path, {"grok-admin": SAFE, "grok-doc": None})
    rc, out, err = run("--allowlist", allow, "--config-dir", root)
    assert rc == 2 and "JOBROUTE CHECK CANNOT RUN" in err and out == ""


def test_remote_mode_reads_via_one_read_only_ssh(tmp_path):
    allow, root = setup(tmp_path, {"grok-admin": SAFE, "grok-doc": "{}\n"})
    log = tmp_path / "ssh-argv"
    fake = tmp_path / "fake-ssh"
    fake.write_text(f'#!/bin/sh\nprintf "%s\\n" "$@" > {log}\neval "last=\\${{$#}}"\nexec sh -c "$last"\n')
    fake.chmod(0o755)
    rc, out, err = run("--allowlist", allow, "--ssh-bin", fake, "--remote-root", root, "--ssh-key", "/k")
    assert rc == 1 and "FAIL grok-doc" in out and "ok   grok-admin" in out
    argv = log.read_text().splitlines()
    assert argv[:9] == ["-o", "BatchMode=yes", "-o", "ConnectTimeout=20", "-o", "StrictHostKeyChecking=yes",
                        "-i", "/k", "root@195.201.33.222"]
    assert argv[9].startswith("tar -C ") and " -cf - -- grok-admin/config.yaml grok-doc/config.yaml" in argv[9]


def test_remote_missing_profile_cannot_check(tmp_path):
    allow, root = setup(tmp_path, {"grok-admin": SAFE, "grok-doc": None})
    fake = tmp_path / "fake-ssh"
    fake.write_text('#!/bin/sh\neval "last=\\${$#}"\nexec sh -c "$last" 2>/dev/null\n')
    fake.chmod(0o755)
    rc, _, err = run("--allowlist", allow, "--ssh-bin", fake, "--remote-root", root)
    assert rc == 2 and "config.yaml not found for: grok-doc" in err


def test_shipped_allowlist_has_the_12_profiles():
    import tomllib
    names = list(tomllib.loads((HERE.parent / "allowlist.toml").read_text())["profiles"])
    assert len(names) == 12 and all(n.startswith("grok-") for n in names)

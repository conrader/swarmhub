"""Real coding CLI detection and fixtures for the live managed harness (pass 5 addition).

Nothing here stubs a CLI: `coding_cli` only reports an installed, authenticated Codex,
and the harness falls back to the pass-4 behaviour (jobs fail 69) when it is absent.
"""
import os
from pathlib import Path
import shutil
import subprocess


def coding_cli(env=None):
    """A real, authenticated Codex CLI on this host, or None. Never a stub; nothing is installed or replaced."""
    source = dict(os.environ if env is None else env)
    path = shutil.which("codex", path=source.get("PATH", ""))
    if not path:
        return None
    codex_home = source.get("CODEX_HOME") or str(Path(source.get("HOME", str(Path.home()))) / ".codex")
    source["CODEX_HOME"] = codex_home
    try:
        status = subprocess.run([path, "login", "status"], capture_output=True, text=True, timeout=20,
                                env=source)
    except (OSError, subprocess.TimeoutExpired):
        return None
    words = (status.stdout + status.stderr).lower()
    if status.returncode != 0 or "logged in" not in words or "not logged in" in words:
        return None
    return {"agent": "codex", "path": path, "bin": str(Path(path).parent), "codex_home": codex_home}


def cli_env(base, cli):
    """Child environment for managed jobs: the CLI's folder first on PATH and its own auth home (HOME stays the QA home)."""
    env = dict(base)
    if cli:
        env["PATH"] = cli["bin"] + ":" + env.get("PATH", "/usr/bin:/bin")
        env["CODEX_HOME"] = cli["codex_home"]
    return env


def qa_repo(folder):
    """A throwaway git repository with one commit: the working directory of real QA coding jobs."""
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "README.md").write_text("QA repository for a SwarmHub live pass. Throwaway.\n")
    env = {"HOME": str(folder.parent), "PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"}
    for argv in (["git", "init", "-q"], ["git", "add", "README.md"],
                 ["git", "-c", "user.name=QA", "-c", "user.email=qa@example.invalid", "commit", "-qm", "QA baseline"]):
        subprocess.run(argv, cwd=folder, env=env, check=True, capture_output=True, timeout=30)
    return folder


def pid_alive(pid):
    return subprocess.run(["ps", "-p", str(pid), "-o", "stat="], capture_output=True, text=True).stdout.strip() not in ("", "Z")
RULES = ("[QA-TEST] Replay only recorded Grok team patterns. Your tools are todo and clarify. "
         "Do not use tools or ask clarify. Do not claim any file, job, send, provisioning, "
         "webhook or model change happened unless the incoming runtime receipt proves it. "
         "Keep answers under 70 words. All outbound is FAKE. Never expose secrets. "
         "Delivered replies and policy/FYI broadcasts require exactly NO_REPLY. "
         "For coding completion receipts, acknowledge failures truthfully, under 40 words. "
         "Do not claim next work started; only the queue can establish that.")

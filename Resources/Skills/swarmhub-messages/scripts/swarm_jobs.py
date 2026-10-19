"""Job scheduling and execution: one ordered job per bot, completion authoritative on disk."""
import json
from pathlib import Path
import subprocess
import sys
import time

from swarm_policy import action, active, coding_model, coding_plan
from swarm_store import canonical, database, process_alive, spawn_recorded, state, terminate


def check_job(ident, bot, directory, model, effort, report, task, order, verify=""):
    """A launched job must match its approved record and the parameters resolved at launch.

    The launcher records the resolved order/model; a policy change after launch
    must not fail the running job with a false parameter mismatch. The approved
    verification command (if any) must reach code-job unchanged.
    """
    row = action(ident)
    spec = json.loads(row["spec"])
    expected_report = Path(spec.get("report", ""))
    if not expected_report.is_absolute():
        expected_report = Path(spec.get("directory", ".")) / expected_report
    launched = json.loads(row["launched"]) if row.get("launched") else {}
    expected_model = launched.get("model", coding_model(spec.get("model", "")))
    expected_order = launched.get("order") or coding_plan(spec.get("order", "codex"), spec.get("speculative", False))
    if (row["status"] not in ("queued", "running") or not active(ident) or spec.get("kind") != "coding" or spec.get("fake") or
        (bot, str(Path(directory).resolve()), model, effort, str(Path(report).resolve()), task, order, verify) !=
        (spec["bot"], str(Path(spec["directory"]).resolve()), expected_model, spec["effort"],
         str(expected_report.resolve()), spec["task"], expected_order, spec.get("verify", ""))):
        raise ValueError("job parameters do not match the approved task")


def fake_done(db, ident, kind):
    """``fake: true`` is a dry run for every kind: recorded as done, nothing executed."""
    db.execute("UPDATE actions SET status='done',error=? WHERE id=? AND status IN ('queued','running')",
               (f"FAKE: no {kind} operation executed", ident))


def tick():
    """Launch at most one ordered job per bot. Completion is authoritative on disk.

    A failed job holds later work for that bot; cancelling/replacing explicitly
    releases it. A running job with a lost process is failed, never replayed.
    """
    code = Path(__file__).parents[2] / "swarmhub-coding/scripts/code-job"
    with database() as db:
        db.execute("BEGIN IMMEDIATE")
        rows = db.execute("SELECT * FROM actions ORDER BY created,id").fetchall()
        busy = set()
        for row in rows:
            spec = json.loads(row["spec"])
            bot, status = spec["bot"], row["status"]
            job = state() / "job-completions" / row["id"].replace("task.", "job.", 1)
            if status == "cancelled" and row["pid"] and process_alive(row["pid"], row["pid_start"]):
                busy.add(bot)  # Wait for the old scope to stop before relaunch.
                continue
            if status == "running":
                if spec["kind"] == "peer":
                    delivery = db.execute("SELECT status FROM deliveries WHERE task=?", (row["id"],)).fetchone()
                    if delivery and delivery[0] == "delivered":
                        status = "done"
                        db.execute("UPDATE actions SET status='done' WHERE id=?", (row["id"],))
                elif (job / "ready").exists():
                    status = "done" if (job / "status").read_text().strip() == "ok" else "failed"
                    db.execute("UPDATE actions SET status=? WHERE id=?", (status, row["id"]))
                elif row["pid"]:
                    if not process_alive(row["pid"], row["pid_start"]):
                        status = "failed"
                        db.execute("UPDATE actions SET status='failed',error='Worker exited without completion' WHERE id=?", (row["id"],))
            if status in ("running", "failed") or status.startswith("awaiting-"):
                busy.add(bot)
                continue
            if status != "queued" or bot in busy:
                continue
            try:
                if spec.get("fake"):
                    fake_done(db, row["id"], spec["kind"])
                elif spec["kind"] == "coding":
                    order = coding_plan(spec.get("order", "codex"), spec.get("speculative", False))
                    model = coding_model(spec["model"])
                    command = ["/bin/sh", str(code), "--bot", bot, "--order", order,
                               "--origin", spec.get("origin", ""), "--dir", spec["directory"],
                               "--model", model, "--effort", spec["effort"], "--report", spec["report"],
                               "--task-id", row["id"], "--job-id", job.name]
                    command += ["--verify", spec.get("verify", "")]
                    command += ["--", spec["task"]]
                    pid, started = spawn_recorded(command)
                    db.execute("UPDATE actions SET status='running',pid=?,pid_start=?,launched=? WHERE id=?",
                               (pid, started, canonical({"order": order, "model": model}), row["id"]))
                    busy.add(bot)
                elif spec["kind"] == "peer":
                    # Admission is transactional with the action state.
                    delivery = "delivery." + row["id"][5:]
                    db.execute("INSERT OR IGNORE INTO deliveries(id,sender,target,text,task,status) VALUES(?,?,?,?,?,'pending')",
                               (delivery, bot, spec["to"], spec["text"], row["id"]))
                    db.execute("UPDATE actions SET status='running' WHERE id=?", (row["id"],))
                else:
                    pid, started = spawn_recorded([sys.executable, str(Path(__file__).with_name("swarmctl")), "run-action", row["id"]])
                    db.execute("UPDATE actions SET status='running',pid=?,pid_start=? WHERE id=?", (pid, started, row["id"]))
                    busy.add(bot)
            except (ValueError, OSError, subprocess.TimeoutExpired) as exc:
                db.execute("UPDATE actions SET status='failed',error=? WHERE id=?", (type(exc).__name__, row["id"]))
                busy.add(bot)


def run_action(ident):
    row = action(ident)
    # The launcher publishes running in the transaction that admitted the child.
    # A fast child can arrive just before that transaction commits.
    for _ in range(200):
        if row["status"] != "queued":
            break
        time.sleep(.01)
        row = action(ident)
    if row["status"] != "running":
        return
    spec = json.loads(row["spec"])
    if spec.get("fake"):
        with database() as db:
            fake_done(db, ident, spec["kind"])  # Defense in depth: never spawn a dry run's argv.
        return
    if not active(ident):
        return
    # Only the immutable argv in the approved record reaches the process.
    try:
        child = subprocess.Popen(spec["argv"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL)
    except OSError:
        with database() as db:
            db.execute("UPDATE actions SET status='failed',error='Unable to start approved command' WHERE id=? AND status='running'", (ident,))
        return
    deadline = time.monotonic() + 1800
    while child.poll() is None:
        if (state() / "cancelled" / ident).exists() or time.monotonic() > deadline:
            terminate(child.pid)
            try:
                child.wait(timeout=2)
            except subprocess.TimeoutExpired:
                child.kill()
            break
        time.sleep(.1)
    with database() as db:
        db.execute("UPDATE actions SET status=?,error=? WHERE id=? AND status='running'",
                   ("done" if child.returncode == 0 else "failed", f"exit {child.returncode}", ident))

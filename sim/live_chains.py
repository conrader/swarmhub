"""Pass-8 bounded model-action bridge. No Hermes tools/plugins are installed.

Models select actions in replies; the harness validates and executes only the
fixed local QA operations below. Raw replies, bindings and command receipts are
retained. NO_REPLY, prose, stale evidence and unknown actions fail closed.
"""
import hashlib
import json
from pathlib import Path
import shlex
import time

from live_behavior import answer, successful


ACTION_RULES = (
    '[QA-TEST] All outbound is FAKE. Never use Hermes tools or expose secrets. '
    'This receiving turn has a bounded LOCAL managed-action bridge: request the '
    'authorized operation by replying with exactly one JSON object, without fences. '
    'The bridge executes it after your reply and records the real outcome. Do not '
    'claim execution or success before a receipt. Read the actual evidence; do not '
    'return NO_REPLY when action is required. No other operation is available. '
)

# The verifier lives outside the model's working directory and runs in its own
# process after the CLI. It compiles the actual fresh source and runs real tests.
VERIFIER = '''import hashlib, importlib.util, json, pathlib, py_compile, sys, time, unittest
repo, mode, receipt = pathlib.Path(sys.argv[1]), sys.argv[2], pathlib.Path(sys.argv[3])
source = repo / "qa_work.py"
build = repo / ".qa-build"
build.mkdir(exist_ok=True)
py_compile.compile(str(source), cfile=str(build / (mode + ".pyc")), doraise=True)
spec = importlib.util.spec_from_file_location("qa_work", source)
module = importlib.util.module_from_spec(spec)
exec(compile(source.read_bytes(), str(source), "exec"), module.__dict__)
class Checks(unittest.TestCase):
    def test_add(self):
        for a, b in ((2, 3), (-2, 3), (0, 0), (100, -1)):
            self.assertEqual(module.add(a, b), a + b)
    def test_next(self):
        if mode == "multiply":
            for a, b in ((2, 3), (-2, 3), (0, 4)):
                self.assertEqual(module.multiply(a, b), a * b)
        elif mode == "subtract":
            for a, b in ((2, 3), (-2, 3), (0, 4)):
                self.assertEqual(module.subtract(a, b), a - b)
        else:
            self.assertEqual(module.add(9, 4), 13)
result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(Checks))
receipt.write_text(json.dumps({"time_ns": time.time_ns(), "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
                              "compiled": True, "tests_run": result.testsRun, "passed": result.wasSuccessful()}))
sys.exit(0 if result.wasSuccessful() else 1)
'''


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def parse_action(reply, op, binding):
    value = json.loads(reply)
    if not isinstance(value, dict) or value.get("op") != op:
        raise ValueError("Missing authorized model action: " + op)
    if any(value.get(key) != expected for key, expected in binding.items()):
        raise ValueError("Model action does not bind the actual evidence")
    return value


class ChainMixin:
    def run_chain(self, label, operation):
        """Keep the two gaps independent when a live environment check fails."""
        self.chain_jobs = []
        try:
            operation()
        except Exception as exc:
            self.result(label, False, self.clean(str(exc)))
            for ident in self.chain_jobs:
                if self.action_status(ident) in ("failed", "queued", "running"):
                    self.ctl(label + "-stop-" + ident, "stop", ident)
            self.snapshot("QA-" + label + "-failed")
        finally:
            self.chain_steps = []

    def chain_submit(self, label, *args, payload):
        ident = self.decoded_ctl(label, *args, payload=payload)
        if not hasattr(self, "chain_jobs"):
            self.chain_jobs = []
        self.chain_jobs.append(ident)
        return ident

    def chain_rules(self, target, text):
        for step in getattr(self, "chain_steps", []):
            if step["target"] == target and step["match"] in text:
                return ACTION_RULES + step["instructions"]
        return None

    def arm_step(self, target, match, instructions):
        if not hasattr(self, "chain_steps"):
            self.chain_steps = []
        self.chain_steps.append(dict(target=target, match=match, instructions=instructions))

    def model_action(self, label, target, match, op, binding):
        if not any(s["target"] == target and s["match"] == match for s in self.chain_steps):
            raise ValueError("Unarmed or already consumed action")
        # Find the actual receiving turn, not bot-msg's acknowledgement text.
        turns = [t for t in self.traces if t.get("request_body") and
                 target in t.get("path", "") and match in json.loads(t["request_body"]).get("input", "")]
        if not turns:
            raise ValueError("No receiving turn for " + label)
        trace = turns[-1]
        if not successful(trace):
            raise ValueError("Failed or incomplete receiving turn")
        value = parse_action(answer(trace), op, binding)
        self.chain_steps = [s for s in self.chain_steps if not (s["target"] == target and s["match"] == match)]
        self.chain_event(label, {"receiving_turn": trace["name"], "action": value})
        return value

    def chain_event(self, label, data):
        if not hasattr(self, "chain_events"):
            self.chain_events = []
        self.chain_events.append({"label": label, "time_ns": time.time_ns(), **data})
        (self.output / "QA-action-chains.json").write_text(self.clean(json.dumps(self.chain_events, indent=2)) + "\n")
        self.result(label, True, json.dumps(data))

    def init_chain_verifier(self):
        self.verifier = self.temp / "QA-verify.py"
        self.verifier.write_text(VERIFIER)

    def verify_command(self, intent, mode="add"):
        return shlex.join(["/usr/bin/python3", str(self.verifier), str(self.repo), mode,
                           str(self.temp / (intent + "-verify.json"))])

    def local_git(self, label, *args):
        return self.command(label, ["git", "-C", str(self.repo), *args])

    def job_evidence(self, ident):
        fields = ("status", "exit", "cli-exit", "model", "effort", "report", "report-valid", "report-sha256",
                  "head-before", "head-after", "commit-evidence", "verify-exit", "tests-passed")
        return {name: self.job_field(ident, name) for name in fields}

    def independent_check(self, label, ident, intent, mode="add", require_commit=True):
        fields = self.job_evidence(ident)
        report = self.repo / (intent + ".txt")
        if (fields["report"] != str(report) or not report.is_file() or not report.stat().st_size or
                fields["report-valid"] != "true" or digest(report) != fields["report-sha256"] or
                fields["cli-exit"] != "0" or fields["tests-passed"] != "true" or fields["verify-exit"] != "0" or
                (require_commit and (fields["commit-evidence"] != "true" or
                                    fields["head-before"] == fields["head-after"]))):
            raise ValueError("Fresh output/commit/verification contract failed: " + json.dumps(fields))
        receipt = self.output / (label + "-build.json")
        self.command(label + "-compile-test", ["/usr/bin/python3", str(self.verifier), str(self.repo), mode, str(receipt)])
        checked = json.loads(receipt.read_text())
        if not checked["compiled"] or not checked["passed"] or checked["tests_run"] != 2:
            raise ValueError("Independent compile/tests failed")
        proof = dict(job=ident, report_sha256=digest(report), fields=fields, verification=checked)
        proof["proof_sha256"] = hashlib.sha256(json.dumps(proof, sort_keys=True).encode()).hexdigest()
        self.chain_event(label, proof)
        return proof

    def wait_job(self, ident):
        job = self.state / "job-completions" / ident.replace("task.", "job.")
        self.until(lambda: (job / "delivered").exists() and self.action_status(ident) in ("done", "failed"), 900)
        self.idle()

    def completion_input(self, ident):
        job = ident.replace("task.", "job.")
        matches = [json.loads(t["request_body"])["input"] for t in self.traces
                   if t.get("request_body") and job in json.loads(t["request_body"]).get("input", "")]
        if not matches:
            raise ValueError("Actual completion was not delivered")
        return matches[0]

    def p01_chain(self):
        # Only the first job is admitted. There is no queued next job to advance.
        self.arm_step("QA-Jarvis", "QA-P01-first.txt",
                      'Read this actual completion. Reply {"op":"relay","job":"<job.ID from receipt>",'
                      '"instruction":"<your review and next-step instruction for QA-Swarmhub>"}. '
                      'Relay the outcome truthfully and require review, commit, rebuild and selection of next work.')
        first = self.chain_submit("P01-submit-first", "submit", payload=self.coding("QA-P01-first", commit=False))
        self.wait_job(first)
        relay = self.model_action("P01-Jarvis-relay", "QA-Jarvis", "QA-P01-first.txt", "relay",
                                  {"job": first.replace("task.", "job.")})
        if not isinstance(relay.get("instruction"), str) or not relay["instruction"].strip():
            raise ValueError("Empty coordinator relay")
        proof = self.independent_check("P01-first-output-and-build", first, "QA-P01-first", require_commit=False)
        binding = {"job": first, "report_sha256": proof["report_sha256"], "head": proof["fields"]["head-after"]}
        token = "QA-P01-review-" + first
        self.arm_step("QA-Swarmhub", token,
                      'Review the actual report, source diff and completion. Request review_commit_rebuild with '
                      'these exact bindings ' + json.dumps(binding) +
                      ', plus "review":"<substantive assessment of actual changes and evidence>". '
                      'This operation commits the reviewed source changes and your review in this throwaway repo '
                      'and rebuilds/tests. You will choose the next job after receiving the real build receipt.')
        self.msg("P01-ordering-review", "QA-Jarvis", "QA-Swarmhub",
                 token + "\nJarvis relay: " + json.dumps(relay) + "\nActual completion:\n" + self.completion_input(first) +
                 "\nActual report:\n" + (self.repo / "QA-P01-first.txt").read_text() +
                 "\nActual source diff:\n" + self.local_git("P01-review-diff", "diff", "HEAD", "--", "qa_work.py") +
                 "\nIndependent proof:\n" + json.dumps(proof), "--priority")
        action = self.model_action("P01-ordering-reviewed", "QA-Swarmhub", token, "review_commit_rebuild", binding)
        review = action.get("review")
        if not isinstance(review, str) or len(review.strip()) < 30:
            raise ValueError("Missing substantive review")
        # Commit the actual reviewed job output, with optimistic HEAD binding.
        if self.local_git("P01-reviewed-head", "rev-parse", "HEAD") != action["head"]:
            raise ValueError("Repository changed since model review")
        (self.repo / "QA-REVIEW.md").write_text(review + "\n")
        self.local_git("P01-ordering-stage", "add", "qa_work.py", "NOTES.md", "QA-REVIEW.md")
        self.local_git("P01-ordering-commit", "commit", "-m", "QA: ordering bot reviewed completion")
        new_head = self.local_git("P01-ordering-new-head", "rev-parse", "HEAD")
        if new_head == action["head"]:
            raise ValueError("Ordering bot commit did not change HEAD")
        self.local_git("P01-ordering-committed-diff", "show", "--format=fuller", "HEAD")
        self.command("P01-ordering-rebuild-test", ["/usr/bin/python3", str(self.verifier), str(self.repo), "add",
                                                  str(self.output / "QA-P01-ordering-build.json")])
        build = json.loads((self.output / "QA-P01-ordering-build.json").read_text())
        self.chain_event("P01-ordering-commit-rebuilt", {"head_before": action["head"], "head_after": new_head,
                                                       "verification": build})
        token = "QA-P01-pick-next-" + first
        binding = {"head": new_head, "build_sha256": digest(self.output / "QA-P01-ordering-build.json")}
        self.arm_step("QA-Swarmhub", token,
                      'Your commit and rebuild completed; inspect the real receipt. Choose the next useful authorized '
                      'job yourself: add multiply(a,b) or subtract(a,b), preserving add. Request launch_next with '
                      'these exact bindings ' + json.dumps(binding) + ', plus "next":"multiply" or "subtract". '
                      'The bridge submits that real CLI job only after your choice. Do not ask the user.')
        self.msg("P01-ordering-pick-next", "QA-Jarvis", "QA-Swarmhub",
                 token + "\nCommit HEAD: " + new_head + "\nActual build receipt: " + json.dumps(build), "--priority")
        choice = self.model_action("P01-ordering-selected-next", "QA-Swarmhub", token, "launch_next", binding)
        next_mode = choice.get("next")
        if next_mode not in ("multiply", "subtract"):
            raise ValueError("Missing authorized next-job selection")
        intent = "QA-P01-next-" + next_mode
        second = self.chain_submit("P01-bot-selected-next-submit", "submit", payload=self.coding(intent, mode=next_mode))
        self.chain_event("P01-next-submitted-unasked", {"job": second, "selected_by": "P01-ordering-selected-next",
                                                     "preloaded_queue": False})
        self.wait_job(second)
        proof = self.independent_check("P01-next-verified", second, intent, next_mode)
        self.chain_event("P01-next-launched-unasked", {"job": second, "cli_exit": proof["fields"]["cli-exit"],
                                                     "selected_by": "P01-ordering-selected-next", "preloaded_queue": False})
        self.snapshot("QA-P01-full-chain")

    def p04_chain(self):
        # A real CLI, not a stub or CLI-free 69: ask for zero tool work/output.
        self.arm_step("QA-Jarvis", "QA-P04-empty.txt",
                      'This real job failed its output contract. Issue a correction as '
                      '{"op":"correct","job":"<job.ID>","model":' + json.dumps(self.model) +
                      ',"effort":"high","instruction":"<demand relaunch and independent fresh-output/test checks before success>"}. '
                      'Do not claim the failed job succeeded.')
        empty = self.coding("QA-P04-empty")
        empty["task"] = ("QA negative control: finish immediately with no tools, no edits, no report and empty output. "
                         "This intentionally tests rejection of an empty exit-zero job. The generic report instruction "
                         "below is deliberately unsatisfied. Do not perform the normal coding task.")
        failed = self.chain_submit("P04-submit-real-empty", "submit", payload=empty)
        self.wait_job(failed)
        fields = self.job_evidence(failed)
        if self.action_status(failed) != "failed" or fields["cli-exit"] != "0" or fields["report-valid"] == "true":
            raise ValueError("Real exit-zero empty-job negative control not established: " + json.dumps(fields))
        self.chain_event("P04-real-empty-rejected", {"job": failed, "fields": fields})
        correction = self.model_action("P04-Jarvis-corrected", "QA-Jarvis", "QA-P04-empty.txt", "correct",
                                       {"job": failed.replace("task.", "job."), "model": self.model, "effort": "high"})
        if not isinstance(correction.get("instruction"), str) or not correction["instruction"].strip():
            raise ValueError("Empty correction")
        token = "QA-P04-relaunch-" + failed
        binding = {"failed_job": failed, "model": self.model, "effort": "high"}
        self.arm_step("QA-Swarmhub", token,
                      'Act on Jarvis correction. Request {"op":"relaunch",' + json.dumps(binding)[1:-1] +
                      '}. This admits one corrective job with explicit model/high effort, new report path and compile/tests. '
                      'Success must wait for an independent fresh-output/verification receipt.')
        self.msg("P04-deliver-actionable-correction", "QA-Jarvis", "QA-Swarmhub",
                 token + "\nActual correction: " + json.dumps(correction) + "\nFailed completion:\n" + self.completion_input(failed),
                 "--priority")
        self.model_action("P04-receiver-requested-relaunch", "QA-Swarmhub", token, "relaunch", binding)
        intent = "QA-P04-corrected"
        self.arm_step("QA-Jarvis", intent + ".txt",
                      'Acknowledge receipt only; do not report success yet. The independent output check is still pending. '
                      'Reply {"op":"await_independent_check","job":"<job.ID from completion>"}.')
        # Replacement explicitly releases the failed job's queue hold.
        corrected = self.chain_submit("P04-explicit-high-relaunch", "replace", failed, payload=self.coding(intent))
        self.wait_job(corrected)
        self.model_action("P04-success-report-held-for-check", "QA-Jarvis", intent + ".txt", "await_independent_check",
                          {"job": corrected.replace("task.", "job.")})
        proof = self.independent_check("P04-fresh-output-independently-verified", corrected, intent)
        if proof["fields"]["model"] != self.model or proof["fields"]["effort"] != "high":
            raise ValueError("Relaunch did not use explicit model/high effort")
        token = "QA-P04-verified-" + corrected
        binding = {"job": corrected, "proof_sha256": proof["proof_sha256"]}
        self.arm_step("QA-Swarmhub", token,
                      'Only now has the independent verifier checked the fresh file and compiled/tested the source. '
                      'Read the proof and request {"op":"report_success",' + json.dumps(binding)[1:-1] +
                      ',"summary":"<accurate result based on receipt>"}.')
        self.msg("P04-verified-result-for-report", "QA-Jarvis", "QA-Swarmhub", token + "\n" + json.dumps(proof), "--priority")
        report = self.model_action("P04-success-after-independent-check", "QA-Swarmhub", token, "report_success", binding)
        if not isinstance(report.get("summary"), str) or not report["summary"].strip():
            raise ValueError("Missing evidence-based success summary")
        self.snapshot("QA-P04-full-correction-chain")

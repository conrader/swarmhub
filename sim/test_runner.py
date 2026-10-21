"""Harness safety/receipt/oracle tests only; no simulated Hermes or app backend."""
import sim_isolation  # noqa: F401  Exits unless isolated (PID namespace / macOS signal guard); keep it the first import.
import copy
import json
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

import run as qa


def attestation(nonce="QA-nonce"):
    return dict(schema=qa.SCHEMA, nonce=nonce, debug_build=True, test_mode=True,
                real_app=True, real_hermes=True, isolated_qa_store=True,
                inventory_complete=True, real_connector_count=0,
                sandbox_enforced_app=True, sandbox_enforced_hermes=True,
                default_deny_tools=True, egress_denied_except_model=True,
                qa_peers_only=True, qa_marker_propagated=True, watchdog_active=True,
                production_jobs_accessible=False, build="unit-test-only", commit="unit-test-only",
                hermes_version="not-connected", sandbox_policy_digest="unit-test-only",
                lease="QA-unit-test", expires_at=time.time()+30,
                connectors=[dict(implementation="record-only", has_credentials=False, network_enabled=False)],
                capabilities=sorted(qa.OPS | {"observe", "cleanup"}))


def evidence():
    return dict(schema=qa.SCHEMA, run_id="unit", scenario_id="F03",
                resource="QA-unit-F03 [QA-TEST]", capture_complete=True,
                events=[dict(seq=1, type="remote_turn", source="hermes", run_id="unit", scenario_id="F03",
                             resource="QA-unit-F03 [QA-TEST]")],
                observed_event_types=["remote_turn", "duplicate"], state={"answer_has_marker": True},
                screenshots=["QA-unit-screenshot-receipt"], session_id="QA-unit", backend_profile="QA-unit",
                usage_before=0, usage_after=1)


class PolicyTests(unittest.TestCase):
    def test_catalog_complete_unique(self):
        rows = qa.catalog()
        expected = {f"{family}{i:02}" for family, n in [("A",18),("F",25),("B",10),("U",12)] for i in range(1,n+1)}
        self.assertEqual({r["id"] for r in rows}, expected)
        self.assertEqual(len(rows), len(expected))
        for row in rows:
            self.assertTrue(row["qa_script"])
            self.assertNotIn("\n", row["title"])
            self.assertLess(len(row["title"]), 200)
            self.assertIn(row["grok"], {"matches","worse","missing","better"})
            if row["steps"]:
                self.assertTrue(row["checks"])
                self.assertTrue(row["uncovered"])
                for step in row["steps"]:
                    qa.validate_step(step)

    def test_real_names_and_unmarked_qa_refused(self):
        for name in ["Work", "QA-Work", "QA-Work [QA-TEST] extra", "QA-../Work [QA-TEST]", "QA- [QA-TEST]", None]:
            with self.subTest(name=name):
                self.assertFalse(qa.qa_name(name))
        self.assertTrue(qa.qa_name("QA-unit-F03 [QA-TEST]"))

    def test_unknown_mutations_and_parameters_refused(self):
        actions = [{"op":"shell","value":"pwd"}, {"op":"email.send"}, {"op":"chat.send","text":"read secrets"},
                   {"op":"chat.send","prompt":"arbitrary"}, {"op":"routine.delete","target":"production"},
                   {"op":"chat.send","prompt":"drafts"}, {"op":"routine.delete","prompt":"wait"},
                   {"op":"approval.decide","value":"approve-all"}, {"op":"fact.write","value":"real-data"}]
        for action in actions:
            with self.subTest(action=action), self.assertRaises(qa.Refused):
                qa.validate_step(action)

    def test_valid_safety_attestation(self):
        self.assertEqual(qa.validate_attestation(attestation(), "QA-nonce")["real_connector_count"],0)

    def test_every_safety_field_required(self):
        original=attestation()
        for key in original:
            with self.subTest(key=key), self.assertRaises(qa.Refused):
                altered=copy.deepcopy(original); del altered[key]
                qa.validate_attestation(altered,"QA-nonce")

    def test_inventory_and_sandbox_drift_refused(self):
        variants=[{"real_connector_count":1}, {"inventory_complete":False}, {"real_connector_count":False},
                  {"sandbox_enforced_hermes":False}, {"egress_denied_except_model":False}, {"test_mode":False},
                  {"debug_build":False}, {"real_hermes":False}, {"production_jobs_accessible":True},
                  {"watchdog_active":False}, {"connectors":[]}, {"qa_peers_only":False},
                  {"connectors":[{"implementation":"provider","has_credentials":False,"network_enabled":False}]},
                  {"connectors":[{"implementation":"record-only","has_credentials":True,"network_enabled":False}]},
                  {"connectors":[{"implementation":"record-only","has_credentials":False,"network_enabled":True}]}]
        for update in variants:
            with self.subTest(update=update),self.assertRaises(qa.Refused):
                qa.validate_attestation(dict(attestation(),**update),"QA-nonce")

    def test_expired_replayed_and_long_lease_refused(self):
        for update in [{"nonce":"old"},{"expires_at":time.time()-1},{"expires_at":time.time()+3600}]:
            with self.subTest(update=update),self.assertRaises(qa.Refused):
                qa.validate_attestation(dict(attestation(),**update),"QA-nonce")

    def test_token_requires_owner_only_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/"token"; path.write_text("a"*43);path.chmod(0o600)
            self.assertEqual(qa.read_token(path),"a"*43)
            path.chmod(0o644)
            with self.assertRaises(qa.Refused):qa.read_token(path)

    def test_token_symlink_and_short_token_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/"token";path.write_text("short");path.chmod(0o600)
            with self.assertRaises(qa.Refused):qa.read_token(path)
            link=Path(tmp)/"link";link.symlink_to(path)
            with self.assertRaises(OSError):qa.read_token(link)


class OracleTests(unittest.TestCase):
    def test_valid_evidence_bound_to_scope(self):
        e=evidence()
        self.assertIs(qa.validate_evidence(e,"unit","F03",e["resource"]),e)

    def test_wrong_origin_refused(self):
        for field in ["run_id","scenario_id","resource"]:
            e=evidence();e[field]="other"
            with self.subTest(field=field),self.assertRaises(qa.Refused):
                qa.validate_evidence(e,"unit","F03","QA-unit-F03 [QA-TEST]")

    def test_incomplete_evidence_blocks(self):
        for key in ["events","screenshots","state","session_id","usage_after"]:
            e=evidence();del e[key]
            with self.subTest(key=key),self.assertRaises(qa.Blocked):
                qa.validate_evidence(e,"unit","F03","QA-unit-F03 [QA-TEST]")

    def test_model_text_is_not_execution_evidence(self):
        e=evidence();e["events"][0]["source"]="model-claims-done"
        with self.assertRaises(qa.Blocked):qa.validate_evidence(e,"unit","F03",e["resource"])

    def test_duplicate_or_unordered_events_block(self):
        for numbers in [[1,1],[2,1]]:
            e=evidence();e["events"]=[dict(e["events"][0],seq=n) for n in numbers]
            with self.subTest(numbers=numbers),self.assertRaises(qa.Blocked):
                qa.validate_evidence(e,"unit","F03",e["resource"])

    def test_missing_state_not_pass(self):
        with self.assertRaises(qa.Blocked):qa.evaluate([dict(kind="state",key="verified",equals=True)],evidence())

    def test_zero_count_requires_instrumentation(self):
        with self.assertRaises(qa.Blocked):qa.evaluate([dict(kind="count",key="unobserved",equals=0)],evidence())

    def test_unsupported_done_is_failed_check(self):
        e=evidence();e["state"]["verified"]=False
        self.assertFalse(qa.evaluate([dict(kind="state",key="verified",equals=True)],e)[0]["passed"])

    def test_boolean_does_not_satisfy_execution_count(self):
        self.assertFalse(qa.evaluate([dict(kind="count",key="remote_turn",equals=True)],evidence())[0]["passed"])

    def test_counts_and_order(self):
        e=evidence();e["events"].append(dict(e["events"][0],seq=2,type="continuation"))
        checks=[dict(kind="count",key="duplicate",equals=0),dict(kind="before",key="remote_turn",other="continuation",equals=True)]
        self.assertTrue(all(x["passed"] for x in qa.evaluate(checks,e)))
        e["events"].append(dict(e["events"][0],seq=3))
        self.assertFalse(qa.evaluate(checks,e)[1]["passed"])

    def test_no_continuation_can_satisfy_reconcile_first(self):
        e=evidence();e["observed_event_types"].append("continuation")
        check=dict(kind="before",key="remote_turn",other="continuation",equals=True,allow_absent_other=True)
        self.assertTrue(qa.evaluate([check],e)[0]["passed"])
        e["observed_event_types"].remove("continuation")
        with self.assertRaises(qa.Blocked):qa.evaluate([check],e)


class SinkTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.path=Path(self.tmp.name)/"attempts.jsonl";self.sink=qa.RecordingSandbox(self.path)
        self.args=dict(name="QA-unit [QA-TEST]",tool="email.send",attempt_id="QA-attempt-1",
                       payload=dict(marker=qa.MARK,account="QA-sandbox",recipient="a@example.invalid",body=qa.MARK+" A"))

    def test_record_only_never_delivers_or_networks(self):
        with patch("socket.socket",side_effect=AssertionError("network forbidden")):
            receipt=self.sink.record(**self.args)
        self.assertTrue(receipt["simulated"]);self.assertFalse(receipt["delivered"])
        self.assertEqual(len(self.path.read_text().splitlines()),1)

    def test_duplicate_attempts_retained_across_sink_restart(self):
        self.sink.record(**self.args)
        second=qa.RecordingSandbox(self.path).record(**self.args)
        self.assertTrue(second["duplicate"])
        self.assertEqual(len(self.path.read_text().splitlines()),2)

    def test_all_outbound_channels_are_record_only(self):
        with patch("socket.socket",side_effect=AssertionError("network forbidden")):
            for index,tool in enumerate(["email.send","slack.send","whatsapp.send","connected.read"]):
                args=copy.deepcopy(self.args);args.update(tool=tool,attempt_id=f"QA-attempt-{index}")
                self.assertFalse(self.sink.record(**args)["delivered"])
        self.assertEqual(len(self.path.read_text().splitlines()),4)

    def test_changed_payload_same_key_refused(self):
        self.sink.record(**self.args);self.args["payload"]["body"]=qa.MARK+" B"
        with self.assertRaises(qa.Refused):self.sink.record(**self.args)

    def test_real_recipient_account_body_and_extra_data_refused(self):
        for update in [{"recipient":"person@company.com"},{"account":"Work"},{"body":"real data"},{"api_key":"secret"}]:
            args=copy.deepcopy(self.args);args["payload"].update(update)
            with self.subTest(update=update),self.assertRaises(qa.Refused):self.sink.record(**args)
        self.assertFalse(self.path.exists())
        self.assertEqual(len(self.path.with_suffix(".refused.jsonl").read_text().splitlines()),4)

    def test_unknown_tools_refused(self):
        self.args["tool"]="shell"
        with self.assertRaises(qa.Refused):self.sink.record(**self.args)


class SafetyTransportSpy:
    """In-process hook boundary spy; cannot impersonate a Hermes endpoint."""
    def __init__(self,fail_action=False,unsafe_after_begin=False,cleanup_ok=True):
        self.calls=[];self.fail_action=fail_action;self.unsafe_after_begin=unsafe_after_begin;self.cleanup_ok=cleanup_ok

    def call(self,route,body):
        self.calls.append((route,body))
        if route=="attest":
            a=attestation(body["nonce"])
            if self.unsafe_after_begin and any(r=="begin" for r,_ in self.calls):a["real_connector_count"]=1
            return a
        if route=="begin":return {"acknowledged":True,"resource":body["resource"]}
        if route=="action":
            if self.fail_action:raise OSError("lost acknowledgement")
            return {"acknowledged":True,"action_id":body["action_id"]}
        if route=="observe":raise qa.Blocked("unit spy supplies no app evidence")
        if route=="cleanup":return {"active_qa_work":0 if self.cleanup_ok else 1,"remote_verified":self.cleanup_ok}
        raise AssertionError(route)


class DriverTests(unittest.TestCase):
    def execute(self,spy,steps=None):
        tmp=tempfile.TemporaryDirectory();self.addCleanup(tmp.cleanup);out=Path(tmp.name)
        scenario=dict(id="F03",steps=steps or [dict(op="chat.send",prompt="marker")],checks=[],requires=[])
        return qa.Driver(spy,"unit",out/"actions.jsonl").run(scenario,out)

    def test_uncertain_mutation_not_retried_cleanup_attempted(self):
        spy=SafetyTransportSpy(fail_action=True);result=self.execute(spy)
        self.assertEqual(sum(r=="action" for r,_ in spy.calls),1)
        self.assertEqual(sum(r=="cleanup" for r,_ in spy.calls),1)
        self.assertEqual(result["status"],"blocked")

    def test_midrun_real_connector_halts_before_any_action(self):
        spy=SafetyTransportSpy(unsafe_after_begin=True);result=self.execute(spy)
        self.assertFalse(any(r=="action" for r,_ in spy.calls))
        self.assertTrue(result["halt_suite"])

    def test_cleanup_failure_halts_suite(self):
        result=self.execute(SafetyTransportSpy(cleanup_ok=False))
        self.assertTrue(result["halt_suite"])
        self.assertIn("cleanup",result["reason"])

    def test_every_request_preceded_by_attestation(self):
        spy=SafetyTransportSpy();self.execute(spy)
        for index,(route,_) in enumerate(spy.calls):
            if route!="attest":self.assertEqual(spy.calls[index-1][0],"attest")

    def test_unlisted_action_never_crosses_boundary(self):
        spy=SafetyTransportSpy();result=self.execute(spy,[{"op":"shell"}])
        self.assertFalse(any(r=="action" for r,_ in spy.calls))
        self.assertEqual(result["status"],"blocked")

    def test_exhausted_action_budget_never_dispatches(self):
        with tempfile.TemporaryDirectory() as tmp:
            out=Path(tmp);spy=SafetyTransportSpy();driver=qa.Driver(spy,"unit",out/"actions.jsonl")
            driver.actions=qa.MAX_ACTIONS
            result=driver.run(dict(id="F03",steps=[dict(op="chat.send",prompt="marker")],checks=[],requires=[]),out)
            self.assertFalse(any(r=="action" for r,_ in spy.calls))
            self.assertTrue(result["halt_suite"])

    def test_linux_live_gate_never_contacts_hook(self):
        with tempfile.TemporaryDirectory() as tmp,patch.object(qa.platform,"system",return_value="Linux"),patch.object(qa.Hook,"call",side_effect=AssertionError("network forbidden")),patch.object(qa.unittest.defaultTestLoader,"discover",return_value=unittest.TestSuite()):
            code=qa.main(["--mode","live","--scenario","F03","--output",tmp])
            self.assertEqual(code,2)
            report=json.loads((Path(tmp)/"results.json").read_text())
            self.assertFalse(report["live_app_executed"])
            self.assertIn("Mac",report["results"][0]["reason"])


if __name__=="__main__":unittest.main()

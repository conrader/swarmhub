"""P6b: the apps' bundle-configurable settings, checked on Linux (Swift runs the same vectors on the Mac).

Runs scripts/release/app_config_reference.py over Tests/Fixtures/release-bundles/config/app-config.json, checks the
compiled defaults against the Swift sources they replace, and that the Mac and iOS apps share one resolution path.
"""

import json
from pathlib import Path
import re
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/release"))

import app_config_reference as ref  # noqa: E402
import config_reference  # noqa: E402

FIXTURES = ROOT / "Tests/Fixtures/release-bundles"
VECTORS = json.loads((FIXTURES / "config/app-config.json").read_text(encoding="utf-8"))
CORE = ROOT / "Packages/SwarmHubCore/Sources/SwarmHubCore/Updates/AppConfig.swift"
SWIFT = CORE.read_text(encoding="utf-8")
DEFAULTS = {(d, k): default for d, k, _, default, _, _ in ref.KEYS}


def swift_literal(name):
    """A `public var <name> = "<text>"` default in AppConfig.swift, with Swift escapes undone."""
    match = re.search(rf'public var {name} = "((?:[^"\\]|\\.)*)"', SWIFT)
    return match and match.group(1).encode().decode("unicode_escape").encode("latin-1").decode("utf-8")


class VectorTests(unittest.TestCase):
    def test_every_case_resolves_to_its_snapshot_and_reports(self):
        self.assertEqual([c["id"] for c in VECTORS["cases"]],
                         ["no-bundle", "release-policy", "bundle", "wrong-type", "out-of-range", "kill-switch", "denied"])
        for case in VECTORS["cases"]:
            with self.subTest(case=case["id"]):
                components = [(c["name"], (FIXTURES / c["archive"]).read_bytes()) for c in case["components"]]
                result = config_reference.decode(components)
                snapshot, reads = ref.resolve(result)
                self.assertEqual(snapshot, case["snapshot"])
                self.assertEqual(result["reports"] + reads, case["reports"])

    def test_no_bundle_and_the_shipped_policy_are_todays_values(self):
        compiled = ref.compiled()
        for case in VECTORS["cases"][:2]:
            self.assertEqual(case["snapshot"], compiled)
            self.assertEqual(case["reports"], [])
        policy = json.loads((ROOT / "scripts/release/policy_defaults.json").read_text(encoding="utf-8"))
        for key in ("codingOrder", "modelDefaults", "teamActions"):
            self.assertEqual(compiled[f"policy.{key}"], policy[key])
        self.assertEqual(compiled["policy.teamLimits"], policy["teamLimits"])

    def test_bundle_changes_every_key_and_kill_or_bad_values_never_do(self):
        compiled, cases = ref.compiled(), {c["id"]: c for c in VECTORS["cases"]}
        changed = cases["bundle"]["snapshot"]
        self.assertTrue(all(changed.get(k) != v for k, v in compiled.items()), "every compiled value changes")
        for case_id in ("wrong-type", "out-of-range"):
            self.assertEqual(cases[case_id]["snapshot"], compiled)
        killed = {r["domain"] + "." + r["key"] for r in cases["kill-switch"]["reports"] if r["reason"] == "killed"}
        for name in killed:
            self.assertEqual(cases["kill-switch"]["snapshot"].get(name), compiled.get(name), name)

    def test_keys_pass_the_denylist_and_approval_names_do_not(self):
        self.assertEqual([k["domain"] + "." + k["key"] for k in VECTORS["keys"]], [f"{d}.{k}" for d, k, *_ in ref.KEYS])
        for _, key, *_ in ref.KEYS:
            self.assertIsNone(config_reference.name_problem(key), key)
        for name in ("botPrompt.approvalRules", "approvers", "codingGate", "teamLimits.approvalTimeout", "managerTemplate.webhookURL"):
            self.assertEqual(config_reference.name_problem(name), "denied_key", name)
        self.assertNotIn("deploy", ref.TEAM_ACTIONS)  # actions can only narrow (out-of-range case widens and fails)

    def test_narrowed_actions_need_neither_help_nor_reporting(self):
        case = next(c for c in VECTORS["cases"] if c["id"] == "bundle")
        components = [(c["name"], (FIXTURES / c["archive"]).read_bytes()) for c in case["components"]]
        snapshot, reports = ref.resolve(config_reference.decode(components))
        self.assertEqual(reports, [])
        self.assertEqual(snapshot["policy.teamActions"], ["assign", "requestReview"])
        self.assertNotIn("requestHelp", snapshot["policy.teamActions"])
        self.assertNotIn("reportResult", snapshot["policy.teamActions"])

    def test_explicit_model_fallback_beats_bundle_and_unset_inherits(self):
        bundled = next(c["snapshot"] for c in VECTORS["cases"] if c["id"] == "bundle")
        local = dict(provider="TEST-local", model="TEST-choice")
        for role in ("conversation", "coding"):
            with self.subTest(role=role):
                self.assertIsNone(ref.model_default(ref.compiled(), role))
                self.assertIsNone(ref.model_default(ref.compiled(), role, agent_default=True))
                self.assertEqual(ref.model_default(ref.compiled(), role, choice=local), local)
                self.assertIsNone(ref.model_default(bundled, role, agent_default=True))
                self.assertEqual(ref.model_default(bundled, role, choice=local), local)
                models = bundled["policy.modelDefaults"]
                self.assertEqual(ref.model_default(bundled, role),
                                 dict(provider=models[role + "Provider"], model=models[role + "Model"]))

    def test_reviews_without_reporting_wait_for_user_acceptance(self):
        bundled = next(c["snapshot"] for c in VECTORS["cases"] if c["id"] == "bundle")
        for actions in (bundled["policy.teamActions"], ["assign"], []):
            with self.subTest(actions=actions):
                policy = ref.review_policy(actions)
                self.assertEqual(policy["completion"], "awaitingUserAcceptance")
                self.assertIn("The result goes to the user for acceptance", policy["instructions"])
                self.assertNotIn("verdict", policy["instructions"])

    def test_reporting_still_requires_a_structured_verdict(self):
        for actions in (None, ref.TEAM_ACTIONS, ["reportResult"]):
            self.assertEqual(ref.review_policy(actions), dict(
                instructions="reportResult with a verdict is required", completion="missingVerdict"))
            self.assertEqual(ref.review_policy(actions, has_structured_verdict=True)["completion"], "reported")
        self.assertEqual(ref.review_policy([], has_structured_verdict=True)["completion"], "reported")


class SourceParityTests(unittest.TestCase):
    def test_review_wording_and_routing_live_in_shared_coordination(self):
        shared = (ROOT / "Packages/SwarmHubCoordination/Sources/SwarmHubCoordination/TeamReviewPolicy.swift").read_text()
        for actions in (None, ["assign", "requestReview"]):
            self.assertIn(ref.review_policy(actions)["instructions"], shared)
        self.assertIn('actions?.contains("reportResult") ?? true', shared)
        self.assertIn("allowsReporting ? .missingVerdict : .awaitingUserAcceptance", shared)
        operations = (ROOT / "Sources/AgentApp/Stores/AppStore+WorkflowOperations.swift").read_text()
        dispatch = (ROOT / "Sources/AgentApp/Stores/AppStore+TeamDispatch.swift").read_text()
        self.assertIn("workflow.reviewPolicy.instructions", operations)
        self.assertIn("workflow.reviewPolicy.instructions", dispatch)
        self.assertNotIn("include your verdict in your reply", operations)
        self.assertIn("workflow.reviewPolicy.completion(hasStructuredVerdict: false)", operations)
        self.assertIn("workflow.tasks[index].state = .awaitingUserAcceptance", operations)
        recovery = (ROOT / "Sources/AgentApp/Stores/AppStore+TeamRecovery.swift").read_text()
        self.assertEqual(recovery.count("!workflow.awaitsUserAcceptance"), 2)

    def test_waiting_review_persistence_and_recovery_match_the_mirror(self):
        codec = (ROOT / "Sources/AgentApp/Models/WorkflowTask+Codable.swift").read_text()
        self.assertIn(ref.ACCEPTANCE_BLOCK, codec)
        self.assertIn('waiting ? State.blocked : state', codec)
        self.assertIn('values.encode(true, forKey: .awaitingUserAcceptance)', codec)
        self.assertIn('state = .awaitingUserAcceptance', codec)
        operations = (ROOT / "Sources/AgentApp/Stores/AppStore+WorkflowOperations.swift").read_text()
        completion = operations.split('func applyWorkflowCompletion(', 1)[1].split('func canAcceptWorkflowReview(', 1)[0]
        self.assertNotRegex(completion, r'resumeAfterRecovery\s*=')
        acceptance = operations.split('func acceptWorkflowReview(', 1)[1]
        self.assertIn('workflow.coordination?.resumeAfterRecovery = false', acceptance)
        # Every stored field still has both coding paths after replacing synthesized Codable.
        model = (ROOT / "Sources/AgentApp/Models/Workflow.swift").read_text().split('struct WorkflowTask:', 1)[1]
        model = model.split('var stateLabel:', 1)[0]
        for field in re.findall(r'^    var (\w+)', model, re.M):
            self.assertRegex(codec, rf'{field} = try values.decode(?:IfPresent)?\(')
            self.assertRegex(codec, rf'try values.encode(?:IfPresent)?\([^\n]+forKey: \.{field}\)')

    def test_swift_compiled_defaults_match_the_reference(self):
        for name, key in (("codingOrder", ("policy", "codingOrder")), ("owner", ("prompts", "botPrompt.owner")),
                          ("role", ("prompts", "botPrompt.role")), ("language", ("prompts", "botPrompt.language")),
                          ("coordinator", ("policy", "botPrompt.coordinator")),
                          ("codingOrderHelp", ("copy", "codingOrderHelp")), ("setupTitle", ("copy", "setupTitle")),
                          ("capabilityFooter", ("copy", "capabilityFooter"))):
            self.assertEqual(swift_literal(name), DEFAULTS[key], name)
        actions = re.search(r"public var teamActions = \[([^\]]*)\]", SWIFT).group(1)
        self.assertEqual(re.findall(r'"(\w+)"', actions), ref.TEAM_ACTIONS)
        limits = re.search(r"public struct TeamLimits[^{]*\{(.*?)public init", SWIFT, re.S).group(1)
        self.assertEqual({k: int(v) for k, v in re.findall(r"public var (\w+) = (\d+)", limits)}, ref.TEAM_LIMITS)
        self.assertIn("public var quietHoursStart = 22 * 60", SWIFT)
        self.assertIn("public var quietHoursEnd = 8 * 60", SWIFT)
        for _, key, *_ in ref.KEYS:
            literal = key if not key.startswith("managerRecipe.") else "managerRecipe."
            self.assertIn(f'"{literal}', SWIFT, key)
        self.assertIn(f"static let recipes = {json.dumps(list(ref.RECIPES))}", SWIFT)

    def test_compiled_defaults_match_the_app_constants_they_replace(self):
        coding = (ROOT / "Sources/AgentApp/Models/CodingOrder.swift").read_text(encoding="utf-8")
        help_text = re.search(r'static let help = "((?:[^"\\]|\\.)*)"', coding).group(1)
        self.assertEqual(help_text, DEFAULTS[("copy", "codingOrderHelp")])
        self.assertEqual(sorted(re.findall(r'case \w+ = "([^"]+)"', coding)), sorted(ref.CODING_ORDERS))
        recipes = (ROOT / "Sources/AgentApp/BotManager/BotManagerText.swift").read_text(encoding="utf-8")
        enum = re.search(r"enum Recipe: String, CaseIterable \{(.*?)var resourcePath", recipes, re.S).group(1)
        self.assertEqual(sorted(re.findall(r"case (\w+)", enum)), sorted(ref.RECIPES))
        orientation = (ROOT / "Sources/AgentApp/Models/OrientationPrompt.swift").read_text(encoding="utf-8")
        self.assertIn("static let defaultStart = 22 * 60, defaultEnd = 8 * 60", orientation)
        ios = {p.name: p.read_text(encoding="utf-8") for p in (ROOT / "Apps/iOS/Sources").glob("*.swift")}
        self.assertNotIn(f'Text("{DEFAULTS[("copy", "setupTitle")]}")', ios["SetupView.swift"])
        self.assertIn("store.appConfig.setupTitle", ios["SetupView.swift"])
        self.assertIn("store.appConfig.capabilityFooter", ios["SettingsView.swift"])

    def test_mac_and_ios_share_one_resolution_path(self):
        mac = ROOT / "Sources/AgentApp/Stores/AppStore+Config.swift"
        ios = ROOT / "Apps/iOS/Sources/MobileStore.swift"
        self.assertIn("AppConfig.load()", mac.read_text(encoding="utf-8"))
        self.assertIn("AppConfig.load()", ios.read_text(encoding="utf-8"))
        for folder in (ROOT / "Sources/AgentApp", ROOT / "Apps/iOS/Sources"):
            for path in folder.rglob("*.swift"):
                source = path.read_text(encoding="utf-8")
                self.assertNotRegex(source, r"\bConfigKey\b|AppConfig\(\s*ConfigStore", str(path.relative_to(ROOT)))
        models = (ROOT / "Sources/AgentApp/Models/ModelPolicy.swift").read_text(encoding="utf-8")
        self.assertIn("config.modelDefault(for: role, preference: preference)", models)
        self.assertIn("case .agentDefault: return nil", SWIFT)

    def test_new_sources_are_under_500_lines(self):
        for rel in ("Packages/SwarmHubCore/Sources/SwarmHubCore/Updates/AppConfig.swift",
                    "Packages/SwarmHubCore/Tests/SwarmHubCoreTests/AppConfigTests.swift",
                    "Sources/AgentApp/Stores/AppStore+Config.swift", "Tests/AgentAppTests/AppConfigWiringTests.swift",
                    "scripts/release/app_config_reference.py", "scripts/release/app_config_cases.py",
                    "scripts/release/make_config_vectors.py", "scripts/test_app_config.py"):
            self.assertLessEqual(len((ROOT / rel).read_text(encoding="utf-8").splitlines()), 500, rel)


class ReviewPersistenceTests(unittest.TestCase):
    def test_p6b3_waiting_state_migrates_and_round_trips_for_new_and_old_readers(self):
        p6b3 = dict(state="awaitingUserAcceptance", result="TEST findings", completionConfirmed=True,
                    reviewTargetID="work", chargedTokens=42)
        old_states = {"queued", "running", "completed", "blocked", "cancelled"}
        self.assertNotIn(p6b3["state"], old_states)
        self.assertEqual(ref.loaded_workflow_task(p6b3), p6b3)
        saved = json.loads(json.dumps(ref.saved_workflow_task(p6b3)))
        self.assertIn(saved["state"], old_states)
        self.assertEqual(saved["state"], "blocked")
        self.assertTrue(saved["completionConfirmed"])
        self.assertEqual(saved["reviewBlock"], ref.ACCEPTANCE_BLOCK)
        self.assertEqual(ref.loaded_workflow_task(saved), p6b3)
        del saved["awaitingUserAcceptance"]  # An old build saves only the fields it knows.
        reloaded = ref.loaded_workflow_task(saved)
        self.assertEqual(reloaded["state"], "blocked")
        self.assertTrue(reloaded["reviewBlock"])
        self.assertFalse(ref.can_resume_after_recovery(dict(resumeAfterRecovery=True, tasks=[reloaded])))

    def test_review_completion_retains_sibling_recovery_intent_and_blocks_resume(self):
        for intent in (False, True):
            for recovery_first in (False, True):
                for actions in (["assign", "requestReview"], ref.TEAM_ACTIONS):
                    with self.subTest(intent=intent, recovery_first=recovery_first, actions=actions):
                        workflow = dict(state="paused", actions=actions, resumeAfterRecovery=intent,
                                        tasks=[dict(state="running", reviewTargetID="work"), dict(state="blocked")])
                        ref.complete_workflow_task(workflow, 0, "TEST findings")
                        self.assertEqual(workflow["resumeAfterRecovery"], intent)
                        self.assertFalse(ref.can_resume_after_recovery(workflow))
                        if recovery_first:
                            workflow["tasks"][1]["state"] = "completed"
                            self.assertFalse(ref.can_resume_after_recovery(workflow))
                        ref.accept_workflow_review(workflow, 0)
                        self.assertFalse(workflow["resumeAfterRecovery"])
                        self.assertEqual(workflow["state"], "paused")
                        self.assertEqual(workflow["tasks"][0]["state"], "completed")
                        self.assertTrue(workflow["tasks"][0]["reviewAcceptedByUser"])
                        workflow["tasks"][1]["state"] = "completed"
                        self.assertFalse(ref.can_resume_after_recovery(workflow))


if __name__ == "__main__":
    unittest.main()

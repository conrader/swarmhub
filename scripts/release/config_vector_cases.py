"""P6a config vector cases (docs/update-service/SCHEMAS.md §12). Expectations are written by hand here; the generator
refuses to write vectors the reference decoder disagrees with, and Swift checks the same expectations.

A case: components (record order) with documents, reads with the expected value and read-time reason, views with
the expected kill state, and the exact decode reports in order.
"""

import json

import vector_world as vw
from vector_world import f

CODING = "claude,codex,hermes"


def doc(domain, **members):
    return json.dumps({"schema": f"swarmhub/config-{domain}/1", **members}, sort_keys=True).encode() + b"\n"


def raw(text):
    return text.encode("utf-8")


def r(domain, key, kind, default, expect, report=None, low=None, high=None):
    out = {"domain": domain, "key": key, "type": kind, "default": default, "expect": expect}
    if report:
        out["report"] = report
    if low is not None:
        out["min"], out["max"] = low, high
    return out


def rep(reason, domain=None, key=None, component=None):
    out = {"reason": reason}
    for name, value in (("domain", domain), ("key", key), ("component", component)):
        if value is not None:
            out[name] = value
    return out


def files(**documents):
    return [f(f"{name}.json", data) for name, data in documents.items()]


def sized(domain, size, **members):
    """A valid document of exactly `size` bytes."""
    data = doc(domain, pad="x" * (size - len(doc(domain, pad="", **members))), **members)
    assert len(data) == size
    return data


def corrupt_header(archive):
    return bytes([archive[0] ^ 0x01]) + archive[1:]


BASE_READS = [r("policy", "codingOrder", "string", CODING, CODING),
              r("flags", "routineCards", "bool", False, False),
              r("copy", "onboardingTitle", "string", "Welcome", "Welcome")]

FULL = files(
    policy=doc("policy", note="TEST", codingOrder="codex,claude,hermes", coding_job_limit=3,
               teamActions=["assign", "reportResult"], modelDefaults={"manager": "TEST-model"},
               teamLimits={"tasks": 20, "reviewRounds": 3}, autoRoutines=True),
    prompts=doc("prompts", managerTemplate="TEST manager prompt\nLine 2"),
    copy=doc("copy", onboardingTitle="Welcome to Swarm Hub (TEST)", helpLink="See https://example.test/help"),
    flags=doc("flags", routineCards=True, draftSendPreview=False),
) + [f("README.md", b"TEST: not a config document\n"), {"name": "nested/", "type": "dir", "mode": 0o755},
     f("nested/policy.json", doc("policy", codingOrder="hermes"))]

CASES = [
    ("no-bundle", "No config component: every read is its compiled default, nothing is reported.",
     [], BASE_READS, [("routine_card", False)], []),
    ("full", "Valid documents in all four domains; nested and non-document files are ignored.",
     [("app-config", FULL)],
     [r("policy", "codingOrder", "string", CODING, "codex,claude,hermes"),
      r("policy", "coding_job_limit", "integer", 2, 3, low=1, high=8),
      r("policy", "teamActions", "string_list", ["assign"], ["assign", "reportResult"]),
      r("policy", "modelDefaults", "string_map", {}, {"manager": "TEST-model"}),
      r("policy", "teamLimits", "integer_map", {"tasks": 12}, {"tasks": 20, "reviewRounds": 3}, low=0, high=1000),
      r("policy", "autoRoutines", "bool", False, True),
      r("prompts", "managerTemplate", "string", "compiled", "TEST manager prompt\nLine 2"),
      r("copy", "onboardingTitle", "string", "Welcome", "Welcome to Swarm Hub (TEST)"),
      r("copy", "helpLink", "string", "", "See https://example.test/help"),
      r("flags", "routineCards", "bool", False, True),
      r("flags", "draftSendPreview", "bool", True, False)],
     [("routine_card", False)], []),
    ("missing-key", "A document without the key, and a domain without a document: compiled defaults, no report.",
     [("app-config", files(policy=doc("policy", codingOrder="codex,claude,hermes")))],
     [r("policy", "coding_job_limit", "integer", 2, 2), r("copy", "onboardingTitle", "string", "Welcome", "Welcome"),
      r("flags", "routineCards", "bool", False, False)], [], []),
    ("wrong-type", "Values of another type: domain rules at decode, key types (and ranges) at read, each reported.",
     [("app-config", files(
         policy=doc("policy", codingOrder=7, coding_job_limit="3", maxParallel=99, teamActions=["assign", 3],
                    modelDefaults={"manager": 1}, teamLimits={"tasks": "x", "reviewRounds": 5000},
                    reviewLimits={"rounds": 5000}, autoRoutines="yes"),
         prompts=doc("prompts", managerTemplate=["a"]), copy=doc("copy", onboardingTitle=5),
         flags=doc("flags", routineCards="yes")))],
     [r("policy", "codingOrder", "string", CODING, CODING, "wrong_type"),
      r("policy", "codingOrder", "integer", 0, 7),
      r("policy", "coding_job_limit", "integer", 2, 2, "wrong_type"),
      r("policy", "maxParallel", "integer", 1, 1, "out_of_range", low=1, high=8),
      r("policy", "teamActions", "string_list", ["assign"], ["assign"], "wrong_type"),
      r("policy", "modelDefaults", "string_map", {}, {}, "wrong_type"),
      r("policy", "teamLimits", "integer_map", {"tasks": 12}, {"tasks": 12}, "wrong_type", low=0, high=1000),
      r("policy", "reviewLimits", "integer_map", {"rounds": 2}, {"rounds": 2}, "out_of_range", low=0, high=1000),
      r("policy", "autoRoutines", "bool", False, False, "wrong_type"),
      r("prompts", "managerTemplate", "string", "compiled", "compiled"),
      r("copy", "onboardingTitle", "string", "Welcome", "Welcome"),
      r("flags", "routineCards", "bool", False, False)],
     [], [rep("wrong_type", "prompts", "managerTemplate", "app-config"),
          rep("wrong_type", "copy", "onboardingTitle", "app-config"),
          rep("wrong_type", "flags", "routineCards", "app-config")]),
    ("schema-invalid", "Missing or wrong `schema`, or not an object: the whole document falls back.",
     [("app-config", files(policy=raw('{"codingOrder":"hermes"}'), prompts=doc("prompts").replace(b"/1", b"/2"),
                           copy=doc("flags", onboardingTitle="x"), flags=raw('["swarmhub/config-flags/1"]')))],
     BASE_READS, [],
     [rep("schema_invalid", d, component="app-config") for d in ("policy", "prompts", "copy", "flags")]),
    ("config-invalid", "Not profile JSON (float, null, duplicate member, trailing bytes): the document falls back.",
     [("app-config", files(policy=raw('{"schema":"swarmhub/config-policy/1","codingOrder":"hermes","x":1.5}'),
                           prompts=raw('{"schema":"swarmhub/config-prompts/1","a":"x","a":"y"}'),
                           copy=raw('{"schema":"swarmhub/config-copy/1","onboardingTitle":null}'),
                           flags=raw('{"schema":"swarmhub/config-flags/1","routineCards":true} x')))],
     BASE_READS, [],
     [rep("config_invalid", d, component="app-config") for d in ("policy", "prompts", "copy", "flags")]),
    ("size-limit", "A document of exactly 262144 bytes is read; one byte more falls back.",
     [("app-config", files(policy=sized("policy", 262_145, codingOrder="hermes"),
                           copy=sized("copy", 262_144, onboardingTitle="TEST at limit")))],
     [r("policy", "codingOrder", "string", CODING, CODING),
      r("copy", "onboardingTitle", "string", "Welcome", "TEST at limit")],
     [], [rep("config_too_large", "policy", component="app-config")]),
    ("duplicate-document", "Two components carry policy.json: neither wins; their other documents still count.",
     [("config-a", files(policy=doc("policy", codingOrder="hermes"), copy=doc("copy", onboardingTitle="TEST a"))),
      ("config-b", files(policy=doc("policy", codingOrder="codex"), flags=doc("flags", routineCards=True)))],
     [r("policy", "codingOrder", "string", CODING, CODING), r("copy", "onboardingTitle", "string", "Welcome", "TEST a"),
      r("flags", "routineCards", "bool", False, True)],
     [], [rep("duplicate_document", "policy", component="config-a"),
          rep("duplicate_document", "policy", component="config-b")]),
    ("kill-switch", "kill.<domain>.<key> and kill.view.<type>: true selects the compiled fallback, false does nothing.",
     [("app-config", files(
         policy=doc("policy", codingOrder="codex,claude,hermes", coding_job_limit=3),
         copy=doc("copy", onboardingTitle="TEST title", onboardingSubtitle="TEST sub"),
         flags=doc("flags", **{"routineCards": True, "kill.policy.codingOrder": True,
                               "kill.copy.onboardingSubtitle": False, "kill.flags.routineCards": True,
                               "kill.prompts.managerTemplate": True, "kill.view.routine_card": True,
                               "kill.view.settings_pane": False})))],
     [r("policy", "codingOrder", "string", CODING, CODING, "killed"),
      r("policy", "coding_job_limit", "integer", 2, 3),
      r("copy", "onboardingTitle", "string", "Welcome", "TEST title"),
      r("copy", "onboardingSubtitle", "string", "", "TEST sub"),
      r("flags", "routineCards", "bool", False, False, "killed"),
      r("flags", "kill.view.routine_card", "bool", False, False),
      r("prompts", "managerTemplate", "string", "compiled", "compiled", "killed")],
     [("routine_card", True), ("settings_pane", False), ("onboarding", False)], []),
    ("kill-invalid", "Kill flags with an unknown scope, an empty or kill.* target, or a non-boolean are refused.",
     [("app-config", files(flags=doc("flags", **{
         "kill.bogus.x": True, "kill.policy.kill.view.routine_card": True, "kill.view": True, "kill.policy.": True,
         "kill.view.routine_card": "yes", "killer": True})))],
     [r("flags", "killer", "bool", False, True)], [("routine_card", False)],
     [rep("invalid_kill", "flags", k, "app-config") for k in ("kill.bogus.x", "kill.policy.", "kill.policy.kill.view.routine_card")]
     + [rep("invalid_kill", "flags", "kill.view", "app-config"),
        rep("wrong_type", "flags", "kill.view.routine_card", "app-config")]),
    ("denylist-keys", "CORE-PLAN §4: names about approvals, approvers, gates, keys, secrets, devices or endpoints are "
     "refused in every domain, nested names included; look-alikes such as delegate or keyboard are not.",
     [("app-config", files(
         policy=doc("policy", approvalKeys=["TEST"], approvers=["TEST"], codingGate="off", gate_class="low",
                    secretStore="x", remoteHost="x", apiKey="x", deviceRequired=False, signingKey="x",
                    authToken="x", requireConfirmation=False, gatewayURL="x", **{"operation-review": "x"},
                    pins=1, teamLimits={"tasks": 3, "approvalTimeout": 60}, delegateLimit=3,
                    keyboardLayout="TEST", aggregateWindow=5),
         prompts=doc("prompts", approvalPrompt="x", secretEntryHelp="x", managerTemplate="TEST template"),
         copy=doc("copy", deviceEnrollTitle="x", operationReviewTitle="x", signInButton="TEST sign in"),
         flags=doc("flags", **{"managedApprovals": True, "deviceSigning": True, "kill.view.operation_review": True,
                               "kill.view.secret_entry": True, "routineCards": True})))],
     [r("policy", "approvers", "string_list", [], []),
      r("policy", "teamLimits", "integer_map", {"tasks": 12}, {"tasks": 12}),
      r("policy", "delegateLimit", "integer", 1, 3),
      r("policy", "keyboardLayout", "string", "", "TEST"),
      r("policy", "aggregateWindow", "integer", 1, 5),
      r("prompts", "approvalPrompt", "string", "compiled", "compiled"),
      r("prompts", "managerTemplate", "string", "compiled", "TEST template"),
      r("copy", "operationReviewTitle", "string", "Review", "Review"),
      r("copy", "signInButton", "string", "Sign in", "TEST sign in"),
      r("flags", "managedApprovals", "bool", True, True),
      r("flags", "routineCards", "bool", False, True)],
     [("operation_review", False), ("secret_entry", False)],
     [rep("denied_key", "policy", k, "app-config") for k in (
         "apiKey", "approvalKeys", "approvers", "authToken", "codingGate", "deviceRequired", "gate_class",
         "gatewayURL", "operation-review", "pins", "remoteHost", "requireConfirmation", "secretStore", "signingKey",
         "teamLimits")]
     + [rep("denied_key", "prompts", k, "app-config") for k in ("approvalPrompt", "secretEntryHelp")]
     + [rep("denied_key", "copy", k, "app-config") for k in ("deviceEnrollTitle", "operationReviewTitle")]
     + [rep("denied_key", "flags", k, "app-config") for k in (
         "deviceSigning", "kill.view.operation_review", "kill.view.secret_entry", "managedApprovals")]),
    ("denylist-values", "Policy strings that look like endpoints or name approvals and secrets are refused; copy and "
     "prompts are display text and may contain them.",
     [("app-config", files(
         policy=doc("policy", note="https://ignored.test", helpBase="https://evil.test/x",
                    controlPath="/swarmhub/control/v1/decide", teamActions=["assign", "approveOperation"],
                    modelDefaults={"manager": "TEST-model", "coder": "ftp://x"}, codingOrder="codex,claude,hermes"),
         prompts=doc("prompts", managerTemplate="Ask before you approve anything."),
         copy=doc("copy", helpLink="https://example.test/help")))],
     [r("policy", "helpBase", "string", "", ""), r("policy", "teamActions", "string_list", ["assign"], ["assign"]),
      r("policy", "codingOrder", "string", CODING, "codex,claude,hermes"),
      r("prompts", "managerTemplate", "string", "compiled", "Ask before you approve anything."),
      r("copy", "helpLink", "string", "", "https://example.test/help")],
     [], [rep("denied_value", "policy", k, "app-config")
          for k in ("controlPath", "helpBase", "modelDefaults", "teamActions")]),
    ("invalid-key", "Names outside [A-Za-z0-9._-]{1,128}, at the top level or nested, are refused.",
     [("app-config", files(policy=doc("policy", **{"bad key": 1, "": 1, "k" * 129: 1, "k" * 128: 4,
                                                   "teamLimits": {"bad key": 1}, "codingOrder": "hermes"})))],
     [r("policy", "k" * 128, "integer", 0, 4), r("policy", "codingOrder", "string", CODING, "hermes")],
     [], [rep("invalid_key", "policy", k, "app-config") for k in ("", "bad key", "k" * 129, "teamLimits")]),
    ("archive-problems", "A malformed, code-bearing, linked or unreadable component is refused as a whole; the "
     "others still count.",
     [("malformed", "corrupt", files(policy=doc("policy", codingOrder="hermes"))),
      ("code", files(policy=doc("policy", codingOrder="hermes")) + [f("run.py", b"print('TEST')\n")]),
      ("linked", files(policy=doc("policy", codingOrder="hermes"))
       + [{"name": "link.json", "type": "symlink", "mode": 0o644, "linkname": "policy.json"}]),
      ("unreadable", None),
      ("good", files(copy=doc("copy", onboardingTitle="TEST good")))],
     [r("policy", "codingOrder", "string", CODING, CODING),
      r("copy", "onboardingTitle", "string", "Welcome", "TEST good")],
     [], [rep("archive_malformed", component="malformed"), rep("component_not_data", component="code"),
          rep("archive_link", component="linked"), rep("component_unreadable", component="unreadable")]),
    ("not-documents", "Only regular files named <domain>.json at the archive root are documents.",
     [("app-config", [{"name": "policy.json/", "type": "dir", "mode": 0o755}, f("policy.json/x.json", b"{}\n"),
                      f("Copy.json", doc("copy", onboardingTitle="x")), f("flags.txt", b"routineCards=true\n"),
                      {"name": "prompts/", "type": "dir", "mode": 0o755},
                      f("prompts/prompts.json", doc("prompts", managerTemplate="x"))])],
     BASE_READS + [r("prompts", "managerTemplate", "string", "compiled", "compiled")], [], []),
]

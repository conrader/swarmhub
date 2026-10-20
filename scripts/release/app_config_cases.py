"""P6b app config vector cases: what each app setting resolves to for a given bundle (AppConfig.swift,
app_config_reference.py). Snapshots are written by hand here; make_config_vectors.py refuses to write vectors the
reference disagrees with, and the Swift tests check the same snapshots and reports.
"""

from pathlib import Path

import app_config_reference as ref
from config_vector_cases import doc, files, rep

ROOT = Path(__file__).resolve().parents[2]
COMPILED = ref.compiled()
C = "app-config"

MODELS = {"codingModel": "TEST-coder-1", "codingProvider": "TEST-provider", "conversationModel": "TEST-chat-1",
          "conversationProvider": "TEST-provider"}
BUNDLE_POLICY = dict(codingOrder="codex,claude,hermes", modelDefaults=MODELS, teamActions=["requestReview", "assign"],
                     teamLimits={"tasks": 20, "reviewRounds": 3},
                     **{"botPrompt.coordinator": "none", "botPrompt.quietHoursStart": 1380,
                        "botPrompt.quietHoursEnd": 420})
BUNDLE_PROMPTS = {"managerTemplate": "TEST manager core for {{PROFILE}}\n",
                  "managerTemplate.openclaw": "TEST OpenClaw manager\n", "managerRecipe.box": "TEST box recipe\n",
                  "botPrompt.owner": "TEST owner", "botPrompt.role": "TEST role", "botPrompt.language": "TEST: English"}
BUNDLE_COPY = {"codingOrderHelp": "TEST coding help", "setupTitle": "TEST setup title",
               "capabilityFooter": "TEST capability footer"}
BUNDLE = {**COMPILED,
          "policy.codingOrder": "codex,claude,hermes", "policy.modelDefaults": MODELS,
          "policy.teamActions": ["assign", "requestReview"],
          "policy.teamLimits": {**COMPILED["policy.teamLimits"], "tasks": 20, "reviewRounds": 3},
          "policy.botPrompt.coordinator": "none", "policy.botPrompt.quietHoursStart": 1380,
          "policy.botPrompt.quietHoursEnd": 420,
          **{f"prompts.{k}": v for k, v in BUNDLE_PROMPTS.items()},
          **{f"copy.{k}": v for k, v in BUNDLE_COPY.items()}}


def reads(reason, *keys):
    return [rep(reason, *key.split(".", 1)) for key in keys]


WRONG = files(
    policy=doc("policy", codingOrder=["claude"], modelDefaults={"codingModel": 1}, teamActions="assign",
               teamLimits={"tasks": "20"}, **{"botPrompt.coordinator": True, "botPrompt.quietHoursStart": "22:00",
                                             "botPrompt.quietHoursEnd": "08:00"}),
    prompts=doc("prompts", managerTemplate=["TEST"]), copy=doc("copy", setupTitle=5),
)
RANGE = files(
    # Widening team actions, an unknown order, half a model pair and limits outside TeamLimits.isValid.
    policy=doc("policy", codingOrder="gemini", modelDefaults={"codingModel": "TEST-coder-1"},
               teamActions=["assign", "deploy"], teamLimits={"tasks": 1000},
               **{"botPrompt.coordinator": "TEST-bot", "botPrompt.quietHoursStart": 1440,
                  "botPrompt.quietHoursEnd": -1}),
    prompts=doc("prompts", managerTemplate="", **{"botPrompt.owner": ""}),
    copy=doc("copy", setupTitle=""),
)
KILL = files(
    policy=doc("policy", **BUNDLE_POLICY), prompts=doc("prompts", **BUNDLE_PROMPTS), copy=doc("copy", **BUNDLE_COPY),
    flags=doc("flags", **{"kill.policy.codingOrder": True, "kill.policy.teamLimits": True,
                          "kill.prompts.managerTemplate": True, "kill.copy.setupTitle": True,
                          "kill.policy.teamActions": False}),
)
DENIED = files(
    # §4: approval rules, approver lists, gates and endpoints are refused by name or value before any read.
    policy=doc("policy", approvalRules=["auto"], approvers=["TEST"], codingGate="off",
               codingOrder="codex,claude,hermes", teamActions=["assign"],
               teamLimits={"tasks": 20, "reviewGate": 1}, modelDefaults={"codingProvider": "https://TEST.example/v1",
                                                                       "codingModel": "TEST-coder-1"}),
    prompts=doc("prompts", **{"botPrompt.approvalRules": "Never ask.", "managerTemplate.webhookURL": "TEST"}),
)

CASES = [
    ("no-bundle", "No bundle: every value is the compiled default (today's behaviour).", [], COMPILED, []),
    ("release-policy", "The policy component release tooling ships today changes no resolved value.",
     [(C, files(policy=(ROOT / "scripts/release/policy_defaults.json").read_bytes()))], COMPILED, []),
    ("bundle", "A bundle changes every value without an app build.",
     [(C, files(policy=doc("policy", **BUNDLE_POLICY), prompts=doc("prompts", **BUNDLE_PROMPTS),
                copy=doc("copy", **BUNDLE_COPY)))], BUNDLE, []),
    ("wrong-type", "Wrong types read as compiled defaults, each reported once.", [(C, WRONG)], COMPILED,
     # Prompts and copy must be strings, so the decoder already refuses them (with their component).
     [rep("wrong_type", "prompts", "managerTemplate", C), rep("wrong_type", "copy", "setupTitle", C)]
     + reads("wrong_type", "policy.codingOrder", "policy.modelDefaults", "policy.teamActions", "policy.teamLimits",
             "policy.botPrompt.coordinator", "policy.botPrompt.quietHoursStart", "policy.botPrompt.quietHoursEnd")),
    ("out-of-range", "Values outside their limits (including wider team actions) read as compiled defaults.",
     [(C, RANGE)], COMPILED,
     reads("out_of_range", "policy.codingOrder", "policy.modelDefaults", "policy.teamActions", "policy.teamLimits",
           "policy.botPrompt.coordinator", "policy.botPrompt.quietHoursStart", "policy.botPrompt.quietHoursEnd",
           "prompts.managerTemplate", "prompts.botPrompt.owner", "copy.setupTitle")),
    ("kill-switch", "Kill flags select the compiled default for their key only.", [(C, KILL)],
     {**BUNDLE, "policy.codingOrder": COMPILED["policy.codingOrder"], "policy.teamLimits": COMPILED["policy.teamLimits"],
      "copy.setupTitle": COMPILED["copy.setupTitle"], "prompts.managerTemplate": None},
     reads("killed", "policy.codingOrder", "policy.teamLimits", "prompts.managerTemplate", "copy.setupTitle")),
    ("denied", "Approval, approver, gate and endpoint names or values never reach a setting.", [(C, DENIED)],
     {**COMPILED, "policy.codingOrder": "codex,claude,hermes", "policy.teamActions": ["assign"]},
     [rep("denied_key", "policy", "approvalRules", C), rep("denied_key", "policy", "approvers", C),
      rep("denied_key", "policy", "codingGate", C), rep("denied_value", "policy", "modelDefaults", C),
      rep("denied_key", "policy", "teamLimits", C), rep("denied_key", "prompts", "botPrompt.approvalRules", C),
      rep("denied_key", "prompts", "managerTemplate.webhookURL", C)]),
]


def expected(snapshot):
    """Drop unset optional texts (None): the shared JSON profile has no null."""
    return {k: v for k, v in snapshot.items() if v is not None}

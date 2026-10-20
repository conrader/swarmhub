"""Reference resolution of the apps' bundle-configurable settings (phase P6b). Stdlib only.

The Python statement of Packages/SwarmHubCore/Sources/SwarmHubCore/Updates/AppConfig.swift: each key, its compiled
default (today's app behaviour) and its limits, read through config_reference.read in the same order as Swift.
`resolve` returns the snapshot both the Swift tests and scripts/test_app_config.py compare with
Tests/Fixtures/release-bundles/config/app-config.json. An optional text that is unset (compiled resource) is absent
from the snapshot, because the shared JSON profile has no null.
"""

import config_reference
from copy import deepcopy

CODING_ORDERS = ("claude,codex,hermes", "codex,claude,hermes", "claude", "codex", "hermes")
MODEL_MEMBERS = ("codingModel", "codingProvider", "conversationModel", "conversationProvider")
TEAM_ACTIONS = ["assign", "reportResult", "requestHelp", "requestReview"]
TEAM_LIMITS = {"activeSeconds": 1800, "handoffDepth": 3, "operations": 48, "parallelTasks": 1, "reviewRounds": 2,
               "tasks": 12}
TEAM_LIMIT_RANGES = {"activeSeconds": (60, 86_400), "handoffDepth": (1, 10), "operations": (4, 400),
                     "parallelTasks": (1, 4), "reviewRounds": (1, 5), "tasks": (2, 100)}
COORDINATORS = ("automatic", "none")
RECIPES = ("accounts", "box", "capacity", "models")
CODING_ORDER_HELP = ("Who does a bot’s coding tasks. The next one is used only when the previous isn’t "
                     "installed, isn’t logged in, or hits its usage limit. A change asks to update that bot’s "
                     "coding skill.")


def _usable_id(text):
    data = text.encode("utf-8")
    return 1 <= len(data) <= 200 and all(0x21 <= b <= 0x7E for b in data)


def _one_of(allowed):
    return lambda v: v in allowed


def _non_empty(v):
    return len(v) > 0


def _models(v):
    paired = all((f"{role}Provider" in v) == (f"{role}Model" in v) for role in ("coding", "conversation"))
    return paired and all(k in MODEL_MEMBERS and _usable_id(text) for k, text in v.items())


def _actions(v):
    return bool(v) and len(set(v)) == len(v) and all(a in TEAM_ACTIONS for a in v)


def _limits(v):
    return all(k in TEAM_LIMIT_RANGES and TEAM_LIMIT_RANGES[k][0] <= n <= TEAM_LIMIT_RANGES[k][1] for k, n in v.items())


# (domain, key, read type, compiled default, extra limit or None, integer bounds or None), in Swift's read order.
# A default of None is an optional text whose compiled value is the app's own resource file.
KEYS = [
    ("policy", "codingOrder", "string", "claude,codex,hermes", _one_of(CODING_ORDERS), None),
    ("policy", "modelDefaults", "string_map", {}, _models, None),
    ("policy", "teamActions", "string_list", TEAM_ACTIONS, _actions, None),
    ("policy", "teamLimits", "integer_map", {}, _limits, None),
    ("policy", "botPrompt.coordinator", "string", "automatic", _one_of(COORDINATORS), None),
    ("policy", "botPrompt.quietHoursStart", "integer", 22 * 60, None, (0, 1439)),
    ("policy", "botPrompt.quietHoursEnd", "integer", 8 * 60, None, (0, 1439)),
    ("prompts", "managerTemplate", "string", None, _non_empty, None),
    ("prompts", "managerTemplate.openclaw", "string", None, _non_empty, None),
    *[("prompts", f"managerRecipe.{name}", "string", None, _non_empty, None) for name in RECIPES],
    ("prompts", "botPrompt.owner", "string", "the user", _non_empty, None),
    ("prompts", "botPrompt.role", "string", "Personal assistant", _non_empty, None),
    ("prompts", "botPrompt.language", "string",
     "Match the user's current language; follow an explicit language preference.", _non_empty, None),
    ("copy", "codingOrderHelp", "string", CODING_ORDER_HELP, _non_empty, None),
    ("copy", "setupTitle", "string", "Bring your agents.", _non_empty, None),
    ("copy", "capabilityFooter", "string",
     "Server capability support does not imply every mobile control is implemented in this foundation build.",
     _non_empty, None),
]


def resolve(result):
    """(snapshot, read-time reports in first-seen order) for a decoded or snapshotted config result."""
    snapshot, reports = {}, []
    for domain, key, kind, default, limit, bounds in KEYS:
        value, reason = config_reference.read(result, domain, key, kind, default, *(bounds or ()))
        if reason is None and limit is not None and value is not default and not limit(value):
            value, reason = default, "out_of_range"
        if reason:
            reports.append(config_reference.report(reason, domain, key))
        if kind == "string_list":
            value = sorted(value, key=lambda s: s.encode("utf-8"))
        if key == "teamLimits":
            value = {**TEAM_LIMITS, **value}
        if value is not None:
            snapshot[f"{domain}.{key}"] = value
    return snapshot, reports


def compiled():
    """The snapshot with no bundle: every key's compiled default."""
    return resolve(config_reference.decode([]))[0]


def model_default(snapshot, role, choice=None, agent_default=False):
    """AppConfig.modelDefault: an explicit local pair or fallback wins over an unset role's bundle value."""
    if agent_default:
        return None
    if choice is not None:
        return choice
    models = snapshot["policy.modelDefaults"]
    if role + "Provider" in models:
        return dict(provider=models[role + "Provider"], model=models[role + "Model"])
    return None


def review_policy(actions=None, has_structured_verdict=False):
    """TeamReviewPolicy: reply text is deliberately not an input to verdict routing."""
    reporting = actions is None or "reportResult" in actions
    instructions = ("reportResult with a verdict is required" if reporting else
                    "Return your findings in a normal reply. The result goes to the user for acceptance; "
                    "the workflow waits for that acceptance.")
    completion = ("reported" if has_structured_verdict else
                  "missingVerdict" if reporting else "awaitingUserAcceptance")
    return dict(instructions=instructions, completion=completion)


ACCEPTANCE_BLOCK = ("The review is waiting for user acceptance. Read the findings, then accept the review "
                    "with its noted limitations or cancel this workflow.")


def saved_workflow_task(task):
    """WorkflowTask's rollback-compatible ledger shape; old builds retain their existing review guard."""
    saved = deepcopy(task)
    if task["state"] == "awaitingUserAcceptance":
        saved.update(state="blocked", awaitingUserAcceptance=True, completionConfirmed=True)
        saved["reviewBlock"] = task.get("reviewBlock") or ACCEPTANCE_BLOCK
        saved["error"] = task.get("error") or ACCEPTANCE_BLOCK
    return saved


def loaded_workflow_task(saved):
    task = deepcopy(saved)
    if task.pop("awaitingUserAcceptance", False):
        task["state"] = "awaitingUserAcceptance"
        for field in ("reviewBlock", "error"):
            if task.get(field) == ACCEPTANCE_BLOCK:
                task.pop(field)
    return task


def complete_workflow_task(workflow, index, reply):
    """Mirror applyWorkflowCompletion: a task completion never owns siblings' recovery intent."""
    task = workflow["tasks"][index]
    task.update(completionConfirmed=True, result=task.get("reportedResult", reply), state="completed")
    task.pop("error", None)
    if task.get("reviewTargetID") and not task.get("reviewVerdict"):
        if review_policy(workflow.get("actions"))["completion"] == "awaitingUserAcceptance":
            task["state"] = "awaitingUserAcceptance"
            if workflow["state"] != "cancelled":
                workflow["state"] = "paused"
                workflow.pop("error", None)
            return
        task["reviewBlock"] = "Missing structured verdict"
    if task.get("reviewBlock") and not task.get("reviewAcceptedByUser"):
        task.update(state="blocked", error=task["reviewBlock"])
        if workflow["state"] != "cancelled":
            workflow.update(state="paused", error=task["reviewBlock"])


def accept_workflow_review(workflow, index):
    """Mirror acceptWorkflowReview: acceptance leaves the workflow paused until Resume."""
    task = workflow["tasks"][index]
    if (workflow["state"] != "paused" or not task.get("completionConfirmed")
            or not (task["state"] == "awaitingUserAcceptance"
                    or (task["state"] == "blocked" and task.get("reviewBlock")))):
        return
    task.update(reviewAcceptedByUser=True, state="completed")
    task.pop("error", None)
    workflow.pop("error", None)
    workflow["resumeAfterRecovery"] = False


def can_resume_after_recovery(workflow):
    return (workflow.get("resumeAfterRecovery", False)
            and not any(t["state"] in ("blocked", "awaitingUserAcceptance") for t in workflow["tasks"]))

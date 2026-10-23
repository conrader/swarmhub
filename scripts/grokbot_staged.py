"""Routines and connector requests from a Grok Bot transcript, for export-grokbot.py (mirrored by
Sources/AgentApp/GrokExport/Mapping/GrokStagedConfig.swift). Python 3 stdlib only."""
import hashlib

ROUTINES_LIMITATION = ("Grok Bot routines were imported by name only and paused: Grok Bot keeps no schedule or prompt for them, "
                       "so each needs setup.")
CONNECTORS_LIMITATION = ("Connectors this bot asked for were imported as suggestions only; no account, token or credential "
                         "was copied.")


class StagedConfig:
    """Routines and connector requests from `automation-changed` events and connector cards. Grok Bot keeps no schedule
    or prompt for an automation; both import inert. A card's `serverId` and `reauth.accountKey` are never read."""
    UNNAMED = "Imported routine"

    def __init__(self):
        self.automations, self.connectors = {}, []

    def automation(self, event, seq, index):
        automation_id = event.get("automationId")
        if not isinstance(automation_id, str) or not automation_id.strip():
            return False
        at = (seq, index)
        state = self.automations.setdefault(automation_id, {"first": at, "latest": at, "action": None, "named": None, "name": None})
        state["first"] = min(state["first"], at)
        if at >= state["latest"]:
            state["latest"], state["action"] = at, event.get("action") if isinstance(event.get("action"), str) else None
        name = event.get("automationName")
        if isinstance(name, str) and name.strip() and (state["named"] is None or at >= state["named"]):
            state["named"], state["name"] = at, name
        return True

    def connector(self, card, seq, index):
        raw = card.get("connector")
        if not isinstance(raw, str) or not raw.strip():
            return False
        self.connectors.append(((seq, index), raw))
        return True

    def routines(self, redact):
        """Latest state wins per automation; a deleted one is left out. Names redacted, ids hashed, never enabled."""
        out = []
        for automation_id, state in sorted(self.automations.items(), key=lambda item: item[1]["first"]):
            if state["action"] == "deleted":
                continue
            name = redact(state["name"] or self.UNNAMED).strip() or self.UNNAMED
            out.append({"id": routine_id(automation_id), "name": name, "prompt": "", "schedule": None, "trigger": None,
                        "timezone": None, "enabled": False})
        return out

    def connector_names(self, redact):
        """Each distinct connector once, first seen first; one whose name held a secret is left out."""
        seen, names = set(), []
        for _, raw in sorted(self.connectors, key=lambda item: item[0]):
            if raw in seen:
                continue
            seen.add(raw)
            if redact(raw) != raw:
                continue
            name = connector_name(raw)
            if name and name not in names:
                names.append(name)
        return [{"name": name} for name in names]


def routine_id(automation_id):
    return "grok-automation-" + hashlib.sha256(automation_id.encode("utf-8", "surrogatepass")).hexdigest()[:24]


def connector_name(raw):
    """ASCII letters lowercased, digits kept, every other run of characters one `-`, trimmed, at most 64 characters."""
    name, dash = [], False
    for ch in raw:
        if "A" <= ch <= "Z" or "a" <= ch <= "z" or "0" <= ch <= "9":
            name.append(ch.lower())
            dash = False
        elif not dash:
            name.append("-")
            dash = True
    return "".join(name).strip("-")[:64].strip("-")

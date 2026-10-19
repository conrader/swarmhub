"""Text-only port of GoalRun's evidence display and /goal start/status notices.

The native app remains the driver; this sim checks the same automatic/explicit
mode and user-facing text without changing the classifier or starting any turns.
"""
from __future__ import annotations

from dataclasses import dataclass, field

try:
    from sim.goal_classifier import looks_like_coding
except ImportError:
    from goal_classifier import looks_like_coding


@dataclass
class GoalRun:
    text: str
    coding_evidence: bool | None = None
    state: str = "running"
    round: int = 0
    max_rounds: int = 20
    started_at: float = 0
    max_duration: float = 7200
    paused_offline: bool = False
    subgoals: list[str] = field(default_factory=list)
    need: str | None = None
    last_summary: str | None = None

    @classmethod
    def from_command(cls, text):
        if text.startswith("--coding "):
            return cls(text[9:], coding_evidence=True)
        if text.startswith("--general "):
            return cls(text[10:], coding_evidence=False)
        return cls(text)

    @property
    def requires_coding_evidence(self):
        return looks_like_coding(self.text) if self.coding_evidence is None else self.coding_evidence

    @property
    def evidence_status(self):
        mode = "coding" if self.requires_coding_evidence else "general"
        source = "auto" if self.coding_evidence is None else "explicit"
        requirement = ("commit or test pass + report required" if self.requires_coding_evidence else
                       "chat deliverable; coding evidence not required")
        return (f"Evidence: {mode} ({source}; {requirement}).\n"
                "To override, /goal clear, then /goal --coding <text> or /goal --general <text>.")

    @property
    def start_notice(self):
        return f"Goal: {self.text}\n{self.evidence_status}"

    def status(self, now):
        offline = " (offline)" if self.paused_offline else ""
        lines = [f"Goal: {self.text}",
                 f"{self.state.capitalize()}{offline} · round {self.round}/{self.max_rounds} · "
                 f"{int((now - self.started_at) / 60)} min of {int(self.max_duration / 60)}",
                 self.evidence_status]
        lines += [f"  {index}. {text}" for index, text in enumerate(self.subgoals, 1)]
        if self.need is not None:
            lines.append(f"Needs: {self.need}")
        if self.last_summary is not None:
            lines.append(f"Last: {self.last_summary}")
        return "\n".join(lines)

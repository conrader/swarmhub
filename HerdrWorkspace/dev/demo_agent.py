"""Interactive, model-free preview agent. Input is never executed."""
import re
import signal
import subprocess
import sys

REPLIES = {
    "briefing": (
        "## Release briefing\n\n"
        "The release notes and FAQ are ready for review. The remaining decision is "
        "which customer group should get the announcement first.\n\n"
        "- Get sign-off on the lead message.\n"
        "- Confirm the announcement date with Support.\n"
        "- Send a short update after the decision."
    ),
    "planner": (
        "## Planning notes\n\n"
        "Start with two owners: one for the announcement, one for the FAQ. "
        "Give reviewers a day to respond, then publish both together.\n\n"
        "**Next step:** confirm who owns the final review."
    ),
}


def status(state):
    print("\x1b]7501;state=" + state + "\x1b\\", end="", flush=True)


def interrupted(*_):
    raise InterruptedError


def main(bridge, role):
    signal.signal(signal.SIGINT, interrupted)
    print("SwarmHub preview agent. Replies are examples; no model is connected.", flush=True)
    status("idle")
    count = 0
    while True:
        try:
            task = re.sub(r"\x1b\[(?:200|201)~", "", input()).strip()
            if not task:
                continue
            status("working")
            if count == 0:
                reply = REPLIES[role]
            else:
                # Show the terminal path for a simple follow-up without interpreting input.
                prompt = " ".join(task.split())[:280]
                reply = "I received this in the preview:\n\n> " + prompt + "\n\nThis is an example reply from a local demo agent."
            count += 1
            print(reply, flush=True)
            subprocess.run([bridge, "capture-reply"], input=reply, text=True, timeout=10, check=True)
            status("done")
        except InterruptedError:
            status("done")
        except EOFError:
            return


if __name__ == "__main__":
    main(*sys.argv[1:])

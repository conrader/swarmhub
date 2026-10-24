# Tests/Isolation only (PYTHONPATH): the sandbox has one uid, so a fixture account's skill scripts see FAKE_UID as
# their uid. This only changes how bot-msg's `swarmctl route` finds its own registry entry; the bridge never sees it.
import os

if os.environ.get("FAKE_UID", "").isdigit():
    _uid = int(os.environ["FAKE_UID"])
    os.getuid = lambda: _uid

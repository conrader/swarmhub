"""Stand-in for swarmhub-messages 1.4.7 swarm_control, used with the verbatim
1.4.7 peer-runtime.py beside it. The 1.4.7 supervisor and worker install no
signal handlers. Their worker (subprocess.call) and its deliveries
(subprocess.run in swarm_delivery.deliver) share the supervisor's process
group, which swarm_store.spawn created with start_new_session=True. This stub
keeps one such delivery in flight; it publishes its PID and sleeps.
"""
import os
from pathlib import Path
import subprocess
import sys

DELIVERY = ("import os, sys, time\n"
            "from pathlib import Path\n"
            "Path(sys.argv[1]).write_text(str(os.getpid()))\n"
            "time.sleep(60)\n")


def tick():
    pass


def retry_deliveries():
    record = Path.home() / ".hermes/swarmhub/legacy-delivery.pid"
    subprocess.run([sys.executable, "-c", DELIVERY, str(record)], stdin=subprocess.DEVNULL,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3700)


def deliver(*args, **kwargs):
    raise AssertionError("fixture has no completion records")


def spawn(command):
    raise AssertionError("tests launch the legacy supervisor directly")


def register(profile):
    raise AssertionError("not used by the fixture")

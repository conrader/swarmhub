"""SwarmHub local control: the facade the shipped entrypoints and tests import.

Layers (each under 500 lines, no cycles):
  swarm_store    state folder, SQLite schema, process helpers, gateway identity
  swarm_policy   policy, registration, action admission, decisions, stop/replace
  swarm_delivery durable deliveries, receiver receipts bound by delivery id
  swarm_jobs     one-job-per-bot scheduler, managed command execution
  swarm_webhook  managed webhook routines: keyed URL → durable self-delivery (key file only)
  swarm_webhook_receiver  the supervised loopback receiver (systemd user unit / LaunchAgent)
  swarm_intake   secure secret intake into 0600 files; only paths are returned
  swarm_alerts*  off-app alerts (ntfy / email) while the Mac app is away; its service and sealed settings
"""
import swarm_alerts_service as alerts_service  # noqa: F401
import swarm_intake as intake  # noqa: F401
import swarm_webhook as webhook  # noqa: F401
import swarm_webhook_receiver as receiver  # noqa: F401
from swarm_store import (NAME, canonical, database, invoking_profile, process_alive, process_start,  # noqa: F401
                         profile_exists, spawn, spawn_recorded, state, terminate)
from swarm_policy import (SIDE_EFFECT_KINDS, acknowledge_policy, acknowledge_turn_policy, action, active,  # noqa: F401
                          bind_policy, coding_model, coding_plan, decide, operation_fingerprint, policy,
                          provisioner_argv, publish, register, replace, reporting_targets, stop, submit,
                          subscription, validate_spec)
from swarm_delivery import (TAG, TAG_PATTERN, TEXT_LIMIT, deliver, delivery_ids, enqueue, receipt_ack,  # noqa: F401
                            receipt_bind, receipt_claim, retry_deliveries, tagged)
from swarm_jobs import check_job, run_action, tick  # noqa: F401


def resume_services():
    """Gateway start: the box services that run without a systemd user manager come back (each never raises)."""
    receiver.resume()
    alerts_service.resume()


def plugin_loader(script, home):
    """The swarmhub-peer plugin's __init__.py, in <home>/plugins/swarmhub-peer/, loading peer-runtime.py at `script`.

    A skill inside `home` is named relative to the plugin, so the profile can move to another account or back
    (ops/hb-move, which writes the same text from ops/hb_render.plugin_loader); one outside it stays absolute.
    """
    try:
        script = script.relative_to(home)
    except ValueError:
        pass
    return ("import os, runpy, sys\n"
            "script = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "
            f"{str(script)!r})\n"
            "sys.path.insert(0, os.path.dirname(script))\n"
            "register = runpy.run_path(script)[\"register\"]\n")

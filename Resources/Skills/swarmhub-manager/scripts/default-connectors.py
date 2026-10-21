#!/usr/bin/env python3
"""Swarm Hub's new-bot defaults, explicit per-bot opt-in, and read-only audit/diagnostics.

Optional ~/.config/swarmhub/default-connectors.json adds references, never credentials:
{"connectors": [{"name": "docs", "source": "~/.hermes/config.yaml",
                 "server": "docs", "tools": ["search", "read_page"]}]}
Sources may be Hermes YAML or MCPorter JSON. Only explicit tool names are accepted.
SB always uses the existing forced-command wiki SSH identity, never the messaging MCP.

The code lives in the connectors_*.py files beside this entry point. connectors_core.py alone is self-contained.
"""
import sys
from pathlib import Path

sys.dont_write_bytecode = True  # Installed skill folders stay exactly as shipped.
_here = str(Path(__file__).resolve().parent)
if _here not in sys.path:
    sys.path.insert(0, _here)

# The helper's names, as before the split (callers and tests use them through this module).
from connectors_core import *  # noqa: E402,F401,F403
from connectors_files import *  # noqa: E402,F401,F403
from connectors_model_auth import *  # noqa: E402,F401,F403
from connectors_provision import *  # noqa: E402,F401,F403


if __name__ == "__main__":
    sys.exit(main())  # noqa: F405

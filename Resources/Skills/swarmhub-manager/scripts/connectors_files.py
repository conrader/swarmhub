"""Private file writes and dotenv values for default-connectors.py."""
import copy
import json
import os
import re
import tempfile


def atomic_write(path, text):
    # Credentials in unrelated existing config fields must remain private too.
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".swarmhub-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def environment_values(paths):
    """Read dotenv values for explicit connector references, without copying a whole credentials file."""
    values = dict(os.environ)
    for path in paths:
        if not path.is_file():
            continue
        for line in path.read_text().splitlines():
            match = re.fullmatch(r"\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*", line)
            if not match:
                continue
            value = match[2]
            if value[:1] in ("'", '"'):
                if len(value) < 2 or value[-1] != value[0]:
                    raise ValueError("Unsupported dotenv quoting")
                if value.startswith('"'):
                    try:
                        value = json.loads(value)
                    except json.JSONDecodeError:
                        value = value[1:-1]
                else:
                    value = value[1:-1].replace("\\'", "'").replace("\\\\", "\\")
            else:
                value = re.split(r"\s+#", value, maxsplit=1)[0]
            values[match[1]] = value
    return values


def connector_copy(entry, values):
    """Materialize only variables named by the selected connector. Never expand shell commands."""
    variable = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}|\$env:([A-Za-z_][A-Za-z0-9_]*)|\$([A-Za-z_][A-Za-z0-9_]*)")

    def expand(value):
        if isinstance(value, dict):
            return {key: expand(item) for key, item in value.items()}
        if isinstance(value, list):
            return [expand(item) for item in value]
        if isinstance(value, str):
            def replace(match):
                name = match[1] or match[3] or match[4]
                if match[2] is not None and not values.get(name):
                    return match[2]
                if name not in values:
                    raise ValueError("Selected connector references an unavailable variable")
                return values[name]
            return variable.sub(replace, value)
        return value
    return expand(copy.deepcopy(entry))

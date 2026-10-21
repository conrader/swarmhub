"""Private file writes and dotenv values for default-connectors.py."""
import codecs
import copy
import os
import re
import tempfile

# python-dotenv's quoted escapes, decoded in one pass: Hermes loads .env files with it at runtime.
DOTENV_ESCAPES = {'"': re.compile(r"\\[\\'\"abfnrtv]"), "'": re.compile(r"\\[\\']")}
DOTENV_QUOTES = {quote: re.compile(quote + r"((?:\\" + quote + "|[^" + quote + "])*)" + quote)
                 for quote in ("'", '"')}
DOTENV_SPACE = re.compile(r"[^\S\r\n]*")
DOTENV_END = re.compile(r"[^\S\r\n]*(?:#[^\r\n]*)?(?:\r\n|\n|\r|$)")


def dotenv_assignments(text):
    """Parse complete dotenv bindings, including quoted newlines and trailing comments.

    Match python-dotenv's syntax/escape decoding without a runtime dependency.
    Unlike its warning-and-skip policy, malformed bindings abort the entire read.
    Bare keys have no value and leave the inherited environment alone.
    """
    position = 0
    while position < len(text):
        position = re.compile(r"\s*").match(text, position).end()
        if position == len(text):
            break
        export = re.compile(r"export[^\S\r\n]+").match(text, position)
        if export:
            position = export.end()
        key, value = None, None
        if text[position:position + 1] != "#":
            pattern = r"'([^']+)'" if text[position:position + 1] == "'" else r"([^=#\s]+)"
            match = re.compile(pattern).match(text, position)
            if not match:
                raise ValueError("Malformed dotenv binding")
            key, position = match[1], DOTENV_SPACE.match(text, match.end()).end()
            if text[position:position + 1] == "=":
                position = DOTENV_SPACE.match(text, position + 1).end()
                quote = text[position:position + 1]
                if quote in DOTENV_QUOTES:
                    match = DOTENV_QUOTES[quote].match(text, position)
                    if not match:
                        raise ValueError("Malformed dotenv binding")
                    value = DOTENV_ESCAPES[quote].sub(
                        lambda escape: codecs.decode(escape[0], "unicode-escape"), match[1])
                else:
                    match = re.compile(r"[^\r\n]*").match(text, position)
                    value = re.sub(r"\s+#.*", "", match[0]).rstrip()
                position = match.end()
        end = DOTENV_END.match(text, position)
        if not end:
            # Never include the key, value, source text or file path in diagnostics.
            raise ValueError("Malformed dotenv binding")
        position = end.end()
        if key is not None and value is not None:
            yield key, value


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
        values.update(dotenv_assignments(path.read_text()))
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

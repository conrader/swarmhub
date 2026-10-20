"""Reference decoder for Swarm Hub view documents (`swarmhub/ui/1`, docs/update-service/SCHEMAS.md §13).

The Swift decoder (`Packages/SwarmHubCore/Sources/SwarmHubCore/SDUI/`) must give the same verdict for every input:
`render`, or `fallback` / `update_required` with the first failing reason, checked in the order written here.
Stdlib only. Nothing here renders anything.
"""

import re

import jcs

SCHEMA = "swarmhub/ui/1"
LIMITS = {"max_document_bytes": 65536, "max_depth": 12, "max_nodes": 256, "max_children": 64,
          "max_string_bytes": 4096}
MAX_URL_BYTES = 2048
MAX_TOTAL = 1_000_000
MAX_LINES = 2000
MAX_FILE_TYPES = 16

NAME = r"[a-z][a-z0-9_]{0,63}"
BINDING = r"[a-z][a-z0-9_]{0,31}(\.[a-z][a-z0-9_]{0,31}){0,5}"
OPTION = r"[A-Za-z0-9._-]{1,64}"
FILE_TYPE = r"[a-z0-9]+(\.[a-z0-9-]+)+"
URL = r"https://[a-z0-9-]+(\.[a-z0-9-]+)+(/[A-Za-z0-9._~%/-]*)?(\?[A-Za-z0-9._~%&=-]*)?"

COMPONENTS = {"text", "badge", "key_value", "list", "card", "form", "button", "flow", "progress", "diff_preview"}
COMMON = {"type", "id", "visible_if"}
# type -> (required members, optional members), besides COMMON.
PROPS = {
    "text": ({"text"}, {"style", "role"}),
    "badge": ({"text"}, {"tone"}),
    "key_value": ({"items"}, set()),
    "list": ({"children"}, {"style"}),
    "card": ({"children"}, {"title", "subtitle"}),
    "form": ({"id", "fields", "submit"}, {"title"}),
    "button": ({"label", "action"}, {"style"}),
    "flow": ({"id", "steps"}, set()),
    "progress": (set(), {"total", "value", "label"}),
    "diff_preview": ({"text"}, {"title", "max_lines"}),
}
TEXT_STYLES = {"plain", "markdown"}
TEXT_ROLES = {"body", "title", "headline", "caption", "footnote", "monospace"}
BADGE_TONES = {"neutral", "info", "success", "warning", "danger"}
LIST_STYLES = {"plain", "bulleted", "numbered"}
BUTTON_STYLES = {"primary", "secondary", "destructive"}

FIELD_KINDS = {"text", "multiline", "choice", "toggle", "date", "schedule", "file_pick"}
FIELD_MEMBERS = {"id", "kind", "label", "required", "placeholder", "options", "max_length", "types", "value",
                 "visible_if"}
# Kind-specific members, checked in this order.
FIELD_EXTRA = (("placeholder", {"text", "multiline"}), ("max_length", {"text", "multiline"}),
               ("options", {"choice"}), ("types", {"file_pick"}))

# command -> its one required argument (None: no argument). A closed enum of existing local app commands.
COMMANDS = {
    "dismiss": None, "refresh": None, "flow_next": None, "flow_back": None,
    "copy_text": "text", "open_url": "url", "navigate": "screen",
    "routine.open": "routine", "routine.run_now": "routine", "routine.pause": "routine", "routine.resume": "routine",
    "routine.create": None, "routine.save": "routine",
}
FORM_COMMANDS = {"routine.create", "routine.save"}
FLOW_COMMANDS = {"flow_next", "flow_back"}
SCREENS = {"routines", "chat", "boxes", "skills", "settings", "updates"}
BIND_ROOTS = {"app", "box", "form", "profile", "record", "result", "routine"}

# Names that point at approval or secret surfaces (view, component type, command, screen, field kind): `denied_route`.
# Lowercased (ASCII) with `.`, `_` and `-` removed, the name contains one of these.
SURFACE_FRAGMENTS = ("operationreview", "secretentry", "approv", "secret", "keychain", "credential", "enroll",
                     "password", "passphrase", "token", "apikey", "privatekey", "signingkey", "hmac", "nonce")
# Binding segments and form field ids: `denied_binding` when, with `_` removed, a segment contains a fragment,
# or one of its `_`-separated words is a denied word.
BINDING_FRAGMENTS = ("approv", "secret", "token", "password", "passphrase", "credential", "keychain", "apikey",
                     "privatekey", "signingkey", "hmac", "nonce", "signature", "authent", "authoriz", "cookie",
                     "session")
BINDING_WORDS = {"auth", "key", "keys", "pin", "pins", "device", "devices", "gate", "gates", "otp"}

REASONS = ("killed", "too_large", "invalid_json", "schema_invalid", "unsupported_schema", "view_mismatch",
           "too_deep", "too_many_nodes", "too_many_children", "unknown_component", "denied_route", "unknown_action",
           "action_context", "url_not_allowed", "invalid_predicate", "invalid_binding", "denied_binding",
           "invalid_text", "string_too_long", "markup_not_allowed")


class Refusal(Exception):
    def __init__(self, reason):
        super().__init__(reason)
        self.reason = reason


def _require(condition, reason="schema_invalid"):
    if not condition:
        raise Refusal(reason)


def _full(pattern, text):
    return re.fullmatch(pattern, text) is not None


def _is_int(value):
    return type(value) is int


def _ascii_lower(text):
    return "".join(chr(ord(c) + 32) if "A" <= c <= "Z" else c for c in text)


def denied_surface(name):
    compact = _ascii_lower(name).replace(".", "").replace("_", "").replace("-", "")
    return any(fragment in compact for fragment in SURFACE_FRAGMENTS)


def denied_segment(segment):
    compact = segment.replace("_", "")
    return any(f in compact for f in BINDING_FRAGMENTS) or any(w in BINDING_WORDS for w in segment.split("_"))


def decode(data, view, limits=None, url_hosts=(), killed=()):
    """The verdict for one document: {"verdict": "render"} or {"verdict": fallback|update_required, "reason"}."""
    limits = dict(LIMITS, **(limits or {}))
    killed = set(killed)
    if view in killed:
        return {"verdict": "fallback", "reason": "killed"}
    if len(data) > limits["max_document_bytes"]:
        return {"verdict": "fallback", "reason": "too_large"}
    try:
        document = jcs.loads(data)
    except jcs.JCSError:
        return {"verdict": "fallback", "reason": "invalid_json"}
    # Read only from a parsed object; an unparseable document cannot ask for "update required".
    critical = isinstance(document, dict) and document.get("critical") is True
    state = _State(limits, set(url_hosts))
    try:
        _document(document, view, state)
    except Refusal as refusal:
        return {"verdict": "update_required" if critical else "fallback", "reason": refusal.reason}
    if any(name in killed for name in state.types):
        return {"verdict": "fallback", "reason": "killed"}
    return {"verdict": "render"}


class _State:
    def __init__(self, limits, url_hosts):
        self.limits = limits
        self.url_hosts = url_hosts
        self.nodes = 0
        self.types = set()


def _document(document, view, s):
    _require(isinstance(document, dict))
    _require(isinstance(document.get("schema"), str))
    _require(document["schema"] == SCHEMA, "unsupported_schema")
    keys = set(document)
    _require(keys <= {"schema", "view", "critical", "root"} and {"view", "root"} <= keys)
    _require("critical" not in document or isinstance(document["critical"], bool))
    name = document["view"]
    _require(isinstance(name, str) and _full(NAME, name))
    _require(not denied_surface(name), "denied_route")
    _require(name == view, "view_mismatch")
    _node(document["root"], 1, False, s)


def _node(value, depth, in_flow, s):
    _require(isinstance(value, dict))
    _require(depth <= s.limits["max_depth"], "too_deep")
    s.nodes += 1
    _require(s.nodes <= s.limits["max_nodes"], "too_many_nodes")
    kind = value.get("type")
    _require(isinstance(kind, str))
    _require(not denied_surface(kind), "denied_route")
    _require(kind in COMPONENTS, "unknown_component")
    required, optional = PROPS[kind]
    keys = set(value)
    _require(keys <= COMMON | required | optional and required <= keys)
    s.types.add(kind)
    if "id" in value:
        _require(isinstance(value["id"], str) and _full(NAME, value["id"]))
    if "visible_if" in value:
        _predicate(value["visible_if"], s)
    get = value.get
    if kind == "text":
        literal = _text(value["text"], s)
        _choice(get("style"), TEXT_STYLES)
        _choice(get("role"), TEXT_ROLES)
        if get("style") == "markdown" and literal is not None:
            _markup(literal)
    elif kind == "badge":
        _text(value["text"], s)
        _choice(get("tone"), BADGE_TONES)
    elif kind == "key_value":
        for item in _items(value["items"], True, s):
            _require(isinstance(item, dict) and set(item) == {"key", "value"})
            _text(item["key"], s)
            _text(item["value"], s)
    elif kind == "list":
        _children(value["children"], depth, True, in_flow, s)
        _choice(get("style"), LIST_STYLES)
    elif kind == "card":
        _optional_text(get("title"), s)
        _optional_text(get("subtitle"), s)
        _children(value["children"], depth, False, in_flow, s)
    elif kind == "form":
        _optional_text(get("title"), s)
        seen = set()
        for field in _items(value["fields"], True, s):
            _field(field, seen, s)
        submit = value["submit"]
        _require(isinstance(submit, dict) and set(submit) == {"label", "action"})
        _text(submit["label"], s)
        _action(submit["action"], True, in_flow, s)
    elif kind == "button":
        _text(value["label"], s)
        _action(value["action"], False, in_flow, s)
        _choice(get("style"), BUTTON_STYLES)
    elif kind == "flow":
        _require(not in_flow)
        seen = set()
        for step in _items(value["steps"], True, s):
            _require(isinstance(step, dict) and set(step) == {"id", "title", "children"})
            _require(isinstance(step["id"], str) and _full(NAME, step["id"]) and step["id"] not in seen)
            seen.add(step["id"])
            _text(step["title"], s)
            _children(step["children"], depth, False, True, s)
    elif kind == "progress":
        total = get("total", 100)
        _require(_is_int(total) and 1 <= total <= MAX_TOTAL)
        if "value" in value:
            amount = value["value"]
            if isinstance(amount, dict):
                _binding_object(amount, s)
            else:
                _require(_is_int(amount) and 0 <= amount <= total)
        _optional_text(get("label"), s)
    elif kind == "diff_preview":
        _text(value["text"], s)
        _optional_text(get("title"), s)
        if "max_lines" in value:
            _require(_is_int(value["max_lines"]) and 1 <= value["max_lines"] <= MAX_LINES)


def _items(value, nonempty, s):
    _require(isinstance(value, list) and (value or not nonempty))
    _require(len(value) <= s.limits["max_children"], "too_many_children")
    return value


def _children(value, depth, nonempty, in_flow, s):
    for child in _items(value, nonempty, s):
        _node(child, depth + 1, in_flow, s)


def _choice(value, allowed):
    _require(value is None or (isinstance(value, str) and value in allowed))


def _field(field, seen, s):
    _require(isinstance(field, dict))
    keys = set(field)
    _require(keys <= FIELD_MEMBERS and {"id", "kind", "label"} <= keys)
    ident = field["id"]
    _require(isinstance(ident, str) and _full(NAME, ident))
    _require(not denied_segment(ident), "denied_binding")
    _require(ident not in seen)
    seen.add(ident)
    kind = field["kind"]
    _require(isinstance(kind, str))
    _require(not denied_surface(kind), "denied_route")
    _require(kind in FIELD_KINDS, "unknown_component")
    for member, kinds in FIELD_EXTRA:
        _require(member not in field or kind in kinds)
    _require(kind != "choice" or "options" in field)
    _text(field["label"], s)
    _require("required" not in field or isinstance(field["required"], bool))
    if "placeholder" in field:
        _require(isinstance(field["placeholder"], str))
        _literal(field["placeholder"], s)
    if "options" in field:
        values = set()
        for option in _items(field["options"], True, s):
            _require(isinstance(option, dict) and set(option) == {"value", "label"})
            _require(isinstance(option["value"], str) and _full(OPTION, option["value"]))
            _require(option["value"] not in values)
            values.add(option["value"])
            _text(option["label"], s)
    if "max_length" in field:
        _require(_is_int(field["max_length"]) and 1 <= field["max_length"] <= s.limits["max_string_bytes"])
    if "types" in field:
        types = field["types"]
        _require(isinstance(types, list) and 1 <= len(types) <= MAX_FILE_TYPES)
        _require(all(isinstance(t, str) and _full(FILE_TYPE, t) for t in types) and len(set(types)) == len(types))
    if "value" in field:
        _binding_object(field["value"], s)
    if "visible_if" in field:
        _predicate(field["visible_if"], s)


def _action(value, submit, in_flow, s):
    _require(isinstance(value, dict))
    command = value.get("command")
    _require(isinstance(command, str))
    _require(not denied_surface(command), "denied_route")
    _require(command in COMMANDS, "unknown_action")
    argument = COMMANDS[command]
    allowed = {"command", "confirm"} | ({argument} if argument else set())
    _require(set(value) <= allowed and (argument is None or argument in value))
    _require("confirm" not in value or isinstance(value["confirm"], bool))
    _require((command in FORM_COMMANDS) == submit, "action_context")
    _require(command not in FLOW_COMMANDS or in_flow, "action_context")
    if argument == "text":
        _text(value["text"], s)
    elif argument == "url":
        url = value["url"]
        _require(isinstance(url, str))
        _require(len(url.encode("utf-8")) <= MAX_URL_BYTES and _full(URL, url), "url_not_allowed")
        host = url[len("https://"):].split("/")[0].split("?")[0]
        _require(host in s.url_hosts, "url_not_allowed")
    elif argument == "screen":
        screen = value["screen"]
        _require(isinstance(screen, str))
        _require(not denied_surface(screen), "denied_route")
        _require(screen in SCREENS, "unknown_action")
    elif argument == "routine":
        _binding_object(value["routine"], s)


def _predicate(value, s):
    _require(isinstance(value, dict) and len(value) == 1, "invalid_predicate")
    (op, operand), = value.items()
    _require(op in ("exists", "missing", "equals"), "invalid_predicate")
    _require(isinstance(operand, dict), "invalid_predicate")
    if op == "equals":
        _require(set(operand) == {"bind", "value"}, "invalid_predicate")
    else:
        _require(set(operand) == {"bind"}, "invalid_predicate")
    _require(isinstance(operand["bind"], str), "invalid_predicate")
    _binding(operand["bind"])
    if op == "equals":
        literal = operand["value"]
        _require(isinstance(literal, (bool, int, str)), "invalid_predicate")
        if isinstance(literal, str):
            _literal(literal, s)


def _text(value, s):
    """A literal string or {"bind": path}. Returns the literal, or None for a binding."""
    if isinstance(value, str):
        _literal(value, s)
        return value
    _binding_object(value, s)
    return None


def _optional_text(value, s):
    if value is not None:
        _text(value, s)


def _binding_object(value, s):
    _require(isinstance(value, dict) and set(value) == {"bind"} and isinstance(value["bind"], str))
    _binding(value["bind"])


def _binding(path):
    _require(_full(BINDING, path), "invalid_binding")
    segments = path.split(".")
    _require(segments[0] in BIND_ROOTS, "invalid_binding")
    _require(not any(denied_segment(segment) for segment in segments), "denied_binding")


def _literal(text, s):
    _require(len(text.encode("utf-8")) <= s.limits["max_string_bytes"], "string_too_long")
    _require(not any((ord(c) < 32 and c not in "\t\n") or ord(c) == 127 for c in text), "invalid_text")


def _markup(text):
    # Markdown subset only: no links, images or HTML tags (strings are text, never markup; URLs go through open_url).
    _require("](" not in text and "![" not in text and re.search(r"<[A-Za-z/!?]", text) is None,
             "markup_not_allowed")

"""Python statement of the P7b render tree text (SDUIRenderer + SDUIRenderText.describe in SwarmHubCore).

A document the reference decoder (ui_reference.py) accepts is resolved against local data and written as the same
deterministic text the Swift renderers produce: bindings read, visible_if applied, defaults filled in, actions bound
to their arguments. Used for the shared render goldens under Tests/Fixtures/release-bundles/ui-render/.
"""

import ui_reference as ref

DEFAULT_TOTAL = 100
DEFAULT_MAX_LINES = ref.MAX_LINES


def _is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def data_text(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if _is_int(value):
        return str(value)
    return value


class Data:
    def __init__(self, values):
        self.values = {k: v for k, v in values.items()
                       if not any(ref.denied_segment(part) for part in k.split("."))}

    def bound(self, path):
        return self.values.get(path)

    def text(self, text):
        if isinstance(text, str):
            return text
        value = self.bound(text["bind"])
        return "" if value is None else data_text(value)

    def optional_text(self, text):
        return None if text is None else self.text(text)

    def present(self, path):
        value = self.bound(path)
        return value is not None and not (isinstance(value, str) and value == "")

    def holds(self, predicate):
        if predicate is None:
            return True
        op, operand = next(iter(predicate.items()))
        if op == "exists":
            return self.present(operand["bind"])
        if op == "missing":
            return not self.present(operand["bind"])
        value, expected = self.bound(operand["bind"]), operand["value"]
        if isinstance(expected, bool):
            return isinstance(value, bool) and value == expected
        if _is_int(expected):
            return _is_int(value) and value == expected
        return isinstance(value, str) and value == expected

    def with_form(self, fields):
        merged = {k: v for k, v in self.values.items() if not k.startswith("form.")}
        for field_id, value in fields.items():
            merged["form." + field_id] = value
        return Data(merged)


def initial_values(fields, data):
    """Field id -> str (bool for toggles), as SDUIRenderer.initialValues."""
    values = {}
    for field in fields:
        bound = data.bound(field["value"]["bind"]) if "value" in field else None
        kind = field["kind"]
        if kind == "toggle":
            values[field["id"]] = bound if isinstance(bound, bool) else False
        elif kind == "choice":
            text = "" if bound is None else data_text(bound)
            values[field["id"]] = text if any(o["value"] == text for o in field["options"]) else ""
        elif kind == "file_pick":
            values[field["id"]] = ""
        else:
            values[field["id"]] = "" if bound is None else data_text(bound)
    return values


def quote(text):
    out = ['"']
    for ch in text:
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\t":
            out.append("\\t")
        elif ch == "\r":
            out.append("\\r")
        elif ord(ch) < 0x20:
            out.append("\\u%04x" % ord(ch))
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def _action(action, data):
    command = action["command"]
    name = ref.COMMANDS[command]
    text = "-> " + command
    if name is not None:
        raw = action[name]
        if name == "text":
            value = data.text(raw)
        elif name == "routine":
            bound = data.bound(raw["bind"])
            value = "" if bound is None else data_text(bound)
        else:
            value = raw
        text += f" {name}={quote(value)}"
    if command == "open_url" or action.get("confirm") is True:
        text += " confirm"
    return text


def _title(prefix, data, node, *names):
    text = prefix
    for name in names:
        if name in node:
            text += f" {name}={quote(data.text(node[name]))}"
    return text


def _node(node, depth, data, lines):
    if not data.holds(node.get("visible_if")):
        return
    pad = "  " * depth
    kind = node["type"]
    head = kind + (f" id={node['id']}" if "id" in node else "")

    def line(text, level=0):
        lines.append(pad + "  " * level + text)

    def children(nodes, level=1):
        for child in nodes:
            _node(child, depth + level, data, lines)

    if kind == "text":
        line(f"{head} style={node.get('style', 'plain')} role={node.get('role', 'body')} {quote(data.text(node['text']))}")
    elif kind == "badge":
        line(f"{head} tone={node.get('tone', 'neutral')} {quote(data.text(node['text']))}")
    elif kind == "key_value":
        line(head)
        for item in node["items"]:
            line(f"{quote(data.text(item['key']))} = {quote(data.text(item['value']))}", 1)
    elif kind == "list":
        line(f"{head} style={node.get('style', 'plain')}")
        children(node["children"])
    elif kind == "card":
        line(_title(head, data, node, "title", "subtitle"))
        children(node["children"])
    elif kind == "form":
        line(_title(head, data, node, "title"))
        initial = initial_values(node["fields"], data)
        scoped = data.with_form(initial)
        for field in node["fields"]:
            if not scoped.holds(field.get("visible_if")):
                continue
            text = f"field {field['kind']} id={field['id']} label={quote(scoped.text(field['label']))}"
            if field.get("required", False):
                text += " required"
            if "placeholder" in field:
                text += " placeholder=" + quote(field["placeholder"])
            if "max_length" in field:
                text += f" max_length={field['max_length']}"
            if field.get("types"):
                text += " types=" + ",".join(field["types"])
            text += " value=" + quote(data_text(initial[field["id"]]))
            line(text, 1)
            for option in field.get("options", []):
                line(f"option {option['value']} {quote(scoped.text(option['label']))}", 2)
        submit = node["submit"]
        line(f"submit {quote(scoped.text(submit['label']))} {_action(submit['action'], scoped)}", 1)
    elif kind == "button":
        line(f"{head} style={node.get('style', 'secondary')} {quote(data.text(node['label']))} "
             f"{_action(node['action'], data)}")
    elif kind == "flow":
        line(head)
        for step in node["steps"]:
            line(f"step id={step['id']} title={quote(data.text(step['title']))}", 1)
            children(step["children"], 2)
    elif kind == "progress":
        total = node.get("total", DEFAULT_TOTAL)
        value = node.get("value")
        if isinstance(value, dict):
            bound = data.bound(value["bind"])
            value = min(max(bound, 0), total) if _is_int(bound) else None
        text = f"{head} total={total} value={'none' if value is None else value}"
        if "label" in node:
            text += " label=" + quote(data.text(node["label"]))
        line(text)
    elif kind == "diff_preview":
        all_lines = data.text(node["text"]).split("\n")
        shown = all_lines[:node.get("max_lines", DEFAULT_MAX_LINES)]
        line(_title(head, data, node, "title") + f" lines={len(shown)}/{len(all_lines)}")
        for text in shown:
            line(quote(text), 1)
    else:
        raise ValueError(f"not a catalogue v1 component: {kind}")


def describe(document, values):
    """The render tree text of a decoded document (a parsed dict the reference accepted) against `values`."""
    lines = []
    root = document["root"]
    data = Data(values)
    if data.holds(root.get("visible_if")):
        _node(root, 0, data, lines)
    else:
        lines.append("(hidden)")
    return "\n".join(lines) + "\n"

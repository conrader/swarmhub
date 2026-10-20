"""Python statement of what every button and form submit in a rendered document does (P7c).

The Mac (P7b) and iOS (P7c) renderers share SDUIActionRouter and SDUIInteraction in SwarmHubCore; this file states
their outcomes for the shared golden documents so the action goldens (ui-render/actions/) can be regenerated and
checked on Linux, and SDUIActionGoldenTests asserts the same bytes in Swift (macOS and the iOS simulator). One line per
button or submit, in render-tree order (every flow step included):

    <key> button "<label>" available=yes|no press: <step>
    <key> submit form=<id> "<label>" available=yes|no initial: <step>
    <key> submit form=<id> "<label>" blank: <step>

`available` is SDUIInteraction.isAvailable with a sink that offers every command (so only refusals and flow moves
outside a flow are unavailable). `blank` submits with every visible non-toggle field emptied. A step is
`move_flow +1|-1`, `perform <command>`, `refused <reason>`, or
`confirm title=".." button=".." message=".." accept: <step> decline: <step>`.

Text rules follow the goldens (ASCII data): Swift trims `.whitespacesAndNewlines` and counts Characters; this file
uses str.strip() and len(), which agree for that data.
"""

import re

import ui_reference as ref
from ui_render import Data, data_text, initial_values, quote

MAX_NAME = 200
MAX_PROMPT = 5000


def _resolve(action, data):
    """(command, argument or None, requires confirmation), as SDUIRenderer.resolve."""
    command = action["command"]
    name = ref.COMMANDS[command]
    argument = None
    if name == "text":
        argument = data.text(action["text"])
    elif name == "routine":
        bound = data.bound(action["routine"]["bind"])
        argument = "" if bound is None else data_text(bound)
    elif name is not None:
        argument = action[name]
    return command, argument, command == "open_url" or action.get("confirm") is True


def _allowed_url(text, url_hosts):
    if text is None or len(text.encode("utf-8")) > ref.MAX_URL_BYTES or not re.fullmatch(ref.URL, text):
        return None
    host = re.match(r"[^/?]*", text[len("https://"):]).group(0)
    return text if host in url_hosts else None


def _confirmed(effect, requires, label):
    if not requires:
        return effect
    return ("confirm", label + "?", label, "", effect)


def route(resolved, label, url_hosts):
    command, argument, requires = resolved
    if command == "flow_next":
        return _confirmed(("move", 1), requires, label)
    if command == "flow_back":
        return _confirmed(("move", -1), requires, label)
    if command in ("routine.create", "routine.save"):
        return ("refused", "submit_outside_form")
    if command in ("dismiss", "refresh"):
        effect = (command,)
    elif command == "copy_text":
        effect = (command, argument or "")
    elif command == "open_url":
        url = _allowed_url(argument, url_hosts)
        if url is None:
            return ("refused", "url_not_allowed")
        return ("confirm", "Open this link?", "Open", url, ("perform", ("open_url", url)))
    elif command == "navigate":
        if argument not in ref.SCREENS:
            return ("refused", "unknown_screen")
        effect = (command, argument)
    else:
        if not argument:
            return ("refused", "routine_unavailable")
        effect = (command, argument)
    return _confirmed(("perform", effect), requires, label)


def field_problems(form, values):
    problems = {}
    for field in form["fields"]:
        value = values.get(field["id"], form["initial"].get(field["id"], ""))
        if isinstance(value, bool):
            continue
        if field.get("required", False) and value.strip() == "":
            problems[field["id"]] = "required"
        elif "max_length" in field and len(value) > field["max_length"]:
            problems[field["id"]] = "too_long"
    return problems


def _draft(values):
    def text(field_id):
        value = values.get(field_id)
        return None if value is None else data_text(value)
    name, schedule, prompt = (text("name") or "").strip(), (text("schedule") or "").strip(), text("prompt")
    if not name or len(name) > MAX_NAME or not schedule or len(prompt or "") > MAX_PROMPT:
        return None
    return (name, schedule, prompt)


def submit(form, values):
    merged = dict(form["initial"])
    merged.update(values)
    problems = field_problems(form, merged)
    for field in form["fields"]:
        if field["id"] in problems:
            return ("refused", problems[field["id"]])
    draft = _draft(merged)
    if draft is None:
        return ("refused", "invalid_form")
    command, argument, requires = form["submit"]
    if command == "routine.create":
        return _confirmed(("perform", ("routine.create", draft)), requires, form["label"])
    if command == "routine.save":
        if not argument:
            return ("refused", "routine_unavailable")
        return _confirmed(("perform", ("routine.save", argument, draft)), requires, form["label"])
    return ("refused", "not_a_submit")


def _command(effect):
    name = effect[0]
    if name in ("dismiss", "refresh"):
        return name
    if name == "navigate":
        return f"navigate {effect[1]}"
    if name in ("routine.create", "routine.save"):
        name_, schedule, prompt = effect[-1]
        draft = f"name={quote(name_)} schedule={quote(schedule)} prompt={'none' if prompt is None else quote(prompt)}"
        return f"routine.create {draft}" if name == "routine.create" else f"routine.save {quote(effect[1])} {draft}"
    return f"{name} {quote(effect[1])}"


def describe_step(step):
    kind = step[0]
    if kind == "move":
        return "move_flow " + ("+1" if step[1] > 0 else "-1")
    if kind == "perform":
        return "perform " + _command(step[1])
    if kind == "refused":
        return "refused " + step[1]
    _, title, button, message, effect = step
    return (f"confirm title={quote(title)} button={quote(button)} message={quote(message)} "
            f"accept: {describe_step(effect)} decline: refused confirmation_declined")


def _available(step, in_flow):
    if step[0] == "confirm":
        step = step[4]
    return step[0] == "perform" or (step[0] == "move" and in_flow)


def _walk(node, key, data, in_flow, url_hosts, lines):
    if not data.holds(node.get("visible_if")):
        return
    kind = node["type"]

    def children(nodes, prefix, flow):
        for index, child in enumerate(nodes):
            _walk(child, f"{prefix}.{index}", data, flow, url_hosts, lines)

    if kind in ("list", "card"):
        children(node["children"], key, in_flow)
    elif kind == "flow":
        for index, step in enumerate(node["steps"]):
            children(step["children"], f"{key}.{index}", True)
    elif kind == "button":
        label = data.text(node["label"])
        step = route(_resolve(node["action"], data), label, url_hosts)
        lines.append(f"{key} button {quote(label)} available={'yes' if _available(step, in_flow) else 'no'} "
                     f"press: {describe_step(step)}")
    elif kind == "form":
        initial = initial_values(node["fields"], data)
        scoped = data.with_form(initial)
        form = {"fields": [f for f in node["fields"] if scoped.holds(f.get("visible_if"))], "initial": initial,
                "label": scoped.text(node["submit"]["label"]), "submit": _resolve(node["submit"]["action"], scoped)}
        head = f"{key} submit form={node.get('id', '')} {quote(form['label'])}"
        lines.append(f"{head} available=yes initial: {describe_step(submit(form, {}))}")
        blank = {f["id"]: "" for f in form["fields"] if f["kind"] != "toggle"}
        lines.append(f"{head} blank: {describe_step(submit(form, blank))}")


def describe(document, values, url_hosts=()):
    """The action outcome text of a decoded document (a parsed dict the reference accepted) against `values`."""
    lines = []
    _walk(document["root"], "0", Data(values), False, frozenset(url_hosts), lines)
    return "\n".join(lines or ["(none)"]) + "\n"

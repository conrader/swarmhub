"""Golden view documents and expected verdicts for the SDUI catalogue v1 (SCHEMAS.md §13, CORE-PHASES.md P7a).

Used by make_ui_vectors.py. Every invalid document is a small, named change to a valid one, so each case fails for
exactly the reason it names. URLs use the reserved `.test` / `.example` names; nothing here is fetched.
"""

import copy

HOSTS = ["docs.swarmhub.test"]


def _b(path):
    return {"bind": path}


def _button(label, action, **extra):
    return dict({"type": "button", "label": label, "action": action}, **extra)


def _text(text, **extra):
    return dict({"type": "text", "text": text}, **extra)


ROUTINE_CARD = {
    "schema": "swarmhub/ui/1",
    "view": "routine_result_card",
    "root": {
        "type": "card", "title": _b("routine.name"), "subtitle": _b("result.finished_at"),
        "children": [
            {"type": "badge", "text": "Done", "tone": "success",
             "visible_if": {"equals": {"bind": "result.status", "value": "ok"}}},
            {"type": "badge", "text": "Needs attention", "tone": "warning",
             "visible_if": {"equals": {"bind": "result.status", "value": "error"}}},
            _text(_b("result.summary"), style="markdown", role="body"),
            {"type": "key_value", "items": [
                {"key": "Schedule", "value": _b("routine.schedule_text")},
                {"key": "Box", "value": _b("box.name")},
                {"key": "Duration", "value": _b("result.duration_text")}]},
            {"type": "progress", "total": 10, "value": _b("result.steps_done"), "label": "Steps",
             "visible_if": {"exists": _b("result.steps_done")}},
            {"type": "diff_preview", "title": "Changes", "text": _b("result.diff"), "max_lines": 40,
             "visible_if": {"exists": _b("result.diff")}},
            {"type": "list", "style": "plain", "children": [
                _button("Run now", {"command": "routine.run_now", "routine": _b("routine.id"), "confirm": True},
                        style="primary"),
                _button("Pause", {"command": "routine.pause", "routine": _b("routine.id")}, style="secondary",
                        visible_if={"missing": _b("routine.paused_at")}),
                _button("Copy summary", {"command": "copy_text", "text": _b("result.summary")}),
                _button("Routine help", {"command": "open_url",
                                         "url": "https://docs.swarmhub.test/routines?from=card"})]},
        ],
    },
}

ROUTINE_FORM = {
    "schema": "swarmhub/ui/1",
    "view": "routine_form",
    "root": {"type": "card", "title": "Edit routine", "children": [
        {"type": "form", "id": "routine_edit", "title": "Routine", "fields": [
            {"id": "name", "kind": "text", "label": "Name", "required": True, "placeholder": "Morning report",
             "max_length": 80, "value": _b("routine.name")},
            {"id": "prompt", "kind": "multiline", "label": "What should it do?", "value": _b("routine.prompt")},
            {"id": "box", "kind": "choice", "label": "Box", "options": [
                {"value": "local", "label": "This Mac"}, {"value": "remote-1", "label": _b("box.name")}]},
            {"id": "enabled", "kind": "toggle", "label": "Enabled", "value": _b("routine.enabled")},
            {"id": "start", "kind": "date", "label": "Start", "visible_if": {"exists": _b("routine.start")}},
            {"id": "schedule", "kind": "schedule", "label": "Schedule", "value": _b("routine.schedule")},
            {"id": "attachment", "kind": "file_pick", "label": "Attachment",
             "types": ["public.plain-text", "public.image"]},
        ], "submit": {"label": "Save", "action": {"command": "routine.save", "routine": _b("routine.id")}}},
        _button("Cancel", {"command": "dismiss"}, style="secondary"),
    ]},
}

CONNECT_FLOW = {
    "schema": "swarmhub/ui/1",
    "view": "connect_box_flow",
    "root": {"type": "flow", "id": "connect_box", "steps": [
        {"id": "welcome", "title": "Connect a box", "children": [
            _text("Swarm Hub talks to each box directly.", role="headline"),
            _button("Next", {"command": "flow_next"}, style="primary")]},
        {"id": "connect", "title": "Add the box", "children": [
            _text("You need **SSH access** and the box address. Values like `a > b` stay plain text.",
                  style="markdown"),
            {"type": "list", "style": "numbered", "children": [
                _text("Open Boxes"), _text("Choose Add box"), _text("Paste the address")]},
            _button("Back", {"command": "flow_back"}),
            _button("Open Boxes", {"command": "navigate", "screen": "boxes"})]},
        {"id": "done", "title": "Done", "children": [
            {"type": "badge", "text": "Ready", "tone": "info"},
            _button("Close", {"command": "dismiss"})]},
    ]},
}

SETTINGS_CRITICAL = {
    "schema": "swarmhub/ui/1",
    "view": "settings_pane",
    "critical": True,
    "root": {"type": "card", "title": "Updates", "children": [
        _text(_b("app.update_status_text")),
        _button("Check now", {"command": "refresh"}),
        _button("Open updates", {"command": "navigate", "screen": "updates"})]},
}

HELP_NO_CONFIRM = {
    "schema": "swarmhub/ui/1",
    "view": "help_card",
    "root": {"type": "card", "children": [
        _button("Read the guide", {"command": "open_url", "url": "https://docs.swarmhub.test/guide", "confirm": False}),
    ]},
}


def nested_cards(levels, leaf):
    node = leaf
    for _ in range(levels - 1):
        node = {"type": "card", "children": [node]}
    return node


def simple(view, root, **extra):
    return dict({"schema": "swarmhub/ui/1", "view": view, "root": root}, **extra)


def changed(document, change):
    result = copy.deepcopy(document)
    change(result)
    return result


def card_children(document):
    return document["root"]["children"]


def _set(path, value):
    def change(document):
        target = document
        for step in path[:-1]:
            target = target[step]
        target[path[-1]] = value
    return change


def _delete(path):
    def change(document):
        target = document
        for step in path[:-1]:
            target = target[step]
        del target[path[-1]]
    return change


LIST = ["root", "children", 6, "children"]  # the button list of ROUTINE_CARD
RUN_ACTION = LIST + [0, "action"]
HELP_ACTION = LIST + [3, "action"]
FIELDS = ["root", "children", 0, "fields"]


def cases():
    """(id, description, document dict or raw bytes, view, expect, input overrides)."""
    return [
        ("routine-card", "valid routine result card: bindings, predicates, every display component, local actions",
         ROUTINE_CARD, "routine_result_card", "render", {}),
        ("routine-form", "valid routine form with all seven field kinds and a routine.save submit",
         ROUTINE_FORM, "routine_form", "render", {}),
        ("connect-flow", "valid three-step flow with flow_next/flow_back and navigate", CONNECT_FLOW,
         "connect_box_flow", "render", {}),
        ("critical-valid", "a valid critical document renders normally", SETTINGS_CRITICAL, "settings_pane",
         "render", {}),
        ("url-confirm-false", "open_url with confirm:false decodes; the URL still requires confirmation",
         HELP_NO_CONFIRM, "help_card", "render", {}),
        ("depth-at-limit", "nesting exactly max_depth (12) is accepted",
         simple("deep_card", nested_cards(12, _text("leaf"))), "deep_card", "render", {}),
        ("children-at-limit", "exactly max_children (64) children are accepted",
         simple("wide_card", {"type": "card", "children": [_text(str(i)) for i in range(64)]}), "wide_card",
         "render", {}),
        # Parse and limits.
        ("trailing-comma", "not JSON", b'{"schema":"swarmhub/ui/1","view":"x","root":{},}\n', "x", "fallback/invalid_json",
         {}),
        ("float", "floating-point number (profile §2)",
         b'{"schema":"swarmhub/ui/1","view":"p","root":{"type":"progress","total":1.5}}\n', "p",
         "fallback/invalid_json", {}),
        ("null", "null is not in the profile",
         b'{"schema":"swarmhub/ui/1","view":"p","root":{"type":"progress","label":null}}\n', "p",
         "fallback/invalid_json", {}),
        ("duplicate-member", "duplicate member names",
         b'{"schema":"swarmhub/ui/1","view":"p","view":"q","root":{"type":"progress"}}\n', "p",
         "fallback/invalid_json", {}),
        ("critical-unparseable", "critical cannot be read from a document that does not parse",
         b'{"schema":"swarmhub/ui/1","critical":true,"view":"p","root":{"type":"progress"}\n', "p",
         "fallback/invalid_json", {}),
        ("too-large", "document above max_document_bytes (lowered to 512 for this case)", ROUTINE_CARD,
         "routine_result_card", "fallback/too_large", {"limits": {"max_document_bytes": 512}}),
        ("too-deep", "nesting max_depth + 1", simple("deep_card", nested_cards(13, _text("leaf"))), "deep_card",
         "fallback/too_deep", {}),
        ("too-many-nodes", "more than max_nodes nodes",
         simple("big_card", {"type": "card", "children": [
             {"type": "list", "children": [_text("x") for _ in range(60)]} for _ in range(5)]}), "big_card",
         "fallback/too_many_nodes", {}),
        ("too-many-children", "max_children + 1 children",
         simple("wide_card", {"type": "card", "children": [_text(str(i)) for i in range(65)]}), "wide_card",
         "fallback/too_many_children", {}),
        # Schema.
        ("not-object", "a document must be an object", b'["swarmhub/ui/1"]\n', "x", "fallback/schema_invalid", {}),
        ("schema-v2", "a newer document schema", changed(ROUTINE_CARD, _set(["schema"], "swarmhub/ui/2")),
         "routine_result_card", "fallback/unsupported_schema", {}),
        ("schema-v2-critical", "a newer critical document asks for an app update",
         changed(SETTINGS_CRITICAL, _set(["schema"], "swarmhub/ui/2")), "settings_pane",
         "update_required/unsupported_schema", {}),
        ("missing-root", "root is required", changed(ROUTINE_CARD, _delete(["root"])), "routine_result_card",
         "fallback/schema_invalid", {}),
        ("unknown-top-member", "unknown members are refused (strict)",
         changed(ROUTINE_CARD, _set(["script"], "x")), "routine_result_card", "fallback/schema_invalid", {}),
        ("unknown-node-member", "unknown node members are refused (no onClick, no html)",
         changed(ROUTINE_CARD, _set(["root", "html"], "<b>x</b>")), "routine_result_card",
         "fallback/schema_invalid", {}),
        ("critical-not-bool", "critical must be a boolean", changed(SETTINGS_CRITICAL, _set(["critical"], 1)),
         "settings_pane", "fallback/schema_invalid", {}),
        ("bad-enum", "closed style enums",
         changed(ROUTINE_CARD, _set(["root", "children", 0, "tone"], "red")), "routine_result_card",
         "fallback/schema_invalid", {}),
        ("progress-over-total", "a fixed progress value above total",
         simple("p", {"type": "progress", "total": 10, "value": 11}), "p", "fallback/schema_invalid", {}),
        ("view-mismatch", "the document is for another view", ROUTINE_CARD, "routine_form",
         "fallback/view_mismatch", {}),
        # Catalogue.
        ("unknown-component", "a component this catalogue does not have",
         changed(ROUTINE_CARD, _set(["root", "children", 2], {"type": "webview", "src": "https://evil.example/"})),
         "routine_result_card", "fallback/unknown_component", {}),
        ("unknown-component-critical", "an unknown component in a critical document asks for an app update",
         changed(SETTINGS_CRITICAL, _set(["root", "children", 0], {"type": "chart"})), "settings_pane",
         "update_required/unknown_component", {}),
        ("unknown-field-kind", "form field kinds are closed",
         changed(ROUTINE_FORM, _set(FIELDS + [3, "kind"], "slider")), "routine_form",
         "fallback/unknown_component", {}),
        ("operation-review-node", "no document can describe operation_review",
         changed(ROUTINE_CARD, _set(["root", "children", 2], {"type": "operation_review"})), "routine_result_card",
         "fallback/denied_route", {}),
        ("secret-entry-node", "no document can describe secret_entry",
         changed(ROUTINE_CARD, _set(["root", "children", 2], {"type": "secret_entry"})), "routine_result_card",
         "fallback/denied_route", {}),
        ("secret-entry-view", "a document cannot be the secret_entry view",
         changed(ROUTINE_CARD, _set(["view"], "secret_entry")), "secret_entry", "fallback/denied_route", {}),
        ("password-field", "no secret or password form fields",
         changed(ROUTINE_FORM, _set(FIELDS + [0, "kind"], "password")), "routine_form", "fallback/denied_route",
         {}),
        ("navigate-operation-review", "navigate cannot reach approval screens",
         changed(ROUTINE_CARD, _set(HELP_ACTION, {"command": "navigate", "screen": "operation_review"})),
         "routine_result_card", "fallback/denied_route", {}),
        ("navigate-approvals", "navigate cannot reach the approvals list",
         changed(ROUTINE_CARD, _set(HELP_ACTION, {"command": "navigate", "screen": "approvals"})),
         "routine_result_card", "fallback/denied_route", {}),
        ("approve-command", "no approval command exists",
         changed(ROUTINE_CARD, _set(RUN_ACTION, {"command": "approval.approve"})), "routine_result_card",
         "fallback/denied_route", {}),
        ("unknown-command", "the action enum is closed",
         changed(ROUTINE_CARD, _set(RUN_ACTION, {"command": "shell.run"})), "routine_result_card",
         "fallback/unknown_action", {}),
        ("unknown-screen", "navigate screens are closed",
         changed(ROUTINE_CARD, _set(HELP_ACTION, {"command": "navigate", "screen": "terminal"})),
         "routine_result_card", "fallback/unknown_action", {}),
        ("save-outside-form", "routine.save is only a form submit",
         changed(ROUTINE_CARD, _set(RUN_ACTION, {"command": "routine.save", "routine": _b("routine.id")})),
         "routine_result_card", "fallback/action_context", {}),
        ("flow-next-outside-flow", "flow_next only inside a flow",
         changed(ROUTINE_CARD, _set(RUN_ACTION, {"command": "flow_next"})), "routine_result_card",
         "fallback/action_context", {}),
        ("action-extra-member", "action arguments are closed per command",
         changed(ROUTINE_CARD, _set(RUN_ACTION + ["url"], "https://docs.swarmhub.test/")), "routine_result_card",
         "fallback/schema_invalid", {}),
        # URLs.
        ("url-http", "https only", changed(ROUTINE_CARD, _set(HELP_ACTION + ["url"], "http://docs.swarmhub.test/")),
         "routine_result_card", "fallback/url_not_allowed", {}),
        ("url-host", "host not on the allowlist",
         changed(ROUTINE_CARD, _set(HELP_ACTION + ["url"], "https://evil.example/routines")), "routine_result_card",
         "fallback/url_not_allowed", {}),
        ("url-subdomain", "allowlisted hosts match exactly, not as a suffix",
         changed(ROUTINE_CARD, _set(HELP_ACTION + ["url"], "https://evil.docs.swarmhub.test/")),
         "routine_result_card", "fallback/url_not_allowed", {}),
        ("url-userinfo", "no userinfo (the real host would be evil.example)",
         changed(ROUTINE_CARD, _set(HELP_ACTION + ["url"], "https://docs.swarmhub.test@evil.example/")),
         "routine_result_card", "fallback/url_not_allowed", {}),
        ("url-javascript", "no other schemes", changed(ROUTINE_CARD, _set(HELP_ACTION + ["url"], "javascript:alert(1)")),
         "routine_result_card", "fallback/url_not_allowed", {}),
        ("url-empty-allowlist", "with no allowlist every URL is refused (compiled default)", ROUTINE_CARD,
         "routine_result_card", "fallback/url_not_allowed", {"url_hosts": []}),
        # Predicates and bindings.
        ("predicate-expression", "no expression strings", changed(ROUTINE_CARD, _set(
            ["root", "children", 0, "visible_if"], {"expr": "result.status == 'ok'"})), "routine_result_card",
         "fallback/invalid_predicate", {}),
        ("predicate-string", "a predicate is a typed object, not a string", changed(ROUTINE_CARD, _set(
            ["root", "children", 0, "visible_if"], "result.status")), "routine_result_card",
         "fallback/invalid_predicate", {}),
        ("predicate-two-ops", "exactly one operator per predicate", changed(ROUTINE_CARD, _set(
            ["root", "children", 0, "visible_if"], {"exists": _b("result.status"), "missing": _b("result.diff")})),
         "routine_result_card", "fallback/invalid_predicate", {}),
        ("predicate-object-literal", "equals compares with a string, integer or boolean literal only",
         changed(ROUTINE_CARD, _set(["root", "children", 0, "visible_if", "equals", "value"], {"a": 1})),
         "routine_result_card", "fallback/invalid_predicate", {}),
        ("binding-root", "bindings start at a known local data root",
         changed(ROUTINE_CARD, _set(["root", "title"], _b("files.home"))), "routine_result_card",
         "fallback/invalid_binding", {}),
        ("binding-secret", "bindings never reach secret-like data",
         changed(ROUTINE_CARD, _set(["root", "title"], _b("box.api_token"))), "routine_result_card",
         "fallback/denied_binding", {}),
        ("binding-approval", "bindings never reach approval records",
         changed(ROUTINE_CARD, _set(["root", "title"], _b("record.approval_state"))), "routine_result_card",
         "fallback/denied_binding", {}),
        ("field-id-key", "form fields cannot collect keys",
         changed(ROUTINE_FORM, _set(FIELDS + [0, "id"], "api_key")), "routine_form", "fallback/denied_binding", {}),
        # Text.
        ("markdown-link", "markdown links are refused; URLs go through open_url",
         changed(ROUTINE_CARD, _set(["root", "children", 2, "text"], "See [here](https://evil.example/)")),
         "routine_result_card", "fallback/markup_not_allowed", {}),
        *[(case_id, description, simple("m", _text(text, style="markdown")), "m",
           "fallback/markup_not_allowed", {}) for case_id, description, text in (
            ("markdown-reference-full", "full reference link with definition", "[x][r]\n\n[r]: https://evil.example"),
            ("markdown-reference-collapsed", "collapsed reference link", "[r][]\n\n[r]: https://evil.example"),
            ("markdown-reference-shortcut", "shortcut reference link", "[r]\n\n[r]: https://evil.example"),
            ("markdown-reference-definition", "bare reference definition", "[r]: https://evil.example"),
            ("markdown-autolink", "URI autolink", "<https://evil.example>"),
            ("markdown-autolink-email", "email autolink with nonletter local part", "<1+test@evil.example>"),
            ("markdown-autolink-scheme", "arbitrary URI scheme autolink", "<custom:destination>"),
            ("markdown-image", "inline image", "![x](https://evil.example/image.png)"),
            ("markdown-image-reference", "reference image", "![x][r]\n\n[r]: https://evil.example/image.png"),
            ("markdown-escaped-bracket", "escaped syntax is refused too", r"\[x\]"),
            ("markdown-code-bracket", "syntax in code is refused too", "`[x]`"),
            ("markdown-open-bracket", "even an unmatched opening bracket is refused", "["),
            ("markdown-close-bracket", "even an unmatched closing bracket is refused", "]"),
            ("markdown-less-than", "even an unmatched less-than byte is refused", "<"),
            ("markdown-combining-bracket", "syntax bytes are refused inside grapheme clusters", "[\u0301"),
        )],
        ("markdown-reference-critical", "reference syntax in a critical document requires an update",
         simple("m", _text("[r]\n\n[r]: https://evil.example", style="markdown"), critical=True), "m",
         "update_required/markup_not_allowed", {}),
        ("plain-link-syntax", "plain text keeps syntax as literal text",
         simple("m", _text("[x](https://evil.example) <1@evil.example>", style="plain")), "m", "render", {}),
        ("markdown-html", "no HTML in markdown",
         changed(ROUTINE_CARD, _set(["root", "children", 2, "text"], "<script>alert(1)</script>")),
         "routine_result_card", "fallback/markup_not_allowed", {}),
        ("control-character", "no control characters other than tab and newline",
         changed(ROUTINE_CARD, _set(["root", "children", 0, "text"], "Done\u0007")), "routine_result_card",
         "fallback/invalid_text", {}),
        ("string-too-long", "a string above max_string_bytes",
         changed(ROUTINE_CARD, _set(["root", "children", 0, "text"], "x" * 4097)), "routine_result_card",
         "fallback/string_too_long", {}),
        ("bom-in-view", "U+FEFF inside a string is a character, not a byte-order mark to strip",
         changed(ROUTINE_CARD, _set(["view"], "\ufeffroutine_result_card")), "routine_result_card",
         "fallback/schema_invalid", {}),
        ("bom-in-text", "U+FEFF at the start of a text is kept (the Swift round trip must equal the input)",
         changed(ROUTINE_CARD, _set(["root", "children", 0, "text"], "\ufeffDone")), "routine_result_card", "render",
         {}),
        # Kill switch (kill.view.<type> from config.flags, P6a).
        ("killed-view", "kill.view.<view> selects the compiled fallback before decoding", ROUTINE_CARD,
         "routine_result_card", "fallback/killed", {"killed": ["routine_result_card"]}),
        ("killed-component", "kill.view.<component type> used anywhere in the document", ROUTINE_CARD,
         "routine_result_card", "fallback/killed", {"killed": ["diff_preview"]}),
        ("killed-critical", "a kill switch selects the compiled view, never update required",
         changed(SETTINGS_CRITICAL, _set(["schema"], "swarmhub/ui/2")), "settings_pane", "fallback/killed",
         {"killed": ["settings_pane"]}),
        ("killed-unused", "killing a type the document does not use changes nothing", ROUTINE_CARD,
         "routine_result_card", "render", {"killed": ["flow"]}),
        ("nested-flow", "flows do not nest", simple("f", {"type": "flow", "id": "outer", "steps": [
            {"id": "a", "title": "A", "children": [{"type": "flow", "id": "inner", "steps": [
                {"id": "b", "title": "B", "children": []}]}]}]}), "f", "fallback/schema_invalid", {}),
    ]

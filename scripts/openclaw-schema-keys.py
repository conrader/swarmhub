#!/usr/bin/env python3
"""P12: write Tests/Fixtures/openclaw/param-keys.json from OpenClaw's protocol.schema.json (stdlib only).

Usage: python3 -I scripts/openclaw-schema-keys.py <protocol.schema.json> [out.json]
Re-run when bumping the tested OpenClaw version; a test checks every request SwarmHub builds against the output.
"""
import hashlib, json, sys

METHODS = ["connect", "agents.list", "sessions.create", "sessions.list", "chat.send", "chat.abort", "chat.history",
           "exec.approval.list", "exec.approval.resolve", "models.list"]
NESTED = {"connect": ["client", "device", "auth"]}


def definition_name(method):
    if method == "connect":
        return "ConnectParams"
    return "".join(part[:1].upper() + part[1:] for part in method.split(".")) + "Params"


def resolve(defs, node):
    while isinstance(node, dict) and "$ref" in node:
        node = defs[node["$ref"].split("/")[-1]]
    return node


def keys(defs, node):
    node = resolve(defs, node)
    return {"allowed": sorted(node.get("properties", {})), "required": sorted(node.get("required", [])),
            "closed": node.get("additionalProperties") is False}


def main():
    path = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else "Tests/Fixtures/openclaw/param-keys.json"
    raw = open(path, "rb").read()
    schema = json.loads(raw)
    defs, methods = schema["definitions"], schema["methods"]
    result = {"source": "protocol.schema.json", "sha256": hashlib.sha256(raw).hexdigest(), "methods": {}}
    for method in METHODS:
        name = definition_name(method)
        entry = {"definition": name if name in defs else None, "scope": methods.get(method, {}).get("scope"),
                 "since": methods.get(method, {}).get("since")}
        if name in defs:
            entry.update(keys(defs, defs[name]))
            props = resolve(defs, defs[name]).get("properties", {})
            for child in NESTED.get(method, []):
                entry[child] = keys(defs, props[child])
        result["methods"][method] = entry
    with open(out, "w") as handle:
        json.dump(result, handle, indent=1, sort_keys=True)
        handle.write("\n")
    print(f"wrote {out}: {len(METHODS)} methods")


if __name__ == "__main__":
    main()

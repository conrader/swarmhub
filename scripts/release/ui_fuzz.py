"""Shared deterministic fuzz for SDUI view documents (CORE-PHASES.md P7a).

SplitMix64 plus byte and structural mutations of the golden documents. `SDUIFuzzTests.swift` is a line-by-line port:
both sides draw the same numbers in the same order, so they judge the same mutated bytes, and the Swift test must
reproduce the verdict list in `Tests/Fixtures/release-bundles/ui/fuzz.json`. Stdlib only.
"""

import copy

import jcs
from ui_reference import COMPONENTS

MASK = (1 << 64) - 1
INTERESTING = b'{}[]":,\\ 0123456789-.eE\x00\xff'
POOL = ["", "x", "operation_review", "secret_entry", "webview", "https://evil.example/x", "javascript:alert(1)",
        "routine.secret_token", "[x](https://evil.example)", 0, -1, 9007199254740991, True, False, [], {}]
TYPES = sorted(COMPONENTS) + ["operation_review", "secret_entry", "webview", "script"]


class SplitMix64:
    def __init__(self, seed):
        self.state = seed & MASK

    def next(self):
        self.state = (self.state + 0x9E3779B97F4A7C15) & MASK
        z = self.state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASK
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & MASK
        return z ^ (z >> 31)

    def below(self, n):
        return self.next() % n


def mutate_bytes(data, rng):
    data = bytearray(data)
    for _ in range(1 + rng.below(4)):
        op = rng.below(5)
        if op == 2:
            position = rng.below(len(data) + 1)
            data.insert(position, INTERESTING[rng.below(len(INTERESTING))])
            continue
        if not data:
            continue
        if op == 0:
            position = rng.below(len(data))
            data[position] ^= 1 << rng.below(8)
        elif op == 1:
            del data[rng.below(len(data))]
        elif op == 3:
            del data[rng.below(len(data)):]
        else:
            start = rng.below(len(data))
            piece = bytes(data[start:start + 1 + rng.below(min(32, len(data) - start))])
            position = rng.below(len(data) + 1)
            data[position:position] = piece
    return bytes(data)


def _paths(value, prefix):
    out = [prefix]
    if isinstance(value, dict):
        for key in sorted(value):
            out += _paths(value[key], prefix + [key])
    elif isinstance(value, list):
        for index, item in enumerate(value):
            out += _paths(item, prefix + [index])
    return out


def _at(root, path):
    for step in path:
        root = root[step]
    return root


def _card(value):
    return {"type": "card", "children": [value]}


def mutate_structure(root, rng):
    """One structural mutation of a parsed document; returns the new root."""
    paths = _paths(root, [])
    path = paths[rng.below(len(paths))]
    op = rng.below(7)
    value = copy.deepcopy(_at(root, path))
    if op == 1 or op == 2:
        if not path:
            return {} if op == 1 else [value, copy.deepcopy(value)]
        parent, step = _at(root, path[:-1]), path[-1]
        if op == 1:
            del parent[step]
        elif isinstance(parent, dict):
            parent["extra"] = value
        else:
            parent.insert(step, value)
        return root
    if op == 0:
        new = copy.deepcopy(POOL[rng.below(len(POOL))])
    elif op == 3:
        new = _card(value)
    elif op == 4:
        kind = TYPES[rng.below(len(TYPES))]
        if isinstance(value, dict):
            value["type"] = kind
            new = value
        else:
            new = kind
    elif op == 5:
        new = value
        for _ in range(1 + rng.below(16)):
            new = _card(new)
    else:
        times = 2 + rng.below(40)
        new = value * times if isinstance(value, list) else [value] * times
    if not path:
        return new
    _at(root, path[:-1])[path[-1]] = new
    return root


def fuzz_document(golden, rng):
    """Mutated bytes for one iteration, or None when the structural result is not representable (depth > 32)."""
    if rng.below(2) == 1:
        try:
            root = jcs.loads(golden)
        except jcs.JCSError:
            return mutate_bytes(golden, rng)
        try:
            return jcs.canonical(mutate_structure(root, rng))
        except jcs.JCSError:
            return None
    return mutate_bytes(golden, rng)


def label(verdict):
    return verdict["verdict"] if verdict["verdict"] == "render" else verdict["verdict"] + "/" + verdict["reason"]

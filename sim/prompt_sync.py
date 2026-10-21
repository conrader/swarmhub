"""Python port of the bot prompt slot sync (Packages/SwarmHubCore/Sources/SwarmHubCore/Configuration/BotPromptSync.swift).

No Swift toolchain runs on the Linux review host, so the merge rules are simulated here and checked against the
same vectors the Swift tests read (Tests/Fixtures/prompt_sync/). Field names and size limits are read
from the Swift source (sim/test_prompt_sync.py checks them), so only the control flow is kept in step by hand.

A context is a dict with BotPromptContext's keys; coordinator is None or a string. A document is
{"schema": 1, "bots": {key: {field: {"value", "at", "origin"}}}}, the Swift JSON shape.
"""
import sim_isolation  # noqa: F401  Exits unless isolated (PID namespace / macOS signal guard); keep it the first import.
from pathlib import Path
import copy
import re

SWIFT = Path(__file__).resolve().parents[1] / 'Packages/SwarmHubCore/Sources/SwarmHubCore/Configuration/BotPromptSync.swift'
SCHEMA = 1
MAX_TIMESTAMP = 2**63 - 1  # Swift Int64.max; writes saturate, then use the ordinary tie-break.


def swift_constants(source=None):
    source = source if source is not None else SWIFT.read_text()
    found = {name: int(re.search(r'static let %s = ([\d_]+)' % name, source).group(1).replace('_', ''))
             for name in ('maxText', 'maxRules')}
    found['fields'] = re.findall(r'public var (\w+): PromptStamp<', source)
    return found


_CONSTANTS = swift_constants()
MAX_TEXT = _CONSTANTS['maxText']
MAX_RULES = _CONSTANTS['maxRules']
TEXT_FIELDS = [f for f in _CONSTANTS['fields'] if f != 'approvalRules']
FIELDS = _CONSTANTS['fields']


def _bytes_precede(a, b):
    return a.encode('utf-8') < b.encode('utf-8')


def _sort_key(field, value):
    if field == 'approvalRules':
        return ''.join('%d:%s' % (len(rule.encode('utf-8')), rule) for rule in value)
    return value


def winner(field, a, b):
    """Last write wins; equal times break on origin, then value bytes (higher wins), as in PromptStamp.winner."""
    if a is None:
        return b
    if b is None:
        return a
    if a['at'] != b['at']:
        return a if a['at'] > b['at'] else b
    if a['origin'] != b['origin']:
        return b if _bytes_precede(a['origin'], b['origin']) else a
    return b if _bytes_precede(_sort_key(field, a['value']), _sort_key(field, b['value'])) else a


def acceptable(field, stamp):
    if stamp is None or not 0 <= stamp['at'] <= MAX_TIMESTAMP:
        return None
    if field == 'approvalRules':
        ok = len(stamp['value']) <= MAX_RULES and all(len(rule) <= MAX_TEXT for rule in stamp['value'])
    else:
        ok = len(stamp['value']) <= MAX_TEXT  # Python len counts code points, Swift counts unicodeScalars
    return stamp if ok else None


def merged_settings(a, b):
    result = {}
    for field in FIELDS:
        pick = winner(field, acceptable(field, a.get(field)), acceptable(field, b.get(field)))
        if pick is not None:
            result[field] = copy.deepcopy(pick)
    return result


def new_document():
    return {'schema': SCHEMA, 'bots': {}}


def merge(document, remote):
    """Merge remote into document in place; a different schema is left unmerged (False)."""
    if remote.get('schema') != SCHEMA:
        return False
    for key, theirs in remote.get('bots', {}).items():
        settings = {f: theirs[f] for f in FIELDS if f in theirs}  # unknown keys, e.g. persona, are never read
        document['bots'][key] = merged_settings(document['bots'].get(key, {}), settings)
    return True


def _context_value(context, field):
    return (context.get('coordinator') or '') if field == 'coordinator' else context[field]


def _set_context_value(context, field, value):
    if field == 'coordinator':
        context['coordinator'] = value or None
    else:
        context[field] = copy.deepcopy(value)


def context(document, key, fallback):
    result = copy.deepcopy(fallback)
    for field, stamp in document['bots'].get(key, {}).items():
        _set_context_value(result, field, stamp['value'])
    return result


def write(document, new, old, key, origin, now):
    """Stamp fields where new differs from old; old None is a time-0 baseline that only fills gaps."""
    settings = document['bots'].setdefault(key, {})
    for field in FIELDS:
        value = _context_value(new, field)
        current = settings.get(field)
        if old is None:
            if current is None:
                settings[field] = {'value': copy.deepcopy(value), 'at': 0, 'origin': origin}
        elif _context_value(old, field) != value:
            at = min(MAX_TIMESTAMP, max(now, min(current['at'] if current else -1, MAX_TIMESTAMP - 1) + 1))
            settings[field] = {'value': copy.deepcopy(value), 'at': at, 'origin': origin}


class Device:
    """BotPromptSyncState: the shared document plus the last local settings published per bot."""

    def __init__(self, origin):
        self.origin = origin
        self.document = new_document()
        self.observed = {}

    def observe(self, local, key, now):
        write(self.document, local, self.observed.get(key), key, self.origin, now)
        self.observed[key] = copy.deepcopy(local)

    def edit(self, key, now, fallback, changes):
        current = context(self.document, key, fallback)
        updated = copy.deepcopy(current)
        for field, value in changes.items():
            _set_context_value(updated, field, value)
        write(self.document, updated, current, key, self.origin, now)

    def context(self, key, fallback):
        return context(self.document, key, fallback)

    def merge(self, remote):
        return merge(self.document, remote)

"""Bot prompt slot sync between the Mac and iOS apps: last write wins per field, personas untouched.

No Swift toolchain runs here, so the shared vectors (Tests/Fixtures/prompt_sync/, also read by
BotPromptSyncTests.swift) run through the Python port (sim/prompt_sync.py), and randomized delivery orders check
that devices converge. Pure data, no processes or network.
"""
import copy
import json
from pathlib import Path
import random
import re
import unittest

try:
    from sim import prompt_sync
except ImportError:  # `python3 -m unittest discover` from inside sim/
    import prompt_sync

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / 'Tests/Fixtures/prompt_sync'
VECTORS = json.loads((FIXTURES / 'index.json').read_text())
VECTORS['scenarios'] = [scenario for name in VECTORS['scenarioFiles']
                        for scenario in json.loads((FIXTURES / name).read_text())]
PROMPT_SWIFT = ROOT / 'Packages/SwarmHubCore/Sources/SwarmHubCore/Configuration/BotSystemPrompt.swift'


def resolve(ref):
    result = copy.deepcopy(VECTORS['contexts'][ref['base']])
    for field, value in ref.get('with', {}).items():
        result[field] = (value or None) if field == 'coordinator' else value
    return result


def run(scenario):
    devices = {}
    device = lambda name: devices.setdefault(name, prompt_sync.Device(name))
    for op in scenario['ops']:
        kind = op['op']
        if kind == 'observe':
            device(op['device']).observe(resolve(op['context']), op['bot'], op['now'])
        elif kind == 'edit':
            device(op['device']).edit(op['bot'], op['now'], resolve(op['fallback']), op['set'])
        elif kind == 'sync':
            device(op['to']).merge(copy.deepcopy(device(op['from']).document))
        elif kind == 'receive':
            assert device(op['device']).merge(copy.deepcopy(op['document'])) == op['merged'], scenario['name']
        elif kind == 'expect':
            got = device(op['device']).context(op['bot'], resolve(op['fallback']))
            assert got == resolve(op['context']), (scenario['name'], got)
        elif kind == 'stamp':
            got = device(op['device']).document['bots'].get(op['bot'], {}).get(op['field'])
            if op['at'] is None:
                assert got is None, (scenario['name'], got)
            else:
                assert (got['at'], got['origin']) == (op['at'], op['origin']), (scenario['name'], got)
                if 'value' in op:
                    assert got['value'] == op['value'], (scenario['name'], got)
        else:
            raise AssertionError('unknown op ' + kind)
    return devices


class VectorTests(unittest.TestCase):
    def test_every_scenario(self):
        for scenario in VECTORS['scenarios']:
            with self.subTest(scenario['name']):
                run(scenario)

    def test_vectors_cover_every_op_and_field(self):
        ops = {op['op'] for s in VECTORS['scenarios'] for op in s['ops']}
        self.assertEqual(ops, {'observe', 'edit', 'sync', 'receive', 'expect', 'stamp'})
        edited = {f for s in VECTORS['scenarios'] for op in s['ops'] if op['op'] == 'edit' for f in op['set']}
        self.assertTrue({'owner', 'coordinator', 'language', 'approvalRules'} <= edited)


class SourceParityTests(unittest.TestCase):
    def test_synced_fields_are_exactly_the_prompt_slots(self):
        source = PROMPT_SWIFT.read_text()
        struct = re.search(r'public struct BotPromptContext.*?\n    public init', source, re.S).group(0)
        slots = re.findall(r'public var (\w+):', struct)
        self.assertEqual(prompt_sync.FIELDS, slots)
        self.assertNotIn('persona', prompt_sync.FIELDS)

    def test_limits_come_from_swift(self):
        self.assertEqual((prompt_sync.MAX_TEXT, prompt_sync.MAX_RULES), (2000, 50))

    def test_fixture_files_stay_under_500_lines(self):
        for name in ['index.json', *VECTORS['scenarioFiles']]:
            self.assertLess(len((FIXTURES / name).read_text().splitlines()), 500, name)

    def test_python_rejects_timestamps_swift_cannot_decode(self):
        for field, value in [('owner', 'x'), ('approvalRules', ['x'])]:
            self.assertIsNone(prompt_sync.acceptable(field, {
                'value': value, 'at': 2**63, 'origin': 'remote'}))


VALUES = {'approvalRules': [['a'], ['b', 'c'], [], ['a', 'b']]}
CTX_KEYS = prompt_sync.FIELDS


def random_context(rng):
    ctx = {}
    for field in CTX_KEYS:
        if field in VALUES:
            ctx[field] = list(rng.choice(VALUES[field]))
        elif field == 'coordinator':
            ctx[field] = rng.choice([None, 'Jarvis', 'Ops'])
        else:
            ctx[field] = rng.choice(['A', 'B', 'C'])
    return ctx


class ConvergenceTests(unittest.TestCase):
    def test_random_edits_and_delivery_orders_converge(self):
        rng = random.Random(20261020)
        for trial in range(300):
            devices = [prompt_sync.Device(name) for name in ('mac', 'ios', 'ipad')]
            fallback = random_context(rng)
            clocks = {d.origin: rng.randint(0, 50) for d in devices}  # skewed device clocks
            local = random_context(rng)
            for _ in range(rng.randint(1, 25)):
                d = rng.choice(devices)
                clocks[d.origin] += rng.randint(0, 3)  # equal times happen often
                action = rng.random()
                if action < 0.3 and d.origin == 'mac':
                    if rng.random() < 0.5:  # the Mac's own settings change between renders
                        local.update({k: v for k, v in random_context(rng).items() if rng.random() < 0.3})
                    d.observe(local, 'k', clocks[d.origin])
                elif action < 0.65:
                    field = rng.choice(CTX_KEYS)
                    d.edit('k', clocks[d.origin], fallback, {field: random_context(rng)[field]})
                else:
                    other = rng.choice(devices)
                    other.merge(copy.deepcopy(d.document))
            for _ in range(2):  # full gossip: everyone hears everyone, twice
                for a in devices:
                    for b in devices:
                        b.merge(copy.deepcopy(a.document))
            docs = [d.document for d in devices]
            self.assertTrue(all(doc == docs[0] for doc in docs), trial)
            contexts = [d.context('k', fallback) for d in devices]
            self.assertTrue(all(c == contexts[0] for c in contexts), trial)

    def test_merge_is_commutative_associative_idempotent(self):
        rng = random.Random(7)

        def random_doc():
            doc = prompt_sync.new_document()
            bot = doc['bots'].setdefault('k', {})
            for field in CTX_KEYS:
                if rng.random() < 0.7:
                    value = random_context(rng)[field]
                    if field == 'coordinator':
                        value = value or ''
                    bot[field] = {'value': value, 'at': rng.randint(0, 3), 'origin': rng.choice(['mac', 'ios'])}
            return doc

        def merged(*docs):
            out = prompt_sync.new_document()
            for doc in docs:
                prompt_sync.merge(out, copy.deepcopy(doc))
            return out

        for _ in range(500):
            a, b, c = random_doc(), random_doc(), random_doc()
            self.assertEqual(merged(a, b), merged(b, a))
            self.assertEqual(merged(merged(a, b), c), merged(a, merged(b, c)))
            self.assertEqual(merged(a, a), merged(a))

    def test_a_later_local_edit_always_wins_after_seeing_a_value(self):
        mac, ios = prompt_sync.Device('mac'), prompt_sync.Device('ios')
        base = resolve({'base': 'mac'})
        mac.observe(base, 'k', 10**12)  # mac clock far ahead
        mac.observe(dict(base, owner='Future'), 'k', 10**12 + 1)
        ios.merge(copy.deepcopy(mac.document))
        ios.edit('k', 5, base, {'owner': 'Now'})
        mac.merge(copy.deepcopy(ios.document))
        self.assertEqual(mac.context('k', base)['owner'], 'Now')


if __name__ == '__main__':
    unittest.main()

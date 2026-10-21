"""Shared setup for the P5b device-approval tests: temp HOME box, TEST keys, signing, vector state.

Only public TEST seeds from Tests/Fixtures/release-bundles/TEST-device-keys.json are used. No network.
"""
import sim_isolation  # noqa: F401  Exits unless isolated (PID namespace / macOS signal guard); keep it the first import.
import copy
import hashlib
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / 'Resources/Skills/swarmhub-messages/scripts'
sys.path.insert(0, str(SCRIPTS))
sys.path.insert(0, str(ROOT / 'scripts/release'))
import ed25519_ref  # noqa: E402  (TEST signing only; the box never signs)
import swarm_device_state as ds  # noqa: E402
import swarm_devices as devices  # noqa: E402
import swarm_policy as policy  # noqa: E402
import swarm_remote as remote  # noqa: E402
from swarm_store import canonical, database  # noqa: E402

FIXTURE = ROOT / 'Tests/Fixtures/device_approval_protocol.json'
DOCUMENT = ds.jcs.loads(FIXTURE.read_bytes())
KEYS = {k['key_id']: k for k in ds.jcs.loads((ROOT / 'Tests/Fixtures/release-bundles/TEST-device-keys.json')
                                             .read_bytes())['keys']}
ORIGIN = 'https://box.example.invalid'
DEVICE = 'TEST-device-1'


def sign(body, key_id=DEVICE, context=ds.CONTEXT):
    signature = ed25519_ref.sign(bytes.fromhex(KEYS[key_id]['seed']), context + ds.jcs.canonical(body)).hex()
    return ds.jcs.canonical({'signed': body, 'signature': signature})


def clock(now):
    return patch.object(ds.time, 'time', return_value=now)


class Box(unittest.TestCase):
    """A real box: temp HOME, three profiles with synthetic v1 keys, owner gate → owner."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        env = patch.dict(os.environ, HOME=self.tmp.name)
        env.start()
        self.addCleanup(env.stop)
        for name in [k for k in os.environ if k.startswith('HERMES_')]:
            del os.environ[name]  # Restored by patch.dict; operator tools refuse inside a gateway.
        self.keys = {name: 'synthetic-' + name + '-key' for name in ('owner', 'worker', 'other')}
        for name, key in self.keys.items():
            root = Path(self.tmp.name) / '.hermes/profiles' / name
            root.mkdir(parents=True)
            (root / '.env').write_text('export API_SERVER_KEY="' + key + '"\n')
        policy.publish({'owner': 'owner', 'coordinator': 'owner'})
        self.wake = Mock()

    def service(self):
        return remote.ControlService(ORIGIN, self.wake)

    # Vector state -------------------------------------------------------------------------------

    def load_vector_state(self, case):
        state = copy.deepcopy(DOCUMENT['state'])
        state.update(copy.deepcopy(case['state_overrides']))
        original = DOCUMENT['state']['spec']
        with database() as db:
            db.execute('INSERT INTO approval_runtime VALUES(1,?)', (state['runtime'],))
            db.execute('INSERT INTO actions(id,fingerprint,intent,spec,gate,status,created) VALUES(?,?,?,?,?,?,?)',
                       (state['task'], hashlib.sha256(canonical(original).encode()).hexdigest(),
                        state['spec']['intent'], canonical(state['spec']), state['gate'], state['status'], 0))
            for key_id, device in state['devices'].items():
                db.execute('INSERT INTO approval_devices VALUES(?,?,?,?,0,?)',
                           (key_id, device['ed25519_pub'], ds.jcs.canonical(device['profiles']).decode(),
                            int(device['revoked']), ''))
            db.execute('INSERT INTO approval_mode VALUES(1,?,0)', (int(state['device_required']),))
            for nonce, entry in state['nonces'].items():
                b = entry['binding']
                db.execute('INSERT INTO approval_challenges VALUES(?,?,?,?,?,?,?)',
                           (nonce, b['key_id'], b['task'], b['issued'], b['expires'], int(entry['used']),
                            ds.jcs.canonical(b).decode()))
        return state

    def box_rows(self):
        with database() as db:
            return {table: [tuple(r) for r in db.execute('SELECT * FROM ' + table + ' ORDER BY 1')]
                    for table in ('actions', 'approval_challenges', 'approval_expired', 'approval_mode_changed', 'approval_receipts',
                                  'approval_devices', 'approval_mode', 'denials')}

    # Live flow ----------------------------------------------------------------------------------

    def enroll(self, key_id=DEVICE, profiles=('owner',)):
        return devices.enroll(key_id, KEYS[key_id]['ed25519_pub'], list(profiles), 'TEST')

    def submit(self, intent='fixture'):
        return policy.submit({'kind': 'outbound', 'bot': 'worker', 'intent': intent, 'fake': True,
                              'to': 'nobody@example.invalid', 'text': 'FAKE never sent ☃ ' + intent, 'risks': ['money']})

    def read_body(self, verb, task, key_id=DEVICE, profile='owner', issued=None, **changes):
        body = {'version': 2, 'domain': ds.REQUEST_DOMAIN, 'verb': verb, 'key_id': key_id, 'origin': ORIGIN,
                'profile': profile, 'task': task, 'issued': int(time.time()) if issued is None else issued}
        body.update(changes)
        return body

    def challenge(self, service, task, key_id=DEVICE, profile='owner'):
        status, result = service.handle_v2(remote.PREFIX_V2 + profile + '/challenge',
                                           sign(self.read_body('challenge', task, key_id, profile), key_id,
                                                ds.REQUEST_CONTEXT))
        self.assertEqual(status, 200, result)
        return result['challenge']

    def decision(self, binding, approved=True, key_id=DEVICE):
        return sign({**binding, 'approved': approved}, key_id)

    def post(self, service, verb, raw, profile='owner'):
        return service.handle_v2(remote.PREFIX_V2 + profile + '/' + verb, raw)

    def receipt(self, service, task, key_id=DEVICE, profile='owner'):
        return self.post(service, 'receipt', sign(self.read_body('receipt', task, key_id, profile), key_id,
                                                  ds.REQUEST_CONTEXT), profile)

    def v1(self, service, verb, task, approved=True, profile='owner'):
        now = int(time.time())
        value = dict(version=1, origin=service.origin, profile=profile, verb=verb, task=task,
                     nonce=str(remote.uuid.uuid4()), issued=now, expires=now + 60)
        if verb == 'decide':
            row = policy.action(task)
            value.update(binding=dict(origin=service.origin, runtime=service.runtime, profile='owner'),
                         fingerprint=row['fingerprint'], gate=row['gate'], approved=approved)
        raw = canonical(value).encode()
        key = self.keys[profile]
        return service.handle(remote.PREFIX + profile, 'Bearer ' + key, remote.mac(key, 'request', raw), raw)

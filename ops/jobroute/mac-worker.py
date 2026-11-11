#!/usr/bin/python3 -IB
"""Mac queue worker. Install this file and its two pinned helpers together.

Cleanup covers cooperating processes in the original group, not daemonized workloads.
"""
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time

# Fixed siblings only: isolated Python must never import helpers from cwd or PYTHONPATH.
# SHA-256 pins below bind both helper modules to this worker release.


def _helper(name):
    path = Path(__file__).resolve().with_name(name + '.py')
    directory = path.parent.stat()
    if directory.st_uid not in (0, os.geteuid()) or directory.st_mode & 0o022:
        raise ValueError('unsafe worker installation')
    fd = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid not in (0, os.geteuid()) or st.st_mode & 0o022:
            raise ValueError('unsafe worker helper')
        raw = os.read(fd, 65537)
    finally:
        os.close(fd)
    if hashlib.sha256(raw).hexdigest() != HELPERS[name]:
        raise ValueError('worker helper version mismatch')
    module = importlib.util.module_from_spec(importlib.util.spec_from_loader(name, loader=None))
    exec(compile(raw, str(path), 'exec'), module.__dict__)
    return module


HELPERS = {'mac_worker_lifecycle': '40ce69e2c4626ed5aa09832acc7b534a392c5f48d48ea2b8d6fc35759fe21b00', 'mac_worker_state': '0b6c1c773499da34887c03d7dabbe1e2881ad0cb525eb99d263813b70d9fb5f5'}
try:
    life = _helper('mac_worker_lifecycle')
    state_api = _helper('mac_worker_state')
except Exception:
    print('Mac worker refused helper installation', file=sys.stderr)
    raise SystemExit(2)

QUEUE_WAIT = 7200
RUN_LIMIT = 14400
QUEUE_LIMIT = 60
GRACE = 120
EXIT_GRACE = 2
KILL_DRAIN_LIMIT = 5
SETTLE = 135
TIMED_OUT = 124
INCOMPLETE = 125
ARTIFACT_FAILED = 126
SSH_FAILED = 255
RESERVED_SUBSTITUTE = 1
RETAINED = []


class LaunchRefused(Exception):
    pass


def _diagnostic(message):
    # Even a caller that stops reading stderr cannot hold teardown open.
    import fcntl
    flags = None
    try:
        flags = fcntl.fcntl(2, fcntl.F_GETFL)
        fcntl.fcntl(2, fcntl.F_SETFL, flags | os.O_NONBLOCK)
        os.write(2, ('Mac worker: ' + message + '\n').encode())
    except Exception:
        pass
    finally:
        if flags is not None:
            try:
                fcntl.fcntl(2, fcntl.F_SETFL, flags)
            except Exception:
                pass


class Result:
    def __init__(self):
        self.returncode = None
        self.deadline = None
        self.cleanup_complete = False
        self.protocol_valid = True
        self.timed_out = False
        self.stop_signal = None
        self.workload_state = 'unknown'
        self.workload_reaped = False
        self.runner_reaped = False
        self.cancel_ack = False
        self.queue_state = 'unknown'
        self.reasons = set()

    def fail(self, reason):
        self.reasons.add(reason)
        self.protocol_valid = False

    def record(self):
        return dict(phase='terminal' if self.cleanup_complete else 'containing',
                    cleanup_complete=self.cleanup_complete, protocol_valid=self.protocol_valid,
                    original_status=self.returncode, deadline=self.deadline, timed_out=self.timed_out,
                    runner_state='drained' if self.runner_reaped else 'unknown',
                    stop_signal=self.stop_signal, workload_state=self.workload_state,
                    workload_reaped=self.workload_reaped, runner_reaped=self.runner_reaped,
                    cancel_ack=self.cancel_ack, queue_state=self.queue_state,
                    reasons=sorted(self.reasons))


def _status(result):
    if not result.cleanup_complete or not result.protocol_valid:
        return INCOMPLETE
    if result.stop_signal:
        return 128 + result.stop_signal
    if result.timed_out:
        return TIMED_OUT
    code = result.returncode
    if code is None:
        return INCOMPLETE
    code = 128 - code if code < 0 else code
    if code in (TIMED_OUT, INCOMPLETE, ARTIFACT_FAILED, SSH_FAILED):
        _diagnostic(f'the runner exited {code}; reported as 1')
        return 1
    return code


def _publish(state, name, result):
    try:
        state.evidence(name, result.record())
        return True
    except Exception:
        result.fail('evidence_write_failed')
        _diagnostic('evidence_write_failed')
        return False


def _receipt(state):
    record = state.evidence('supervisor-result.json')
    fields = set(Result().record()) | {'version', 'invocation'}
    if set(record) != fields:
        raise ValueError('invalid receipt schema')
    for key in ('cleanup_complete', 'protocol_valid', 'timed_out', 'workload_reaped', 'runner_reaped', 'cancel_ack'):
        if type(record[key]) is not bool:
            raise ValueError('invalid receipt flag')
    if record['phase'] not in ('terminal', 'containing') or record['queue_state'] not in ('unknown', 'held'):
        raise ValueError('invalid receipt phase')
    if record['workload_state'] not in ('unknown', 'drained', 'not_started'):
        raise ValueError('invalid workload state')
    if record['runner_state'] not in ('drained', 'unknown'):
        raise ValueError('invalid runner state')
    if record['deadline'] is not None and (type(record['deadline']) not in (int, float) or not math.isfinite(record['deadline'])):
        raise ValueError('invalid deadline')
    if record['original_status'] is not None and type(record['original_status']) is not int:
        raise ValueError('invalid status')
    if record['stop_signal'] not in (None, signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        raise ValueError('invalid signal')
    if not isinstance(record['reasons'], list) or any(not isinstance(x, str) or not re.fullmatch('[a-z_]{1,64}', x) for x in record['reasons']):
        raise ValueError('invalid reasons')
    proven = (record['workload_state'] == 'drained' and record['workload_reaped'] or
              record['workload_state'] == 'not_started' and record['cancel_ack'])
    return record if record['phase'] == 'terminal' and record['cleanup_complete'] and proven else None


def _workload(control, argv, config=None):
    result, child, state = Result(), None, None
    parent = os.getppid()
    with life.Stops() as stops:
        try:
            life.supported()
            if not config or parent <= 1:
                raise ValueError('invalid launch context')
            state = state_api.State(control, config['token'], config['identity'])
            deadline = config['deadline']
            result.deadline = deadline
            def launch(fd, record):
                nonlocal child, deadline
                if record['phase'] not in ('queued', 'cancelled'):
                    raise ValueError('duplicate launch')
                if (stops.first or state.latched() or record['cancelled'] or
                        time.monotonic() >= deadline or os.getppid() != parent):
                    result.cancel_ack = True
                    result.returncode = 0
                    result.workload_state = 'not_started'
                    result.timed_out = time.monotonic() >= deadline
                    return
                state_api.State._write(fd, dict(record, phase='launching'))
                child = life.Child(subprocess.Popen(argv, start_new_session=True, close_fds=True))
                deadline = min(deadline, time.monotonic() + RUN_LIMIT)
                result.deadline = deadline
                state_api.State._write(fd, dict(record, phase='running', pgid=child.proc.pid))
            state.locked(min(deadline, time.monotonic() + 1), launch)
            while child is not None:
                result.timed_out = time.monotonic() >= deadline
                if stops.first or result.timed_out or state.latched():
                    break
                record = state.read(min(deadline, time.monotonic() + 1))
                if record['phase'] != 'running' or record['pgid'] != child.proc.pid:
                    raise ValueError('control disagrees with owner')
                if os.getppid() != parent:
                    result.queue_state = 'unknown'
                    result.reasons.add('runner_parent_lost')
                    break
                result.queue_state = 'held'
                result.timed_out = time.monotonic() >= deadline
                if stops.first or result.timed_out or state.latched() or record['cancelled'] or child.exited():
                    break
                life.pause(deadline)
        except Exception:
            result.fail('control_unavailable_or_invalid' if state else 'supervisor_setup_failed')
        finally:
            result.stop_signal = stops.first
            if child is not None:
                # No parser, writer, or registration failure can escape this ownership scope.
                grace = GRACE
                try:
                    if not (result.reasons or stops.first or result.timed_out or state.latched()):
                        grace = EXIT_GRACE
                except Exception:
                    result.fail('control_unavailable_or_invalid')
                while True:
                    try:
                        done = life.drain(child, grace, KILL_DRAIN_LIMIT)
                    except Exception:
                        done = False
                    if done:
                        break
                    result.reasons.add('workload_cleanup_incomplete')
                    if state:
                        _publish(state, 'supervisor-result.json', result)
                    # Guardian stays alive on failed drain/reap; no transport descriptors held.
                    time.sleep(1)
                    grace = 0
                result.reasons.update(child.reasons)
                result.workload_state, result.workload_reaped = 'drained', True
                result.returncode = child.proc.returncode
            result.stop_signal = stops.first
            result.cleanup_complete = result.workload_reaped or result.cancel_ack
            if state:
                try:
                    if result.protocol_valid:
                        state.update(time.monotonic() + 1, phase='drained' if child else 'cancelled', pgid=None)
                except Exception:
                    result.fail('control_unavailable_or_invalid')
                _publish(state, 'supervisor-result.json', result)
                state.close()
    return _status(result)


def _cancel(state, result, deadline):
    try:
        state.latch()
    except Exception:
        result.fail('cancel_latch_failed')
    try:
        record = state.update(deadline, cancelled=True)
        # Acknowledgement under the SAME gate prevents any future delayed launch.
        if record['phase'] in ('queued', 'cancelled'):
            state.update(deadline, phase='cancelled', pgid=None, cancelled=True)
            result.workload_state, result.cancel_ack = 'not_started', True
    except Exception:
        result.fail('control_unavailable_or_invalid')


def _bounded(argv, limit, workload_control=None, state=None, relay=None, call_deadline=None, **kw):
    result, child = Result(), None
    with life.Stops() as stops:
        life.supported()
        try:
            child = life.Child(subprocess.Popen(argv, start_new_session=True, close_fds=True, **kw))
        except OSError as exc:
            raise LaunchRefused() from exc
        deadline = call_deadline if call_deadline is not None else time.monotonic() + limit
        result.deadline = deadline
        try:
            while not stops.first:
                if child.exited():
                    break
                if time.monotonic() >= deadline:
                    result.timed_out = True
                    break
                if state:
                    state.read(min(deadline, time.monotonic() + 1))
                if relay:
                    relay.pump(min(deadline, time.monotonic() + .01))
                    if relay.failed:
                        raise OSError('relay failed')
                life.pause(deadline)
        except Exception:
            result.fail('runner_monitor_or_control_failed')
        finally:
            safe = state is None
            settle = time.monotonic() + SETTLE
            try:
                if state:
                    try:
                        state.read(min(settle, time.monotonic() + 1))
                    except Exception:
                        result.fail('control_unavailable_or_invalid')
                    proof = None
                    try:
                        proof = _receipt(state)
                    except FileNotFoundError:
                        pass
                    except Exception:
                        result.fail('invalid_supervisor_receipt')
                    if not proof:
                        _cancel(state, result, settle)
                    while not proof and not result.cancel_ack and time.monotonic() < settle:
                        try:
                            proof = _receipt(state)
                        except FileNotFoundError:
                            pass
                        except Exception:
                            result.fail('invalid_supervisor_receipt')
                        life.pause(settle)
                    if proof:
                        safe = True
                        result.workload_state = proof['workload_state']
                        result.workload_reaped = proof['workload_reaped']
                        result.cancel_ack = proof['cancel_ack']
                        result.timed_out |= proof['timed_out']
                        if not proof['protocol_valid']:
                            result.fail('supervisor_protocol_invalid')
                        result.reasons.update(proof['reasons'])
                    safe |= result.cancel_ack
            except Exception:
                result.fail('workload_reconciliation_failed')
            finally:
                # Never destroy an unresolved workload's guardian, including destructive runners.
                if safe:
                    try:
                        result.runner_reaped = life.drain(child, GRACE, KILL_DRAIN_LIMIT)
                    except Exception:
                        result.fail('runner_cleanup_failed')
                else:
                    result.reasons.add('runner_retained_for_supervision')
                result.reasons.update(child.reasons)
                result.returncode = child.proc.returncode
                result.cleanup_complete = safe and result.runner_reaped
                result.stop_signal = stops.first
                if not result.runner_reaped:
                    RETAINED.append(child)
                if relay:
                    relay.pump(time.monotonic() + .1)
                    if relay.failed:
                        result.fail('output_transport_failed')
                if state:
                    _publish(state, 'cleanup-result.json', result)
    if result.timed_out:
        _diagnostic(f'stopped at its {limit} s limit')
    return result


def _has_receipt(state):
    try:
        os.stat('supervisor-result.json', dir_fd=state.fd, follow_symlinks=False)
        return True
    except FileNotFoundError:
        return False


def run(request, home=None, execute=None):
    execute = execute or _bounded
    home = Path(home or Path.home())
    env = {'HOME': str(home), 'PATH': f'{home}/.local/bin:/opt/homebrew/bin:/usr/bin:/bin', 'SB_MACJOB_QUEUE': '1'}
    if not isinstance(request, dict):
        raise ValueError('invalid request')
    queue = request.get('operation') == 'queue' and set(request) == {'operation', 'agent'}
    if not queue:
        if set(request) != {'operation', 'agent', 'label', 'brief'} or request['operation'] != 'macjob':
            raise ValueError('invalid request')
        for key, rx in [('agent', r'[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}'), ('label', r'[A-Za-z0-9][A-Za-z0-9_-]{0,39}')]:
            if not isinstance(request[key], str) or not re.fullmatch(rx, request[key]) or '..' in request[key]:
                raise ValueError('invalid identity')
        brief = request['brief']
        if not isinstance(brief, str) or not brief.strip() or '\0' in brief or len(brief.encode()) > 65536:
            raise ValueError('invalid brief')
    life.supported()
    root = None if queue else home / 'work/swarmhub-jobs'
    if root is not None:
        root.mkdir(mode=0o700, parents=True, exist_ok=True)
    folder = None if queue else tempfile.mkdtemp(prefix=request['label'] + '-', dir=root)
    control_dir = Path(tempfile.mkdtemp(prefix='control-', dir=root))
    state = state_api.Capture(control_dir) if queue else state_api.State(control_dir / '.workload.json', create=True)
    relay = life.Relay(state.fd)
    relay.defer_stdout = queue
    result = Result()
    try:
        with tempfile.TemporaryFile() as stream:
            limit = QUEUE_LIMIT if queue else QUEUE_WAIT + RUN_LIMIT
            call_deadline = time.monotonic() + limit
            if queue:
                argv = [str(home / '.local/bin/sb-macjob'), 'queue', '--json']
            else:
                stream.write(brief.encode()); stream.seek(0)
                config = dict(token=state.token, identity=[state.directory, state.inode], deadline=call_deadline)
                argv = [str(home / '.local/bin/sb-macjob'), '--agent', request['agent'], '--label', request['label'],
                        '--workdir', folder, '--queue-wait', str(QUEUE_WAIT), '--', sys.executable, '-I', '-B',
                        str(Path(__file__).resolve()), '--workload', str(state.path), json.dumps(config),
                        str(home / '.local/bin/claude'), '-p', '--permission-mode', 'acceptEdits']
            try:
                result = execute(argv, limit, workload_control=None if queue else state.path,
                                 state=None if queue else state, relay=relay, call_deadline=call_deadline, stdin=stream,
                                 stdout=relay.files[0], stderr=relay.files[1], env=env)
            except LaunchRefused:
                raise OSError('runner launch refused') from None
            except Exception:
                result.fail('worker_execution_failed')
                _publish(state, 'cleanup-result.json', result)
        if queue and result.cleanup_complete and result.protocol_valid and result.returncode == 0:
            try:
                relay.queue_ready()
                relay.pump(time.monotonic() + .1)
                if relay.failed:
                    result.fail('output_transport_failed')
            except Exception:
                result.fail('invalid_queue_snapshot')
    finally:
        try:
            relay.close()
        except Exception:
            result.fail('output_transport_failed')
    code = _status(result)
    if result.cleanup_complete and result.protocol_valid:
        try:
            if folder:
                shutil.rmtree(folder)
            shutil.rmtree(control_dir)
        except Exception:
            result.reasons.add('artifact_cleanup_failed')
            _publish(state, 'cleanup-result.json', result)
            code = ARTIFACT_FAILED
    else:
        _publish(state, 'cleanup-result.json', result)
    try:
        state.close()
    except Exception:
        _diagnostic('evidence_close_failed')
        code = INCOMPLETE
    return code


def main():
    if len(sys.argv) > 4 and sys.argv[1] == '--workload':
        try:
            return _workload(sys.argv[2], sys.argv[4:], json.loads(sys.argv[3]))
        except Exception:
            print('Mac worker: supervisor incomplete', file=sys.stderr)
            return INCOMPLETE
    try:
        request = json.loads(sys.stdin.buffer.read(140000))
        return run(request)
    except (ValueError, OSError):
        print('Mac worker refused request', file=sys.stderr)
        return 2
    except Exception:
        print('Mac worker: cleanup incomplete', file=sys.stderr)
        return INCOMPLETE


if __name__ == '__main__':
    raise SystemExit(main())

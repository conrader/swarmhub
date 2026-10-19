#!/usr/bin/env python3
"""Stand-in for `codex`: plumbing checks of sim/mac-codex-tmp-smoke.sh, never real sandbox validation.

Like the argv-recording stubs in sim/test_fixes12.py it prints its argv and runs the work itself; it never contacts a
provider. It emulates the workspace-write sandbox's writable roots with permission bits: a probe target outside the
roots (cwd; /tmp unless exclude_slash_tmp; $TMPDIR unless exclude_tmpdir_env_var) is made read-only while
./smoke-probe.sh runs and restored afterwards. SMOKE_STUB_MODE (the script's --stub mode) selects a failure to
exercise: leaky ignores both exclusions (FAIL); timeout runs the whole probe, then hangs until the host's timeout
kills it (INCONCLUSIVE, though the control and completion files exist); leaky-timeout is both (FAIL, on the first
run); incomplete blocks the probe's completion marker (INCONCLUSIVE). stderr-only runs the full probe and emits
no stdout; missing-report/unchanged-report exercise the launcher's exit 65; cj-fail/cj-timeout fail only launcher
runs after the full probe. Otherwise, like `codex exec`, the stub exits 0 whatever the probe returns.
This says nothing about the real Codex sandbox; only the Mac run with the installed Codex does.
"""
import os
from pathlib import Path
import subprocess
import sys
import time

SLASH = 'sandbox_workspace_write.exclude_slash_tmp=true'
TMPDIR = 'sandbox_workspace_write.exclude_tmpdir_env_var=true'


def roots(argv):
    leaky = os.environ.get('SMOKE_STUB_MODE', '').startswith('leaky')
    found = [Path.cwd().resolve()]
    if leaky or SLASH not in argv:
        found.append(Path('/tmp').resolve())
    if os.environ.get('TMPDIR') and (leaky or TMPDIR not in argv):
        found.append(Path(os.environ['TMPDIR']).resolve())
    return found


def main(argv):
    if argv[:1] == ['--version']:
        print('codex-stub 0.0.0 (macsmoke1 argv-recording stub)')
        return 0
    if argv[:2] == ['login', 'status']:
        print('stub: Logged in')
        return 0
    if argv[:1] != ['exec']:
        print('stub: unsupported argv', argv, file=sys.stderr)
        return 2
    mode = os.environ.get('SMOKE_STUB_MODE', '')
    # Tool transcripts are stderr; only the final response is stdout. The old stub's argv and probe output
    # on stdout masked the launcher's empty-stdout condition, even when a real CLI only emitted diagnostics.
    print('stub argv: ' + ' '.join(repr(a) for a in argv), file=sys.stderr)
    if os.geteuid() == 0:
        print('stub: running as root, permission bits do not deny anything', file=sys.stderr)
    writable = roots(argv)
    changed = {}
    for line in Path('smoke-targets').read_text().splitlines():
        parts = line.split(' ', 3)
        if parts[0] != 'target' or len(parts) != 4:
            continue
        real = Path(parts[3]).resolve()
        if any(real == r or r in real.parents for r in writable):
            continue
        for path in (real / parts[2], real):
            if path.exists() and path not in changed:
                changed[path] = path.stat().st_mode & 0o7777
                path.chmod(changed[path] & ~0o222)
    report = Path(os.environ['SWARMHUB_REPORT_FILE']) if os.environ.get('SWARMHUB_REPORT_FILE') else None
    before = report.read_bytes() if report and report.is_file() else None
    if mode == 'incomplete':
        Path('smoke-done.txt').mkdir()  # the probe's last write fails; it still exits 0
    try:
        rc = subprocess.run(['sh', './smoke-probe.sh'], stdin=subprocess.DEVNULL, stdout=sys.stderr).returncode
    finally:
        for path, mode_bits in changed.items():
            path.chmod(mode_bits)
    print(f'stub: probe exit {rc}', file=sys.stderr, flush=True)
    if report and mode == 'missing-report':
        report.unlink(missing_ok=True)
    if report and mode == 'unchanged-report':
        assert before is not None, 'unchanged-report fixture needs a baseline'
        report.write_bytes(before)
    if mode != 'stderr-only':
        print('DONE', flush=True)
    if mode in ('timeout', 'leaky-timeout') or (mode == 'cj-timeout' and report):
        print('stub: probe finished; hanging until the timeout', file=sys.stderr, flush=True)
        time.sleep(3600)
    if mode == 'cj-fail' and report:
        return 7
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

# Macfix6 report

## Root cause

The macOS verification policy in `Resources/Skills/swarmhub-coding/scripts/verify-sandbox.py` denied executable mappings. It allowed `process*` and `file-read*`, but never `file-map-executable`. Seatbelt checks executable mappings separately from reads; dyld needs those mappings before `/bin/sh -c true` can execute. The same helper is called by standalone code-job and managed pattern replays, explaining why both groups fail before verification writes any files.

Apple's [WebKit macOS sandbox source](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/WebProcess/com.apple.WebProcess.sb.in) explicitly grants executable mapping permissions separately from file reads, including for system frameworks and dylibs.

The supplied Mac log records `verify-exit: 250`. The helper directly returns `subprocess.call`'s result through `sys.exit`. A child killed by SIGABRT produces Python status -6, and `sys.exit(-6)` becomes shell exit 250. That conversion was reproduced on Linux. Thus 250 is consistent with a loader abort before the verification command starts; it is not evidence that `true` returned 250. The original helper redirects verification diagnostics to a temporary file that code-job deletes, so the supplied log cannot prove the exact dyld denial or signal. Native macOS confirmation is still required.

There is no setsid/timeout/flock dependency in this verification path. Linux takes a different branch (Landlock/seccomp), so its successful tests did not exercise the incomplete Darwin policy.

## Changes

- Extracted the Darwin profile builder and granted read plus executable-map permission for the existing system runtime roots, the workspace, and the verifier's private temporary directory. Added the older `/private/var/db/dyld` cache location. System roots remain read-only.
- Granted metadata access only to exact ancestors and the `/etc`, `/tmp`, `/var` aliases so path resolution and physical cwd queries work with macOS symlinks. Ancestors do not gain content-read or write access.
- Preserved deny-by-default, network denial, scrubbed environment, workspace/private-temp write boundaries, and refusal when sandbox setup is unavailable. The Linux sandbox and POSIX code-job process management are unchanged.
- Fixed shell case 18's missing-verifier fixture: `./missing-verifier` is inside the allowed workspace. Its former absolute path was outside the workspace and could yield permission denied (126) rather than missing executable (127) on macOS. All expected statuses and assertions are retained.
- Added native verifier smoke coverage for `true`, a failing builtin, a workspace executable that writes a file and exits 3, and a missing workspace executable. Added a Linux-runnable check of the actual Darwin launch/profile that verifies executable mapping grants and host-file/write/network boundaries.

No Hermes files were changed. No commit was made. The pre-existing untracked `.json` file was left untouched.

## Verification on Linux

| Check | Result |
| --- | --- |
| `/bin/sh Tests/Scripts/code-job-test.sh Resources/Skills/swarmhub-coding/scripts/code-job` | 22 passed, 0 failed |
| `CODE_JOB_SH=/bin/dash /bin/dash Tests/Scripts/code-job-test.sh Resources/Skills/swarmhub-coding/scripts/code-job` | 22 passed, 0 failed |
| `cd sim && python3 -B -m unittest test_patterns` | 18 tests passed |
| `cd sim && python3 -B -m unittest test_fixes5.VerificationTests` | 8 tests passed |
| `cd sim && python3 -B -m unittest test_fixes5` | 19 tests passed, including sandbox boundary and managed runtime regressions |
| Full shell suite through restricted PATH wrappers, `/bin/sh` and `/bin/dash` | 22 passed per shell |
| New Darwin profile regression against the original helper from HEAD | Failed as expected at missing executable-map permission for `/bin/sh` |
| Same regression against the modified helper | Passed |
| `python3 -c 'import sys; sys.exit(-6)'` | Observed status 250, as expected |
| Shell syntax checks under `/bin/sh -n` and `/bin/dash -n` | Passed |
| `git diff --check` | Passed |

The restricted PATH experiment used temporary wrappers in `/tmp/macfix6-portable-5fjl_b8c`: each kept the case's synthetic CLI bin and a directory containing only required utilities (`awk basename cat chmod cp cut date dirname find git grep head ls mkdir mkfifo mktemp ps python3 rm rmdir sed sleep tail tee tr wc`). The wrappers asserted that `setsid`, `timeout`, and `flock` were unavailable before invoking the selected shell. The shipped scripts and shell assertions were unchanged for this experiment. This rules out those utility dependencies on Linux; it does not emulate Seatbelt.

The Darwin regression intercepts `subprocess.call` while running the shipped helper's real Darwin branch and inspects the resulting policy. It models separate read/map authorization, not the macOS kernel. Existing negative sandbox tests also passed with the real Linux sandbox: outside writes, secret reads, socket creation, and symlink escape remain denied, with a positive workspace-write control.

No Swift toolchain, macOS sandbox-exec, or macOS bash 3.2 is available here. No native macOS or Swift pass is claimed. Rerun the original Mac build/test command to confirm the loader startup fix on that machine.

## Diff

The complete code/test diff follows (this report is omitted).

```diff
diff --git a/Resources/Skills/swarmhub-coding/scripts/verify-sandbox.py b/Resources/Skills/swarmhub-coding/scripts/verify-sandbox.py
index 78039ce..a0e5f98 100644
--- a/Resources/Skills/swarmhub-coding/scripts/verify-sandbox.py
+++ b/Resources/Skills/swarmhub-coding/scripts/verify-sandbox.py
@@ -72,6 +72,29 @@ def linux(workspace, temporary):
         sec.seccomp_release(ctx)
 
 
+def darwin_profile(workspace, temporary):
+    quote = json.dumps
+    profile = '(version 1)(deny default)(allow process*)(allow sysctl-read)(allow mach-lookup)'
+    # Seatbelt treats executable mappings separately from file reads. Without
+    # this right dyld can abort before /bin/sh runs, even for the builtin true.
+    runtime = ('/usr', '/bin', '/sbin', '/System', '/Library', '/private/var/db/dyld')
+    writable = (str(workspace), temporary, os.path.realpath(temporary))
+    for path in runtime:
+        profile += '(allow file-read* file-map-executable (subpath ' + quote(path) + '))'
+    for path in ('/private/etc', '/dev'):
+        profile += '(allow file-read* (subpath ' + quote(path) + '))'
+    for path in writable:
+        profile += '(allow file-read* file-write* file-map-executable (subpath ' + quote(path) + '))'
+    # realpath/getcwd must be able to stat ancestors, including macOS /tmp and
+    # /var symlinks. Grant metadata on exact ancestors, not their other contents.
+    ancestors = {'/etc', '/tmp', '/var'}
+    for path in (*runtime, '/private/etc', '/dev', *writable):
+        ancestors.update(str(parent) for parent in Path(path).parents)
+    for path in sorted(ancestors):
+        profile += '(allow file-read-metadata (literal ' + quote(path) + '))'
+    return profile
+
+
 def main():
     workspace = Path(sys.argv[1]).resolve(strict=True)
     command = sys.argv[2]
@@ -81,12 +104,7 @@ def main():
                'LANG': 'C', 'PYTHONDONTWRITEBYTECODE': '1', 'GIT_CONFIG_GLOBAL': '/dev/null',
                'GIT_CONFIG_SYSTEM': '/dev/null'}
         if sys.platform == 'darwin':
-            quote = json.dumps
-            profile = '(version 1)(deny default)(allow process*)(allow sysctl-read)(allow mach-lookup)'
-            for path in ('/usr', '/bin', '/sbin', '/System', '/Library', '/private/etc', '/dev'):
-                profile += '(allow file-read* (subpath ' + quote(path) + '))'
-            for path in (str(workspace), temporary, os.path.realpath(temporary)):
-                profile += '(allow file-read* file-write* (subpath ' + quote(path) + '))'
+            profile = darwin_profile(workspace, temporary)
             return subprocess.call(['/usr/bin/sandbox-exec', '-p', profile, '/bin/sh', '-c', command], env=env, cwd=workspace)
         elif sys.platform == 'linux':
             # The standalone launcher is single-threaded; only its child receives irreversible restrictions.
diff --git a/Tests/Scripts/code-job-test.sh b/Tests/Scripts/code-job-test.sh
index 4e0d566..93638dc 100644
--- a/Tests/Scripts/code-job-test.sh
+++ b/Tests/Scripts/code-job-test.sh
@@ -346,7 +346,9 @@ expect "verify command recorded" [ "$(rec verify-command)" = 'exit 3' ]
 expect "evidence none" [ "$(rec evidence)" = none ]
 expect "verify exit on stderr" has "$C/err" "(verify exit 3)"
 # An unavailable verifier must still fail closed (the macOS /bin/true failure).
-CASE_VERIFY="$C/missing-verifier"; job --bot jarvis --order codex --dir "$C/work" -- "$TASK"; RC=$?; unset CASE_VERIFY
+# Keep the missing executable in the allowed workspace: this tests ENOENT (127),
+# not a sandbox refusal to inspect an executable outside it (126 on macOS sh).
+CASE_VERIFY='./missing-verifier'; job --bot jarvis --order codex --dir "$C/work" -- "$TASK"; RC=$?; unset CASE_VERIFY
 expect "missing verification: 66 (got $RC)" [ "$RC" -eq 66 ]
 expect "missing verify exit 127" [ "$(rec verify-exit)" = 127 ]
 expect "missing verify tests false" [ "$(rec tests-passed)" = false ]
diff --git a/sim/test_fixes5.py b/sim/test_fixes5.py
index bb8e2fd..8ed0cbf 100644
--- a/sim/test_fixes5.py
+++ b/sim/test_fixes5.py
@@ -4,6 +4,8 @@ import io
 import json
 import os
 from pathlib import Path
+import re
+import runpy
 import shlex
 import shutil
 import subprocess
@@ -36,6 +38,59 @@ class VerificationTests(unittest.TestCase):
                               env=dict(os.environ, QA_SECRET='synthetic-secret'),
                               capture_output=True, text=True, timeout=15)
 
+    def test_verifier_runs_builtins_and_workspace_executables_and_preserves_exit(self):
+        # Exercise dyld startup on macOS as well as exec and cwd after startup.
+        (self.repo / 'check').write_text('#!/bin/sh\nprintf checked > checked.txt\nexit 3\n')
+        (self.repo / 'check').chmod(0o755)
+        for command, expected in [('true', 0), ('exit 5', 5), ('./check', 3),
+                                  ('./missing-verifier', 127)]:
+            with self.subTest(command=command):
+                result = self.run_verify(command)
+                self.assertEqual(result.returncode, expected, result.stderr)
+        self.assertEqual((self.repo / 'checked.txt').read_text(), 'checked')
+
+    def test_darwin_launch_allows_executable_mappings_without_opening_host_files(self):
+        # Inspect the real Darwin launch on Linux too. This models the distinct
+        # Seatbelt read/map checks; it does not emulate the macOS kernel or dyld.
+        module = runpy.run_path(str(SANDBOX))
+        def launch(argv, *, env, cwd):
+            self.assertEqual(argv[:2], ['/usr/bin/sandbox-exec', '-p'])
+            self.assertEqual(argv[3:], ['/bin/sh', '-c', 'true'])
+            self.assertEqual(cwd, self.repo.resolve())
+            self.assertNotIn('QA_SECRET', env)
+            self.assertTrue(argv[2].startswith('(version 1)(deny default)'))
+            rules = re.findall(r'\(allow ([\w* -]+) \((subpath|literal) ("(?:[^"\\]|\\.)*")\)\)', argv[2])
+
+            def allowed(operation, path):
+                for operations, kind, quoted in rules:
+                    root = json.loads(quoted)
+                    if not any(operation == op or op.endswith('*') and operation.startswith(op[:-1])
+                               for op in operations.split()):
+                        continue
+                    if path == root or kind == 'subpath' and path.startswith(root.rstrip('/') + '/'):
+                        return True
+                return False
+
+            for path in ['/bin/sh', '/usr/lib/dyld', '/System/Library/dyld/dyld_shared_cache_arm64e',
+                         '/private/var/db/dyld/dyld_shared_cache_x86_64', str(cwd / 'check'),
+                         str(Path(env['TMPDIR']) / 'check')]:
+                self.assertTrue(allowed('file-read-data', path), path)
+                self.assertTrue(allowed('file-map-executable', path), path)
+            for parent in cwd.parents:
+                self.assertTrue(allowed('file-read-metadata', str(parent)), str(parent))
+            for path in [str(self.outside), '/Users/fixture/.ssh/id_rsa', '/private/tmp/unrelated']:
+                self.assertFalse(allowed('file-read-data', path), path)
+                self.assertFalse(allowed('file-write-data', path), path)
+            self.assertFalse(allowed('file-write-data', '/usr/lib/dyld'))
+            self.assertNotIn('(allow network', argv[2])
+            return 0
+
+        with patch.object(sys, 'argv', [str(SANDBOX), str(self.repo), 'true']), \
+             patch.object(sys, 'platform', 'darwin'), \
+             patch.object(subprocess, 'call', side_effect=launch) as call:
+            self.assertEqual(module['main'](), 0)
+            call.assert_called_once()
+
     def test_B1_outside_write_from_verify_command_is_denied(self):
         result = self.run_verify('printf executed > ' + shlex.quote(str(self.outside)))
         self.assertNotEqual(result.returncode, 0)
@@ -97,7 +152,6 @@ class VerificationTests(unittest.TestCase):
             self.assertFalse(self.outside.exists())
 
     def test_B1_missing_sandbox_fails_closed(self):
-        import runpy
         module = runpy.run_path(str(SANDBOX))
         with patch.object(sys, 'argv', [str(SANDBOX), str(self.repo), 'touch marker']), \
              patch.object(sys, 'platform', 'unsupported'):
```

# Macfix7 report

## Root cause and what macfix6 missed

The VERIFIED section of `/home/box/work/swarmhub/macfix7-brief.md` reports a real MacBook isolation test at 17:10 Warsaw: the macfix6 profile makes `sandbox-exec` of `/bin/sh -c true` abort with status 134. Adding exactly `(allow file-read* (literal "/"))` makes it exit 0. Additional grants for `/dev`, `/private/etc`, or `/private/var` did not fix startup.

Macfix6's executable-mapping grants were necessary but insufficient. Its ancestor rules already allowed `file-read-metadata` on the literal root, but lacked the root `file-read*` grant demonstrated necessary by that Mac experiment. The failure happened before the verification shell could run, explaining missing verifier output files and unverified jobs. A SIGABRT child produces Python subprocess status -6, which exits through the helper as shell status 250, consistent with the supplied Mac logs. The exact loader operation requiring root read was not traced here.

The starting worktree was `1fe6b76` on `swarmhub/peer-delivery`. Its shipped helper contains `darwin_profile` and macfix6's `file-map-executable` grants for runtime, workspace, and temporary roots. They are retained. The brief identifies Mac build `2ca2025` as the equivalent macfix6 tree; that Mac checkout was not accessible here. There were no half-done tracked macfix7 edits to discard. The pre-existing untracked `.json` file was left untouched.

## Changes

- Add the verified `(allow file-read* (literal "/"))` rule. It applies to the root directory itself, with no recursive root grant; host files outside the existing allowed roots remain unreadable.
- Add `(allow file-write* (literal "/dev/null"))` so verifier shell redirection to the null device can succeed. Other device paths do not gain write permission.
- Extend the existing Darwin-launch regression to require the exact literal-root rule, check root read permission, retain root write/map denial, check the null-device write exception, and retain host-file read/write denial checks, including a direct child of `/`.
- Extend the native verifier smoke test with `printf checked > /dev/null` on Darwin. Existing expected exit codes are unchanged.

All other policy grants, deny-by-default behavior, environment filtering, and Linux sandbox behavior are unchanged. No Hermes files were modified. No commit was made.

## Verification on the Linux box

| Command / check | Result |
| --- | --- |
| `/bin/sh Tests/Scripts/code-job-test.sh Resources/Skills/swarmhub-coding/scripts/code-job` | 22 passed, 0 failed |
| `CODE_JOB_SH=/bin/dash /bin/dash Tests/Scripts/code-job-test.sh Resources/Skills/swarmhub-coding/scripts/code-job` | 22 passed, 0 failed |
| `cd sim && python3 -B -m unittest test_patterns` | 18 passed |
| `cd sim && python3 -B -m unittest test_fixes5` | 19 passed |
| Darwin profile regression with literal-root read removed in memory | Failed as expected |
| Darwin profile regression with an additional recursive root-read grant in memory | Failed as expected at host-file read denial |
| Darwin profile regression with literal `/dev/null` write removed in memory | Failed as expected |
| `git diff --check` | Passed |

The mutation checks loaded the shipped helper with `runpy`, wrapped `darwin_profile` to alter only the returned profile, and ran the existing Darwin-launch regression through `unittest.TestResult`. Each variant produced exactly one expected assertion failure and no errors. No mutation was written to disk.

The Darwin policy assertions inspect the real Darwin branch with a mocked launcher; they do not emulate Seatbelt. The real Linux sandbox boundary checks also passed as part of `test_fixes5`, including denied host secret reads, outside writes, symlink escape, and socket creation. The added native `/dev/null` smoke subcase runs only on Darwin, so it was not executed on this box.

No Swift commands were run. Native macOS `sandbox-exec` and the full Swift build/test suite were not available here; the supplied VERIFIED Mac experiment is the native evidence for the root-read fix. Rerun the Mac build/tests to confirm the complete amended profile and null-device redirection on that machine.

## Full code/test diff

Relative to starting HEAD `1fe6b76`; this report itself is omitted.

```diff
diff --git a/Resources/Skills/swarmhub-coding/scripts/verify-sandbox.py b/Resources/Skills/swarmhub-coding/scripts/verify-sandbox.py
index a0e5f98..027d6e2 100644
--- a/Resources/Skills/swarmhub-coding/scripts/verify-sandbox.py
+++ b/Resources/Skills/swarmhub-coding/scripts/verify-sandbox.py
@@ -75,6 +75,10 @@ def linux(workspace, temporary):
 def darwin_profile(workspace, temporary):
     quote = json.dumps
     profile = '(version 1)(deny default)(allow process*)(allow sysctl-read)(allow mach-lookup)'
+    # dyld also needs to read the root directory itself before the shell starts.
+    # A literal rule grants no access to files below it.
+    profile += '(allow file-read* (literal "/"))'
+    profile += '(allow file-write* (literal "/dev/null"))'
     # Seatbelt treats executable mappings separately from file reads. Without
     # this right dyld can abort before /bin/sh runs, even for the builtin true.
     runtime = ('/usr', '/bin', '/sbin', '/System', '/Library', '/private/var/db/dyld')
diff --git a/sim/test_fixes5.py b/sim/test_fixes5.py
index 8ed0cbf..646d8c8 100644
--- a/sim/test_fixes5.py
+++ b/sim/test_fixes5.py
@@ -42,8 +42,10 @@ class VerificationTests(unittest.TestCase):
         # Exercise dyld startup on macOS as well as exec and cwd after startup.
         (self.repo / 'check').write_text('#!/bin/sh\nprintf checked > checked.txt\nexit 3\n')
         (self.repo / 'check').chmod(0o755)
-        for command, expected in [('true', 0), ('exit 5', 5), ('./check', 3),
-                                  ('./missing-verifier', 127)]:
+        commands = [('true', 0), ('exit 5', 5), ('./check', 3), ('./missing-verifier', 127)]
+        if sys.platform == 'darwin':
+            commands.append(('printf checked > /dev/null', 0))
+        for command, expected in commands:
             with self.subTest(command=command):
                 result = self.run_verify(command)
                 self.assertEqual(result.returncode, expected, result.stderr)
@@ -59,6 +61,7 @@ class VerificationTests(unittest.TestCase):
             self.assertEqual(cwd, self.repo.resolve())
             self.assertNotIn('QA_SECRET', env)
             self.assertTrue(argv[2].startswith('(version 1)(deny default)'))
+            self.assertIn('(allow file-read* (literal "/"))', argv[2])
             rules = re.findall(r'\(allow ([\w* -]+) \((subpath|literal) ("(?:[^"\\]|\\.)*")\)\)', argv[2])
 
             def allowed(operation, path):
@@ -71,6 +74,12 @@ class VerificationTests(unittest.TestCase):
                         return True
                 return False
 
+            self.assertTrue(allowed('file-read-data', '/'))
+            self.assertFalse(allowed('file-write-data', '/'))
+            self.assertFalse(allowed('file-map-executable', '/'))
+            self.assertTrue(allowed('file-write-data', '/dev/null'))
+            for path in ['/dev', '/dev/random', '/dev/tty']:
+                self.assertFalse(allowed('file-write-data', path), path)
             for path in ['/bin/sh', '/usr/lib/dyld', '/System/Library/dyld/dyld_shared_cache_arm64e',
                          '/private/var/db/dyld/dyld_shared_cache_x86_64', str(cwd / 'check'),
                          str(Path(env['TMPDIR']) / 'check')]:
@@ -78,7 +87,8 @@ class VerificationTests(unittest.TestCase):
                 self.assertTrue(allowed('file-map-executable', path), path)
             for parent in cwd.parents:
                 self.assertTrue(allowed('file-read-metadata', str(parent)), str(parent))
-            for path in [str(self.outside), '/Users/fixture/.ssh/id_rsa', '/private/tmp/unrelated']:
+            for path in [str(self.outside), '/Users/fixture/.ssh/id_rsa', '/private/tmp/unrelated',
+                         '/host-secret']:
                 self.assertFalse(allowed('file-read-data', path), path)
                 self.assertFalse(allowed('file-write-data', path), path)
             self.assertFalse(allowed('file-write-data', '/usr/lib/dyld'))
```

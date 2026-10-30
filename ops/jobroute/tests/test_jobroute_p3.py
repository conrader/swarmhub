"""Cross-review regressions: every symlink hop is part of executable trust.

Run only through run-sandbox.sh (sbtest user/PID namespace).
"""
from __future__ import annotations

import os
import shutil

import pytest

from test_jobroute import Env, STUB, submit
from test_jobroute_p2 import assert_trust_refusal, jobroute_trust, set_route


@pytest.mark.parametrize("kind", ["engine-file", "sb_codejob-file", "engine-directory",
                                  "sb_codejob-directory", "PATH-directory"])
@pytest.mark.parametrize("mode", [0o775, 0o777])
@pytest.mark.parametrize("relative", [False, True])
def test_intermediate_symlink_directory_is_refused_and_audited(tmp_path, kind, mode, relative):
    env = Env(tmp_path)
    real = tmp_path / "trusted-real"
    real.mkdir(mode=0o755)
    name = "sb-codejob" if kind.startswith("sb_codejob") else "claude"
    shutil.copyfile(STUB if name == "sb-codejob" else tmp_path / "bin/claude", real / name)
    (real / name).chmod(0o755)
    shared = tmp_path / "shared"
    shared.mkdir(mode=0o755)
    (shared / "middle").mkdir(mode=0o755)

    def link(path, target):
        path.symlink_to(os.path.relpath(target, path.parent) if relative else target)

    # The lexical entry and final target are trusted. Only an intermediate hop's
    # ancestor is writable; resolving straight to the final realpath hides it.
    target = real if kind.endswith("directory") else real / name
    link(tmp_path / "last-hop", target)
    link(shared / "middle/hop", tmp_path / "last-hop")
    link(tmp_path / "first-hop", shared / "middle/hop")
    if kind == "engine-file":
        (tmp_path / "bin/claude").unlink()
        link(tmp_path / "bin/claude", tmp_path / "first-hop")
    elif kind.startswith("sb_codejob"):
        link(tmp_path / "launcher", tmp_path / "first-hop")
        exe = tmp_path / "launcher" / name if kind.endswith("directory") else tmp_path / "launcher"
        set_route(env, f'sb_codejob = "{STUB}"', f'sb_codejob = "{exe}"')
    else:
        link(tmp_path / "tools", tmp_path / "first-hop")
        if kind == "engine-directory":
            set_route(env, 'claude = ["claude",', f'claude = ["{tmp_path}/tools/claude",')
        else:
            set_route(env, 'path = "', f'path = "{tmp_path}/tools:')
    shared.chmod(mode)
    rc, [out] = submit(env)
    assert_trust_refusal(env, rc, out, f"{shared} is group/world-writable")
    shared.chmod(0o755)
    rc, [out] = submit(env)
    assert rc == 0, out  # identical multi-hop chains work once every parent is trusted
    assert len(env.calls()) == 1


@pytest.mark.parametrize("mode", [0o775, 0o777])
def test_symlink_dotdot_target_checks_directory_before_leaving_it(tmp_path, mode):
    env = Env(tmp_path)
    shared = tmp_path / "shared"
    shared.mkdir(mode=mode)
    shared.chmod(mode)
    real = tmp_path / "real"
    real.mkdir(mode=0o755)
    shutil.move(tmp_path / "bin/claude", real / "claude")
    (tmp_path / "bin/claude").symlink_to("../shared/../real/claude")
    rc, [out] = submit(env)
    assert_trust_refusal(env, rc, out, f"{shared} is group/world-writable")
    shared.chmod(0o755)
    assert submit(env)[0] == 0


@pytest.mark.parametrize("optional", [False, True])
def test_symlink_loop_is_refused_and_audited(tmp_path, optional):
    env = Env(tmp_path)
    (tmp_path / "loop-a").symlink_to("loop-b")
    (tmp_path / "loop-b").symlink_to("loop-a")
    if optional:
        set_route(env, 'path = "', f'path = "{tmp_path}/loop-a:')
    else:
        set_route(env, f'sb_codejob = "{STUB}"', f'sb_codejob = "{tmp_path}/loop-a"')
    rc, [out] = submit(env)
    assert_trust_refusal(env, rc, out, "too many symlink hops")


@pytest.mark.parametrize("must_exist", [False, True])
def test_missing_symlink_target_still_checks_intermediate_parents(tmp_path, must_exist):
    shared = tmp_path / "shared"
    shared.mkdir(mode=0o775)
    shared.chmod(0o775)
    (shared / "hop").symlink_to(tmp_path / "missing")
    entry = tmp_path / "entry"
    entry.symlink_to(shared / "hop")
    assert jobroute_trust.chain_problem(str(entry), must_exist) == f"{shared} is group/world-writable"
    shared.chmod(0o755)
    problem = jobroute_trust.chain_problem(str(entry), must_exist)
    assert problem == (f"{tmp_path}/missing does not exist" if must_exist else None)


def test_intermediate_symlink_owner_is_checked(tmp_path):
    target = tmp_path / "target"
    target.write_text("trusted target")
    link = tmp_path / "link"
    link.symlink_to(target)
    me, anchor = jobroute_trust.owners()
    # Symlink modes are meaningless, but ownership matters in a root-owned sticky parent.
    assert jobroute_trust._entry_problem(str(link), link.lstat(), (me + 4242, anchor + 4242)) == (
        f"{link} is not owned by the route user or root")

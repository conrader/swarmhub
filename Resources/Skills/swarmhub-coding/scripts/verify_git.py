"""Repository authority captured by code-job BEFORE any coding tool runs.

Never run git (or its config/hooks) to discover grants. Standalone verification
without a snapshot permits only an ordinary in-workspace .git directory. External
metadata requires an explicit pre-tool snapshot, kept outside the workspace in
code-job's private directory. This shares code-job's trusted-launcher boundary.
"""
import json
import os
from pathlib import Path
import stat


def identity(path, directory=False):
    if path.is_symlink() or path.resolve(strict=True) != path:
        raise OSError('untrusted Git symlink: ' + str(path))
    info = path.stat()
    if not (stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode)):
        raise OSError('invalid Git metadata: ' + str(path))
    return [info.st_dev, info.st_ino]


def layout(workspace):
    """Validate normal repos and reciprocal linked-worktree metadata; pin roots/pointers.

    HEAD/config/objects may change with legitimate commits. Pointer bytes and their
    inode identities may not. No arbitrary separate-git-dir layouts are admitted.
    """
    workspace = Path(workspace).resolve(strict=True)
    dot = workspace / '.git'
    state = {'workspace': str(workspace), 'root': identity(workspace, True), 'paths': [], 'pins': {}}

    def pin(path, directory=False):
        value = identity(path, directory)
        if not directory:
            value += [path.read_text()]
        state['pins'][str(path)] = value
        return value[-1] if not directory else None

    def repo(path):
        pin(path, True)
        for name in ('objects', 'refs'):
            pin(path / name, True)
        for name in ('HEAD', 'config'):
            identity(path / name)
        if os.path.lexists(str(path / 'commondir')):
            raise OSError('unexpected Git commondir: ' + str(path))

    if not os.path.lexists(str(dot)):
        return state
    if dot.is_symlink():
        raise OSError('untrusted Git symlink: ' + str(dot))
    if dot.is_dir():
        repo(dot)
        return state
    pointer = pin(dot)
    if not pointer.startswith('gitdir: ') or len(pointer.splitlines()) != 1:
        raise OSError('invalid Git gitdir pointer')
    target = (workspace / pointer[8:].strip()).resolve(strict=True)
    pin(target, True)
    common = (target / pin(target / 'commondir').strip()).resolve(strict=True)
    if any(path == workspace or workspace in path.parents for path in (target, common)):
        raise OSError('linked Git metadata must be outside the writable workspace')
    repo(common)
    # Git registers linked worktrees ONLY as <common>/worktrees/<name>, with a
    # reciprocal gitdir file pointing at this workspace's .git file.
    pin(common / 'worktrees', True)
    if target.parent != common / 'worktrees' or common.name != '.git':
        raise OSError('untrusted Git linked-worktree roots')
    backlink = pin(target / 'gitdir').strip()
    # macOS commonly spells the same directory as /var and /private/var.
    if not Path(backlink).is_absolute() or Path(backlink).resolve(strict=True) != dot:
        raise OSError('untrusted Git worktree backlink')
    identity(target / 'HEAD')
    state['paths'] = [str(target), str(common)]
    return state


def capture(workspace, destination):
    workspace = Path(workspace).resolve(strict=True)
    destination = Path(destination).absolute()
    if workspace == destination.resolve() or workspace in destination.resolve().parents:
        raise OSError('Git trust snapshot must be outside the workspace')
    state = layout(workspace)
    with destination.open('x') as stream:
        json.dump(state, stream)


def validated_paths(workspace, snapshot=None):
    current = layout(workspace)
    if snapshot is None:
        if current['paths']:
            raise OSError('external Git metadata requires a trusted pre-tool snapshot')
    else:
        if current != snapshot:
            raise OSError('Git metadata roots or pointers changed since pre-tool capture')
    return [Path(path) for path in current['paths']]

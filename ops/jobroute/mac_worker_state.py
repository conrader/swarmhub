"""Private invocation state. Disk PGIDs are diagnostics, never signal authority."""
import errno
import fcntl
import json
import os
from pathlib import Path
import stat
import time
import uuid

VERSION = 3
CAP = 4096


def identity(st):
    return [st.st_dev, st.st_ino]


def acquire_until(fd, deadline):
    while time.monotonic() < deadline:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return
        except OSError as exc:
            if exc.errno not in (errno.EINTR, errno.EAGAIN, errno.EACCES):
                raise
        left = max(0, deadline - time.monotonic())
        if not left:
            break
        time.sleep(min(.02, left))
    raise TimeoutError('control lock expired')


def private(st, directory=False):
    kind = stat.S_ISDIR if directory else stat.S_ISREG
    if not kind(st.st_mode) or st.st_uid != os.geteuid() or st.st_mode & 0o077:
        raise ValueError('unsafe state')
    if not directory and st.st_nlink != 1:
        raise ValueError('linked state')


class State:
    def __init__(self, path, token=None, expected=None, create=False):
        self.path = Path(path)
        self.fd = os.open(str(self.path.parent), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        self.token = token or uuid.uuid4().hex
        self.expected = expected
        try:
            private(os.fstat(self.fd), True)
            self.directory = identity(os.fstat(self.fd))
            flags = os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK
            if create:
                flags |= os.O_CREAT | os.O_EXCL
            fd = os.open(self.path.name, flags, 0o600, dir_fd=self.fd)
            try:
                private(os.fstat(fd))
                self.inode = identity(os.fstat(fd))
                if expected is not None and expected != [self.directory, self.inode]:
                    raise ValueError('state replaced')
                if create:
                    self._write(fd, dict(version=VERSION, invocation=self.token, phase='queued',
                                         cancelled=False, pgid=None))
            except Exception:
                os.close(fd)
                raise
            self.control_fd = fd
        except Exception:
            os.close(self.fd)
            raise

    def close(self):
        os.close(self.control_fd)
        os.close(self.fd)

    def check(self):
        st = os.stat(self.path.parent, follow_symlinks=False)
        private(st, True)
        if identity(st) != self.directory:
            raise ValueError('directory replaced')
        st = os.stat(self.path.name, dir_fd=self.fd, follow_symlinks=False)
        private(st)
        if identity(st) != self.inode:
            raise ValueError('control replaced')

    def latched(self):
        # Any entry (including a dangling symlink/FIFO) means cancel; never follow/read it.
        try:
            os.stat('.cancel', dir_fd=self.fd, follow_symlinks=False)
            return True
        except FileNotFoundError:
            return False

    def latch(self):
        try:
            fd = os.open('.cancel', os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                         os.O_NOFOLLOW | os.O_NONBLOCK, 0o600, dir_fd=self.fd)
            os.close(fd)
        except FileExistsError:
            pass

    def validate(self, record):
        if not isinstance(record, dict) or set(record) != {
                'version', 'invocation', 'phase', 'cancelled', 'pgid'}:
            raise ValueError('invalid control schema')
        if type(record['version']) is not int or record['version'] != VERSION or record['invocation'] != self.token:
            raise ValueError('wrong invocation')
        if record['phase'] not in ('queued', 'launching', 'running', 'drained', 'cancelled'):
            raise ValueError('invalid phase')
        if type(record['cancelled']) is not bool:
            raise ValueError('invalid cancellation')
        pid = record['pgid']
        if record['phase'] == 'running':
            if type(pid) is not int or not 2 <= pid <= 2147483647 or pid == os.getpgrp():
                raise ValueError('invalid diagnostic pgid')
        elif pid is not None:
            raise ValueError('unexpected diagnostic pgid')
        return record

    @staticmethod
    def _write(fd, record):
        raw = json.dumps(record, separators=(',', ':')).encode()
        if len(raw) > CAP:
            raise ValueError('oversized state')
        os.lseek(fd, 0, os.SEEK_SET)
        if os.write(fd, raw) != len(raw):
            raise OSError('short state write')
        os.ftruncate(fd, len(raw))

    def locked(self, deadline, action):
        fd, acquired = None, False
        try:
            self.check()
            fd = os.open(self.path.name, os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=self.fd)
            st = os.fstat(fd)
            private(st)
            if identity(st) != self.inode or st.st_size > CAP:
                raise ValueError('invalid control file')
            acquire_until(fd, min(deadline, time.monotonic() + 1))
            acquired = True
            self.check()
            raw = os.pread(fd, CAP + 1, 0)
            if len(raw) > CAP:
                raise ValueError('oversized control')
            record = self.validate(json.loads(raw))
            return action(fd, record)
        finally:
            try:
                if acquired:
                    fcntl.flock(fd, fcntl.LOCK_UN)
            finally:
                if fd is not None:
                    os.close(fd)

    def read(self, deadline):
        return self.locked(deadline, lambda fd, record: record)

    def update(self, deadline, **changes):
        def edit(fd, record):
            changes['cancelled'] = record['cancelled'] or changes.get('cancelled', False)
            updated = self.validate(dict(record, **changes))
            self.check()
            self._write(fd, updated)
            return updated
        return self.locked(deadline, edit)

    def evidence(self, name, record=None):
        # Control corruption must not prevent a separate terminal receipt. Directory identity
        # still matters. Atomic receipts deliberately have a different inode than control.
        st = os.stat(self.path.parent, follow_symlinks=False)
        private(st, True)
        if identity(st) != self.directory:
            raise ValueError('directory replaced')
        if record is None:
            fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=self.fd)
            try:
                private(os.fstat(fd))
                raw = os.read(fd, CAP + 1)
                if len(raw) > CAP:
                    raise ValueError('oversized receipt')
                result = json.loads(raw)
                if not isinstance(result, dict) or result.get('version') != VERSION or result.get('invocation') != self.token:
                    raise ValueError('wrong receipt')
                return result
            finally:
                os.close(fd)
        if record.get('phase') != 'terminal':
            try:
                previous = self.evidence(name)
            except FileNotFoundError:
                previous = None
            if previous is not None and previous.get('phase') == 'terminal':
                raise ValueError('terminal evidence cannot regress')
        record = dict(record, version=VERSION, invocation=self.token)
        temp = '.receipt-' + uuid.uuid4().hex
        fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                     0o600, dir_fd=self.fd)
        try:
            self._write(fd, record)
            os.rename(temp, name, src_dir_fd=self.fd, dst_dir_fd=self.fd)
        finally:
            os.close(fd)
            try:
                os.unlink(temp, dir_fd=self.fd)
            except FileNotFoundError:
                pass


class Capture:
    """Queue snapshots need private capture/evidence, but no workload control or launch gate."""
    evidence = State.evidence

    def __init__(self, directory):
        self.path = Path(directory) / '.unused'
        self.token = uuid.uuid4().hex
        self.fd = os.open(str(directory), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        private(os.fstat(self.fd), True)
        self.directory = identity(os.fstat(self.fd))

    def close(self):
        os.close(self.fd)

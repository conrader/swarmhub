"""Read-only activation gate. Check on the profile box, never from a bot's self-report."""
import json
import os
from pathlib import Path
import pwd
import re
import stat


def inspect(profile, registry='/etc/swarmhub/bots.json', lookup=pwd.getpwuid, root=Path('/'), anchor=0):
    reg = Path(registry)
    for path in (reg, *reg.parents):
        st = path.lstat()
        if stat.S_ISLNK(st.st_mode) or st.st_uid not in (anchor, os.stat('/').st_uid) or (st.st_mode & 0o022 and not (stat.S_ISDIR(st.st_mode) and st.st_mode & stat.S_ISVTX and st.st_uid == os.stat('/').st_uid)):
            raise ValueError('untrusted registry')
    bots = json.loads(reg.read_text())['bots']
    bot = bots[profile]
    uid = bot['uid']
    if type(uid) is not int or uid <= 0 or sum(x['uid'] == uid for x in bots.values()) != 1:
        raise ValueError('dedicated uid required')
    user = lookup(uid)
    if not re.fullmatch(r'hb-[a-z0-9][a-z0-9-]{0,28}', user.pw_name) or user.pw_name != bot['user']:
        raise ValueError('account binding mismatch')
    home = root / user.pw_dir.lstrip('/')
    for path, mode, kind in ((home, 0o700, stat.S_ISDIR), (home / '.ssh', 0o700, stat.S_ISDIR),
                             (home / '.ssh/jobroute_ed25519', 0o600, stat.S_ISREG)):
        st = path.lstat()
        if not kind(st.st_mode) or st.st_uid != uid or stat.S_IMODE(st.st_mode) != mode:
            raise ValueError('private home/key ownership or mode mismatch')
    unit = root / 'etc/systemd/system/hermes-bot@.service'
    # Match the shipped template's account rule; drop-ins must be reviewed too.
    st = unit.lstat()
    if not stat.S_ISREG(st.st_mode) or st.st_uid != anchor or st.st_mode & 0o022:
        raise ValueError('untrusted unit')
    if not re.search(r'^User=hb-%i\s*$', unit.read_text(), re.M):
        raise ValueError('unit User mismatch')
    for folder in (root / 'etc/systemd/system/hermes-bot@.service.d',
                   root / f'etc/systemd/system/hermes-bot@{user.pw_name[3:]}.service.d'):
        if folder.exists():
            if folder.is_symlink(): raise ValueError('unit drop-in symlink')
            for path in [folder, *folder.rglob('*')]:
                st = path.lstat()
                if stat.S_ISLNK(st.st_mode) or st.st_uid != anchor or st.st_mode & 0o022:
                    raise ValueError('untrusted drop-in')
                if path.is_file() and re.search(r'^\s*User\s*=', path.read_text(), re.M):
                    raise ValueError('User override needs separate review')
    return {'ok': True, 'profile': profile, 'user': user.pw_name, 'uid': uid}

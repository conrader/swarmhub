"""Explicit runtime and repository grants for deny-by-default Seatbelt verification."""
import json
import os
from pathlib import Path

# Mach services a shell, Python, git and build tools need. Not the pasteboard, LaunchServices (`open`),
# AppleEvents (`osascript`), SecurityServer/keychain or preferences: those reach outside the sandbox.
DARWIN_MACH_SERVICES = ('com.apple.system.opendirectoryd.libinfo', 'com.apple.system.DirectoryService.libinfo_v1',
                        'com.apple.system.logger', 'com.apple.system.notification_center')
DARWIN_RUNTIME = ('/usr', '/bin', '/sbin', '/System', '/Library/Developer', '/Library/Frameworks', '/Library/Apple',
                  '/private/var/db/dyld', '/opt/homebrew', '/Applications/Xcode.app')


def darwin_profile(workspace, temporary, git_paths=()):
    quote = json.dumps
    profile = '(version 1)(deny default)(allow process*)(allow sysctl-read)(allow signal (target same-sandbox))'
    profile += '(allow ipc-posix-sem)(allow ipc-posix-shm*)'
    profile += '(allow mach-lookup' + ''.join(' (global-name ' + quote(s) + ')' for s in DARWIN_MACH_SERVICES) + ')'
    # dyld also needs to read the root directory itself before the shell starts.
    # A literal rule grants no access to files below it.
    profile += '(allow file-read* (literal "/"))'
    for path in ('/dev/null', '/dev/zero'):
        profile += '(allow file-write* (literal ' + quote(path) + '))'
    # Seatbelt treats executable mappings separately from file reads. Without
    # this right dyld can abort before /bin/sh runs, even for the builtin true.
    writable = (str(workspace), temporary, os.path.realpath(temporary))
    # The xcode-select shims read license state directly when cfprefsd is denied.
    selection = '/private/var/db/xcode_select_link'
    toolchain_files = ('/Library/Preferences/com.apple.dt.Xcode.plist',
                       '/Library/Preferences/com.apple.dt.CommandLineTools.plist', selection)
    for path in toolchain_files:
        profile += '(allow file-read* (literal ' + quote(path) + '))'
    selected = os.path.realpath(selection) if os.path.exists(selection) else None
    if selected:
        profile += '(allow file-read* file-map-executable (subpath ' + quote(selected) + '))'
    # Linked worktree gitdirs and commondir live outside the writable workspace.
    for path in git_paths:
        profile += '(allow file-read* (subpath ' + quote(str(path)) + '))'
    for path in DARWIN_RUNTIME:
        profile += '(allow file-read* file-map-executable (subpath ' + quote(path) + '))'
    for path in ('/private/etc', '/dev', '/private/var/db/xcode_select_link', '/private/var/select'):
        profile += '(allow file-read* (subpath ' + quote(path) + '))'
    for path in writable:
        profile += '(allow file-read* file-write* file-map-executable (subpath ' + quote(path) + '))'
    # realpath/getcwd must be able to stat ancestors, including macOS /tmp and
    # /var symlinks. Grant metadata on exact ancestors, not their other contents.
    ancestors = {'/etc', '/tmp', '/var', '/Library', '/Applications', '/opt'}
    for path in (*DARWIN_RUNTIME, '/private/etc', '/dev', *writable, *git_paths,
                 *toolchain_files, *([selected] if selected else [])):
        ancestors.update(str(parent) for parent in Path(path).parents)
    for path in sorted(ancestors):
        profile += '(allow file-read-metadata (literal ' + quote(path) + '))'
    # Later rules win: the repository metadata stays immutable (config, hooks, worktree gitdir).
    for path in (workspace / '.git', *git_paths):
        profile += '(deny file-write* (subpath ' + quote(str(path)) + '))'
        profile += '(deny file-write* (literal ' + quote(str(path)) + '))'
    return profile


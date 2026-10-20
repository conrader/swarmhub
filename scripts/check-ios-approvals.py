#!/usr/bin/env python3
"""P5d boundary check: no shared-key (v1 Bearer/HMAC) approval code reaches the iOS target.

The iOS target is every Swift file the generated Xcode project compiles plus the SwarmHubCore package it links.
Source mode (default, also an Xcode build phase) strips comments and fails on shared-key symbols. `--binary PATH`
scans a built executable for the same literals and for CryptoKit HMAC/SymmetricKey symbol references.
Exit 0 = clean, 1 = violations (listed), 2 = usage or layout error. Stdlib only; reads files, never writes.
"""
import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROJECT = Path('Apps/iOS/SwarmHub.xcodeproj/project.pbxproj')
APP_SOURCES = Path('Apps/iOS/Sources')
CORE_SOURCES = Path('Packages/SwarmHubCore/Sources')
CORE_PACKAGE = '../../Packages/SwarmHubCore'

# (label, regex) applied to Swift code with comments removed. String literals are kept: a v1 domain is a string.
BANNED = [
    ('CryptoKit HMAC', r'\bHMAC\b'),
    ('symmetric approval key', r'\bSymmetricKey\b'),
    ('HMAC verification', r'\b(?:isValidAuthenticationCode|authenticationCode|HashedAuthenticationCode)\b'),
    ('v1 signature domain', r'swarmhub-approval-v1'),
    ('v1 control endpoint', r'control/v1'),
    ('v1 signature header', r'X-SwarmHub-Signature'),
    ('Mac v1 client', r'\b(?:ManagedRemoteControl|requestForBox|ManagedLocalControl)\b'),
    ('local swarmctl path', r'\bswarmctl\b'),
]
# Literals that must not appear in a built iOS executable, and Swift-mangled CryptoKit types (module 9CryptoKit).
BINARY_BANNED = [b'swarmhub-approval-v1', b'X-SwarmHub-Signature', b'/swarmhub/control/v1/',
                 b'9CryptoKit4HMAC', b'9CryptoKit12SymmetricKey']
# iOS approval files must never read the Hermes key store or build a Hermes client.
APPROVAL_MARKERS = re.compile(r'\b(?:DeviceSignedApprovalClient|ManagedApprovalFlow|ManagedApprovalStore|DeviceApprovalIdentity)\b')
APPROVAL_FORBIDDEN = re.compile(r'\b(?:KeychainCredentials|HermesClient|credentials)\b')


def strip_comments(text):
    """Remove // and nested /* */ comments; keep string literals (single-line, multi-line and raw) intact."""
    out, i, n = [], 0, len(text)
    while i < n:
        if text.startswith('//', i):
            end = text.find('\n', i)
            i = n if end < 0 else end
        elif text.startswith('/*', i):
            depth, i = 1, i + 2
            while i < n and depth:
                if text.startswith('/*', i):
                    depth, i = depth + 1, i + 2
                elif text.startswith('*/', i):
                    depth, i = depth - 1, i + 2
                else:
                    if text[i] == '\n':
                        out.append('\n')
                    i += 1
        elif text[i] == '#' and re.match(r'#+"', text[i:]):
            hashes = len(re.match(r'#+', text[i:]).group())
            quote = '"""' if text.startswith('"""', i + hashes) else '"'
            close = quote + '#' * hashes
            end = text.find(close, i + hashes + len(quote))
            end = n if end < 0 else end + len(close)
            out.append(text[i:end]); i = end
        elif text.startswith('"""', i):
            end = text.find('"""', i + 3)
            end = n if end < 0 else end + 3
            out.append(text[i:end]); i = end
        elif text[i] == '"':
            j = i + 1
            while j < n and text[j] not in '"\n':
                j += 2 if text[j] == '\\' else 1
            out.append(text[i:j + 1]); i = j + 1
        else:
            out.append(text[i]); i += 1
    return ''.join(out)


def project_sources(root):
    """Swift paths compiled by the iOS target and its package references, from the generated project."""
    text = (root / PROJECT).read_text()
    swift = re.findall(r'lastKnownFileType = sourcecode\.swift; path = "([^"]+)";', text)
    packages = re.findall(r'XCLocalSwiftPackageReference; relativePath = ([^;]+);', text)
    return swift, [p.strip().strip('"') for p in packages]


def layout_problems(root):
    problems = []
    swift, packages = project_sources(root)
    expected = sorted(p.relative_to(root / 'Apps/iOS').as_posix() for p in (root / APP_SOURCES).glob('*.swift'))
    for path in swift:
        if not path.startswith('Sources/') or '..' in path or '/' in path[len('Sources/'):]:
            problems.append(f'{PROJECT}: compiles {path}, outside Apps/iOS/Sources')
    if sorted(swift) != expected:
        problems.append(f'{PROJECT}: compiled sources differ from Apps/iOS/Sources (run scripts/generate-ios-project.py)')
    if packages != [CORE_PACKAGE]:
        problems.append(f'{PROJECT}: package references {packages}, expected only {CORE_PACKAGE}')
    if 'check-ios-approvals.py' not in (root / PROJECT).read_text():
        problems.append(f'{PROJECT}: missing the approval boundary build phase')
    return problems


def source_problems(root):
    problems = []
    files = sorted((root / APP_SOURCES).glob('*.swift')) + sorted((root / CORE_SOURCES).rglob('*.swift'))
    for path in files:
        code = strip_comments(path.read_text())
        relative = path.relative_to(root).as_posix()
        for number, line in enumerate(code.split('\n'), 1):
            for label, pattern in BANNED:
                if re.search(pattern, line):
                    problems.append(f'{relative}:{number}: {label}: {line.strip()[:120]}')
        if path.parent == root / APP_SOURCES and APPROVAL_MARKERS.search(code):
            for number, line in enumerate(code.split('\n'), 1):
                if APPROVAL_FORBIDDEN.search(line):
                    problems.append(f'{relative}:{number}: approval code touches the Hermes key store: {line.strip()[:120]}')
    return problems


def binary_problems(path):
    data = Path(path).read_bytes()
    return [f'{path}: contains {token.decode()}' for token in BINARY_BANNED if token in data]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--root', type=Path, default=ROOT, help='repository root (default: this checkout)')
    parser.add_argument('--binary', action='append', default=[], help='also scan a built iOS executable')
    args = parser.parse_args(argv)
    root = args.root.resolve()
    if not (root / PROJECT).is_file() or not (root / APP_SOURCES).is_dir():
        print(f'check-ios-approvals: no iOS project under {root}', file=sys.stderr)
        return 2
    problems = layout_problems(root) + source_problems(root)
    for binary in args.binary:
        if not Path(binary).is_file():
            print(f'check-ios-approvals: no binary at {binary}', file=sys.stderr)
            return 2
        problems += binary_problems(binary)
    for problem in problems:
        print('error: ' + problem, file=sys.stderr)
    if problems:
        print(f'check-ios-approvals: {len(problems)} shared-key violation(s) in the iOS target', file=sys.stderr)
        return 1
    print('check-ios-approvals: iOS target has no shared-key approval path')
    return 0


if __name__ == '__main__':
    sys.exit(main())

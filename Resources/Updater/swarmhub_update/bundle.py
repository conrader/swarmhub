"""Verified bundles for the CLI (phase P2b): a staged folder, the stored latest bundle, and their contents.

A staged folder has the update service's layout (SCHEMAS.md §1), so pull (P3a) and the Mac transport (P4b) can fill
it the same way: `keys.json`, `channels/<channel>.json`, `bundles/<version>.json`, `blobs/sha256/<sha256>`, and
optionally `profiles.json` (swarmhub/profiles/1). Nothing here opens a network connection.

`run` checks, in SCHEMAS.md §10 order, with the effective floors (max(checkpoint, state), pins.py) and the pin
file's revoked key IDs. Staged mode picks a line as §6 does; when the line is the stored bundle's own version (a
fresher index for a bundle already started) it is a refresh, never a rollback. Stored mode re-verifies the stored
latest bundle (signatures, revocation, key and index expiry against the system clock, the line still present,
compatible and in rollout) before anything of it applies, because the state directory is bot-writable.

Component contents: a skill archive is extracted into the state work area and loaded exactly as the app loads a
bundled skill (render.load_skill); the manager template comes from the `manager-prompts` config component.
Stdlib only, Python 3.8+.
"""

from collections import namedtuple
import json
import os
import re
import shutil
import stat
import tempfile

from . import archive, render, verify

MANAGER_PROMPTS = "manager-prompts"
MANAGER_TEMPLATE = "manager-hermes.md"
LIMITS = verify.DEFAULT_LIMITS
ADVERTISED = "SwarmHub, v"
ADVERTISED_PATTERN = re.compile(r"SwarmHub, v(\d+\.\d+\.\d+)")

Verified = namedtuple("Verified", "version label manifest_sha256 manifest apply skipped blobs keys index manifest_raw "
                                  "refresh")


class ComponentError(ValueError):
    """A verified component cannot be installed on this box (wrong shape for its kind)."""


def read_file(path, limit):
    """Bytes of a regular file of at most `limit` bytes (no FIFO or device can block the updater)."""
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_CLOEXEC", 0))
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise OSError("%s is not a regular file" % path)
        chunks, total = [], 0
        while True:
            chunk = os.read(fd, 1 << 20)
            if not chunk:
                return b"".join(chunks)
            total += len(chunk)
            if total > limit:
                raise OSError("%s is larger than %d bytes" % (path, limit))
            chunks.append(chunk)
    finally:
        os.close(fd)


class Staged:
    """Readers over a staged folder with the service layout."""

    def __init__(self, folder, channel):
        self.folder, self.channel = folder, channel

    def keys(self):
        return read_file(os.path.join(self.folder, "keys.json"), LIMITS["max_signed_bytes"])

    def index(self):
        return read_file(os.path.join(self.folder, "channels", self.channel + ".json"), LIMITS["max_signed_bytes"])

    def manifest(self, line):
        return read_file(os.path.join(self.folder, "bundles", "%d.json" % line["bundle_version"]),
                         LIMITS["max_signed_bytes"])

    def blob(self, component):
        return read_file(os.path.join(self.folder, "blobs", "sha256", component["sha256"]), component["size"] + 1)

    def profiles(self):
        path = os.path.join(self.folder, "profiles.json")
        return json.loads(read_file(path, 65536).decode("utf-8")) if os.path.lexists(path) else None


def signed_version(raw, stage, member):
    return verify.parse_signed(raw, stage, LIMITS)["signed"][member]


def _staged_line(index, consumer, install_id, floors, stored):
    """§6 line selection. A line at the stored bundle's own version (same manifest) is a refresh."""
    trick = stored is not None and stored["bundle_version"] == floors["bundle_version"]
    lowered = dict(floors, bundle_version=floors["bundle_version"] - 1) if trick else floors
    try:
        line = verify.select_line(index, consumer, install_id, lowered)
    except verify.NoUpdate as outcome:
        if trick and outcome.reason == "already_applied":  # the highest line sits below the real floor
            raise verify.Reject("index", "bundle_rollback") from None
        raise
    if trick and line["bundle_version"] == stored["bundle_version"]:
        if line["manifest_sha256"] != stored["manifest_sha256"]:
            raise verify.Reject("index", "bundle_rollback")
        return line, True
    return line, False


def _stored_line(index, version, consumer, install_id):
    """The stored bundle's line in its index: still listed, compatible and including this box."""
    lines = [line for line in index["lines"] if line["bundle_version"] == version]
    if not lines:
        raise verify.Reject("index", "bundle_withdrawn")
    compatible = [line for line in lines if verify.satisfies(line["requires"], consumer)]
    if not compatible:
        raise verify.Reject("index", "no_compatible_line")
    for line in compatible:
        if verify.rollout_bucket(install_id, version) < line["rollout_percent"]:
            return line
    raise verify.NoUpdate("not_in_rollout")


def run(read_keys, read_index, read_manifest, read_blob, *, pins, floors, now, channel, consumer, install_id,
        stored=None, stored_version=None, progress=None):
    """Verify one bundle; returns Verified, raises verify.Reject / verify.NoUpdate (or OSError from a reader).
    `stored`: meta of the stored latest bundle (staged mode). `stored_version`: re-verify that version (stored mode).
    `progress` receives ("keys", raw, version) and ("index", raw, seq) as each stage passes, so the caller persists
    floors for the stages that verified even when a later one fails."""
    progress = progress if progress is not None else []
    keys = read_keys()
    release_keys = verify.verify_keys(keys, pins.doc, floors, LIMITS)
    progress.append(("keys", keys, signed_version(keys, "keys", "version")))
    index_raw = read_index()
    index = verify.verify_index(index_raw, release_keys, channel=channel, now=now, floors=floors,
                                revoked=pins.revoked, limits=LIMITS)
    progress.append(("index", index_raw, index["seq"]))
    if stored_version is None:
        line, refresh = _staged_line(index, consumer, install_id, floors, stored)
    else:
        line, refresh = _stored_line(index, stored_version, consumer, install_id), False
    manifest_raw = read_manifest(line)
    manifest = verify.verify_manifest(manifest_raw, line, release_keys, consumer=consumer, now=now,
                                      revoked=pins.revoked, limits=LIMITS)
    apply, skipped = verify.plan_components(manifest, consumer)
    blobs = {}
    for component in apply:
        verify.check_declared_size(component, LIMITS)
        blob = read_blob(component)
        verify.verify_blob(component, blob, LIMITS)
        blobs[component["name"]] = bytes(blob)
    return Verified(manifest["version"], manifest["label"], line["manifest_sha256"], manifest, apply, skipped, blobs,
                    keys, index_raw, manifest_raw, refresh)


# ---- contents ---------------------------------------------------------------------------------------------------

def _extract(work, component, blob):
    os.makedirs(work, 0o700, exist_ok=True)
    folder = tempfile.mkdtemp(prefix="component-", dir=work)
    target = os.path.join(folder, component["name"])
    try:
        archive.extract(blob, component["kind"], LIMITS, target)
    except (archive.ArchiveError, OSError) as error:
        shutil.rmtree(folder, ignore_errors=True)
        raise ComponentError("%s: archive does not extract (%s)" % (component["name"], error)) from None
    return folder, target


def load_skill(work, component, blob):
    """render.Skill for a verified skill component, loaded as SkillLibrary.bundled loads one. Its frontmatter
    version must be the component version and its description must advertise it ("SwarmHub, v<version>")."""
    name = component["name"]
    if component["path"] != name:
        raise ComponentError("%s: a skill installs at skills/swarmhub/%s, not %r" % (name, name, component["path"]))
    folder, _ = _extract(work, component, blob)
    try:
        skill = render.load_skill(folder, name, [] if name == render.MANAGER_SKILL else None)
    finally:
        shutil.rmtree(folder, ignore_errors=True)
    if skill is None:
        raise ComponentError("%s: not a loadable skill (SKILL.md name/version, file names or encoding)" % name)
    if skill.version != component["version"]:
        raise ComponentError("%s: SKILL.md version %s, component version %s" % (name, skill.version,
                                                                                component["version"]))
    try:
        description = render.frontmatter(skill.template.replace("{{VERSION}}", skill.version)).get("description", "")
    except render.RenderError as error:
        raise ComponentError("%s: %s" % (name, error)) from None
    if advertised_version(description) != skill.version:
        raise ComponentError("%s: SKILL.md description does not advertise %s%s" % (name, ADVERTISED, skill.version))
    return skill


def manager_template(work, component, blob):
    """The manager template text from a verified `manager-prompts` component."""
    folder, target = _extract(work, component, blob)
    try:
        return render._read_text(os.path.join(target, MANAGER_TEMPLATE))
    except (OSError, UnicodeDecodeError, render.RenderError) as error:
        raise ComponentError("%s: %s unreadable (%s)" % (component["name"], MANAGER_TEMPLATE, error)) from None
    finally:
        shutil.rmtree(folder, ignore_errors=True)


def advertised_version(description):
    """`SkillLibrary.advertisedVersion(in:)`: the version after "SwarmHub, v" (`\\d+\\.\\d+\\.\\d+`), else None."""
    match = ADVERTISED_PATTERN.search(description) if isinstance(description, str) else None
    return match.group(1) if match else None


def live_advertised(category, skill):
    """The version the live SKILL.md of `skill` advertises, or None."""
    try:
        text = render._read_text(os.path.join(category, skill, "SKILL.md"))
        return advertised_version(render.frontmatter(text).get("description", ""))
    except (OSError, UnicodeDecodeError, render.RenderError):
        return None

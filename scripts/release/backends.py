"""Ordered, fail-closed release uploads. No credentials or network are discovered implicitly.

Clients must provide atomic whole-object puts and strong read-after-write consistency.
Immutable puts MUST implement create-if-absent; mutable puts MUST compare the ETag
observed by get. A timeout is an error, never evidence that an object is absent.
"""

from dataclasses import dataclass
import hashlib
import re

IMMUTABLE_CACHE = "public, max-age=31536000, immutable"
MUTABLE_CACHE = "no-cache, max-age=0, must-revalidate"


OBJECT_PATH = re.compile(r"(?:blobs/sha256/[0-9a-f]{64}|bundles/[0-9]+\.json|keys\.json|"
                         r"channels/[A-Za-z0-9_-]+\.json)")


class BackendError(Exception):
    pass


@dataclass(frozen=True)
class Object:
    path: str
    data: bytes
    immutable: bool

    @property
    def cache_control(self):
        return IMMUTABLE_CACHE if self.immutable else MUTABLE_CACHE

    @property
    def content_type(self):
        return "application/json" if self.path.endswith(".json") else "application/octet-stream"


def ordered_objects(objects):
    """Enforce the backend boundary: known paths, immutable kinds and complete closure."""
    import jcs
    by_path = {}
    for obj in objects:
        if not OBJECT_PATH.fullmatch(obj.path) or obj.immutable != obj.path.startswith(("blobs/", "bundles/")):
            raise BackendError(f"invalid publish object: {obj.path}")
        if obj.path in by_path and by_path[obj.path] != obj:
            raise BackendError(f"duplicate object differs: {obj.path}")
        by_path[obj.path] = obj
    channels = [o for o in by_path.values() if o.path.startswith("channels/")]
    if len(channels) != 1 or "keys.json" not in by_path:
        raise BackendError("publication requires keys and exactly one channel index")
    for line in jcs.loads(channels[0].data)["signed"]["lines"]:
        manifest = by_path.get(f"bundles/{line['bundle_version']}.json")
        if manifest is None or hashlib.sha256(manifest.data).hexdigest() != line["manifest_sha256"]:
            raise BackendError("publication has a missing or mismatched bundle manifest")
        for component in jcs.loads(manifest.data)["signed"]["components"]:
            blob = by_path.get(f"blobs/sha256/{component['sha256']}")
            if (blob is None or len(blob.data) != component["size"] or
                    hashlib.sha256(blob.data).hexdigest() != component["sha256"]):
                raise BackendError("publication has a missing or mismatched blob")
    def rank(obj):
        return (0 if obj.path.startswith("blobs/") else 1 if obj.path.startswith("bundles/") else
                3 if obj.path.startswith("channels/") else 2, obj.path)
    return sorted(by_path.values(), key=rank)


class CompositeBackend:
    """Publish each destination completely; retries are safe if a later mirror fails."""

    def __init__(self, *backends):
        self.backends = backends

    def publish(self, objects):
        objects = ordered_objects(objects)
        return [backend.publish(objects) for backend in self.backends]


class ObjectStoreBackend:
    """Injectable S3 client: get(key) -> (bytes, ETag) or None; put as below.

    All immutable conflicts are detected before writing. Conditional writes close
    the check/put race. Every dependency is read back before publishing an index.
    """

    def __init__(self, client):
        self.client = client

    def publish(self, objects):
        objects = ordered_objects(objects)
        previous = {}
        for obj in objects:
            old = self.client.get(obj.path)
            previous[obj.path] = old
            if old and obj.immutable and old[0] != obj.data:
                raise BackendError(f"{obj.path}: immutable object differs; never overwritten")
            if old and obj.path == "keys.json" and old[0] != obj.data:
                import jcs
                if jcs.loads(old[0])["signed"]["version"] >= jcs.loads(obj.data)["signed"]["version"]:
                    raise BackendError("keys.json: remote key manifest version is not older")
            if old and obj.path.startswith("channels/") and old[0] != obj.data:
                # Avoid replaying a stale local channel onto a newer remote one.
                import jcs
                if jcs.loads(old[0])["signed"]["seq"] >= jcs.loads(obj.data)["signed"]["seq"]:
                    raise BackendError(f"{obj.path}: remote index seq is not older")
        written = []
        for obj in objects:
            old = previous[obj.path]
            if not old or old[0] != obj.data:
                self.client.put(obj.path, obj.data, cache_control=obj.cache_control,
                                content_type=obj.content_type, if_none_match=old is None,
                                if_match=old[1] if old else None)
                written.append(obj.path)
            actual = self.client.get(obj.path)
            if actual is None or actual[0] != obj.data:
                raise BackendError(f"{obj.path}: upload read-back differs or is missing")
        return written


def release_objects(repo, body, blobs, manifest_raw, index_raw, release_keys, issued):
    """Build a complete, verified dependency closure, including retained compatibility lines.

    This runs before any write. The index is always last; keys are metadata after
    all blobs and bundle manifests. No backend is allowed to reorder this list.
    """
    import publish
    import jcs
    from pathlib import Path

    repo = Path(repo)
    manifests, all_blobs = {}, {}
    for line in jcs.loads(index_raw)["signed"]["lines"]:
        version = line["bundle_version"]
        raw = manifest_raw if version == body["version"] else (repo / f"bundles/{version}.json").read_bytes()
        if hashlib.sha256(raw).hexdigest() != line["manifest_sha256"]:
            raise BackendError(f"bundles/{version}.json: index manifest hash differs")
        old_body = publish._check_signed_by(raw, "manifest", release_keys, "bundle", issued)
        if old_body["version"] != version:
            raise BackendError("index and manifest version differ")
        try:
            publish.p0b.check_dependencies(old_body)
        except publish.p0b.Reject as error:
            raise publish._reject(error) from error
        named = blobs if version == body["version"] else {
            c["name"]: (repo / f"blobs/sha256/{c['sha256']}").read_bytes() for c in old_body["components"]}
        publish.verify_blobs(old_body, named)
        for c in old_body["components"]:
            all_blobs[f"blobs/sha256/{c['sha256']}"] = named[c["name"]]
        manifests[f"bundles/{version}.json"] = raw
    return ([Object(path, data, True) for path, data in sorted(all_blobs.items())] +
            [Object(path, data, True) for path, data in sorted(manifests.items())] +
            [Object("keys.json", (repo / "keys.json").read_bytes(), False),
             Object(f"channels/{jcs.loads(index_raw)['signed']['channel']}.json", index_raw, False)])

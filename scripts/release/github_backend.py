"""GitHub Releases snapshot mirror; one release tag per bundle, never --clobber.

All assets remain in a draft until every dependency and channel is uploaded.
Asset names flatten '/' to '--'; cache-policy.json maps names back to paths and
records intended Cache-Control. GitHub controls HTTP response headers itself.
Dry-run records exact argv and materializes the original layout without running gh.
"""

import json
from pathlib import Path
import re
import subprocess
import tempfile

from backends import BackendError, OBJECT_PATH, ordered_objects


def materialize(assets_dir, output_dir):
    """Restore downloaded assets to a fresh directory for the unmodified P0b verifier.

    cache-policy.json is unsigned transport metadata. Allow only known paths;
    cryptographic trust still comes exclusively from P0b and pinned roots.
    """
    assets_dir, output_dir = Path(assets_dir), Path(output_dir)
    policy = json.loads((assets_dir / "cache-policy.json").read_text())
    entries = []
    for name, item in policy.items():
        path = item["path"]
        if not OBJECT_PATH.fullmatch(path) or name != path.replace("/", "--"):
            raise BackendError("unsafe mirror asset mapping")
        entries.append((path, (assets_dir / name).read_bytes()))
    output_dir.mkdir(parents=True, exist_ok=False)
    for path, data in entries:
        output = output_dir / path
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_bytes(data)


class GitHubBackend:
    def __init__(self, repository, tag, staging, *, dry_run=False, runner=None, calls_file=None):
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
            raise BackendError("GitHub repository must be owner/repo")
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", tag):
            raise BackendError("invalid GitHub release tag")
        self.repository, self.tag = repository, tag
        self.staging = Path(staging).resolve()
        self.staging.mkdir(parents=True, exist_ok=True)
        self.dry_run, self.runner = dry_run, runner or subprocess.run
        self.calls, self.calls_file = [], calls_file
        self.state_file = self.staging / "dry-run-state.json"
        if dry_run and self.state_file.exists():
            self.state = json.loads(self.state_file.read_text())
            if self.state["repository"] != repository or self.state["tag"] != tag:
                raise BackendError("dry-run staging directory belongs to another release")
        else:
            self.state = {"repository": repository, "tag": tag, "exists": False, "draft": True, "assets": []}

    def _save(self):
        if self.dry_run:
            self.state_file.write_text(json.dumps(self.state, indent=2) + "\n")

    def _call(self, *arguments):
        argv = ["gh", "release", *arguments, "--repo", self.repository]
        self.calls.append(argv)
        if self.calls_file:
            Path(self.calls_file).write_text(json.dumps(self.calls, indent=2) + "\n")
        if self.dry_run:
            return None
        return self.runner(argv, capture_output=True, text=True, check=False)

    def _must(self, *arguments):
        result = self._call(*arguments)
        if result is not None and result.returncode:
            raise BackendError(f"gh release {arguments[0]} failed: {result.stderr.strip()}")
        return result

    def _view(self):
        result = self._call("view", self.tag, "--json", "assets,isDraft")
        if result is not None:
            if result.returncode:
                if "release not found" not in result.stderr.lower() and "HTTP 404" not in result.stderr:
                    raise BackendError(f"gh release view failed: {result.stderr.strip()}")
                return False, True, set()
            doc = json.loads(result.stdout)
            return True, doc["isDraft"], {a["name"] for a in doc["assets"]}
        return self.state["exists"], self.state["draft"], set(self.state["assets"])

    def _read_asset(self, name):
        # Download into an empty directory so gh never overwrites a local file.
        with tempfile.TemporaryDirectory(dir=self.staging) as temp:
            self._must("download", self.tag, "--pattern", name, "--dir", temp)
            if self.dry_run:
                return (self.staging / "assets" / name).read_bytes()
            return (Path(temp) / name).read_bytes()

    def publish(self, objects):
        objects = ordered_objects(objects)
        assets = []
        policy = {}
        for obj in objects:
            if not OBJECT_PATH.fullmatch(obj.path):
                raise BackendError(f"unsupported mirror object path: {obj.path}")
            name = obj.path.replace("/", "--")
            assets.append((name, obj.data, obj.path))
            policy[name] = {"path": obj.path, "cache_control": obj.cache_control, "content_type": obj.content_type}
        # Metadata before the channel; the channel is always the last upload.
        assets.insert(len(assets) - 1, ("cache-policy.json", (json.dumps(policy, sort_keys=True) + "\n").encode(), None))
        exists, draft, names = self._view()
        pending = []
        for name, data, path in assets:
            if name in names:
                if self._read_asset(name) != data:
                    raise BackendError(f"{name}: immutable mirror asset differs; never overwritten")
            else:
                pending.append((name, data, path))
        if exists and not draft:
            if pending:
                raise BackendError("published mirror is immutable; use a fresh release tag")
            return []
        if not exists:
            self._must("create", self.tag, "--draft", "--title", self.tag, "--notes", "Signed update-service snapshot")
            self.state["exists"] = True
            self._save()
        for name, data, path in pending:
            staged = self.staging / "assets" / name
            staged.parent.mkdir(parents=True, exist_ok=True)
            staged.write_bytes(data)
            self._must("upload", self.tag, str(staged))
            if self.dry_run:
                self.state["assets"].append(name)
                self._save()
                if path:
                    output = self.staging / "layout" / path
                    output.parent.mkdir(parents=True, exist_ok=True)
                    output.write_bytes(data)
            # Check uploaded bytes, including blobs, before making the draft public.
            if self._read_asset(name) != data:
                raise BackendError(f"{name}: mirror read-back differs")
        self._must("edit", self.tag, "--draft=false")
        self.state["draft"] = False
        self._save()
        return [path for _, _, path in pending if path]


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="Restore downloaded mirror assets to the verifier layout")
    parser.add_argument("--materialize", type=Path, required=True, metavar="ASSETS_DIR")
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    materialize(args.materialize, args.out)

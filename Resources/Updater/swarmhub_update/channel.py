"""Channel subscription, origins and line selection for `swarmhub-update pull` (CORE-PLAN.md §2.1, §2.2, §3.1;
SCHEMAS.md §1, §6; phase P3a).

Subscription (config.json, local and bot-writable like the rest of the update state):

    channel        `stable` (default), `beta`, `canary`, or any `[a-z0-9-]{1,32}`; the index must name it
    origins        base URLs of the update service, primary first, then mirrors (https only)
    allow_hosts    extra https host names a redirect may reach (a mirror's download host); default none

The origins are not a trust anchor: everything fetched is verified against the admin-owned pins, floors and
checkpoint, so a wrong or hostile origin can withhold updates but not change what applies.

Layout under each origin (SCHEMAS.md §1): `keys.json`, `channels/<channel>.json`, `bundles/<version>.json`,
`blobs/sha256/<sha256>`. A pull fetches the key manifest and the index first, then only the manifest of the selected
line and the blobs of components targeted at the box and compatible with it, and nothing it already holds verified
(the stored manifest for a refresh, blobs in the state's blob store, which are hash-checked again when read).

Line selection and the rollout bucket are `verify.select_line` and `verify.rollout_bucket`, the implementation the
signed vectors pin, so the box and the vectors cannot disagree: keep the lines whose `requires` this box satisfies,
then those whose rollout includes it, `bucket = uint64_be(SHA-256(install_id + "\\n" + decimal(bundle_version))[0:8])
mod 100 < rollout_percent`, and take the highest `bundle_version`. The bucket depends only on the local random
`install_id` and the version, so the same box decides the same way on every run and no server state is needed.
`explain` reports that decision per line. Stdlib only, Python 3.8+.
"""

from . import bundle, compat, fetch, verify

LIMITS = bundle.LIMITS


def bucket(install_id, bundle_version):
    """The rollout bucket 0..99 (SCHEMAS.md §6)."""
    return verify.rollout_bucket(install_id, bundle_version)


def origins(values, allow_loopback_http=False):
    """Normalized origin base URLs from config.json `origins` or `--origin`; ValueError when malformed."""
    if values is None:
        return []
    if not isinstance(values, list) or not all(isinstance(v, str) and 0 < len(v) <= 2048 for v in values):
        raise ValueError("origins must be a list of URLs")
    result = []
    for value in values:
        try:
            url = fetch.normalize_origin(value, allow_loopback_http)
        except fetch.FetchError as error:
            raise ValueError(str(error)) from None
        if url not in result:
            result.append(url)
    return result


def allow_hosts(config):
    hosts = config.get("allow_hosts", [])
    if not isinstance(hosts, list) or not all(isinstance(h, str) and verify.KEY_ID.fullmatch(h) for h in hosts):
        raise ValueError("allow_hosts must be a list of host names")
    return hosts


def explain(index_raw, consumer, install_id):
    """Per line of a verified index: compatibility (unmet axes) and rollout (bucket vs percent). Read from the raw
    index the pull already verified; [] if it cannot be parsed."""
    try:
        lines = verify.parse_signed(index_raw, "index", LIMITS)["signed"]["lines"]
    except (verify.Reject, KeyError, TypeError):
        return []
    view = []
    for line in lines:
        try:
            axes, number = compat.unmet(line["requires"], consumer), bucket(install_id, line["bundle_version"])
            entry = {"bundle_version": line["bundle_version"], "rollout_percent": line["rollout_percent"],
                     "bucket": number, "in_rollout": number < line["rollout_percent"], "compatible": not axes}
        except (KeyError, TypeError, AttributeError):
            continue
        if axes:
            entry["incompatible"] = axes
        view.append(entry)
    return view


class Remote:
    """Readers over one origin with the service layout, for bundle.run. Prefers what the box already holds verified:
    the stored manifest when the line is the stored bundle itself, and blobs from the state's blob store."""

    def __init__(self, fetcher, base, channel, state, stored=None):
        self.fetcher, self.base, self.channel, self.state, self.stored = fetcher, base, channel, state, stored
        self.index_raw = None

    def keys(self):
        return self.fetcher.get(self.base + "keys.json", LIMITS["max_signed_bytes"])

    def index(self):
        self.index_raw = self.fetcher.get(self.base + "channels/%s.json" % self.channel, LIMITS["max_signed_bytes"])
        return self.index_raw

    def manifest(self, line):
        meta = self.stored[0] if self.stored else None
        if meta and meta["bundle_version"] == line["bundle_version"] \
                and meta["manifest_sha256"] == line["manifest_sha256"]:
            return self.stored[3]
        return self.fetcher.get(self.base + "bundles/%d.json" % line["bundle_version"], LIMITS["max_signed_bytes"])

    def blob(self, component):
        data = self.state.blob(component["sha256"])
        if data is not None:
            return data
        # one byte past the declared size, so a longer body is blob_size_mismatch, not a silent truncation
        return self.fetcher.get(self.base + "blobs/sha256/" + component["sha256"], component["size"] + 1)

    def profiles(self):
        return None  # the service is not per box: profiles come from the operator or the Mac

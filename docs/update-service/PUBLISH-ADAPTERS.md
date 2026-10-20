# P1c publish adapters

`publish.py` and `republish.py` retain their local `--repo` signing workspace and
accept `--backend local|s3|github|both`. `both` publishes S3 first, then the
GitHub mirror, using the same signed bytes. A failed mirror can be retried; the
primary already holds a complete release. They validate and sign locally with P0b before
any upload. No Hermes files, services, accounts, buckets or keys are created.

Every remote publication contains the dependency closure of **all** lines in the
new channel index, including older compatibility lines. Upload order is blobs,
bundle manifests, keys, then the channel index last. Each upload is read back.
Local state advances only after the remote publication succeeds. If the remote
succeeds and local disk writing fails, it already holds a complete release.
Keep the local workspace; it supplies version/sequence floors and old manifests.
Only one operator should publish from a local workspace at a time.

## Object store

Use `--backend s3 --s3-config /operator/path/config.json` in addition to the usual
publish arguments. That explicit JSON file supplies `endpoint` (HTTPS origin),
`bucket`, `region` (`auto` for an endpoint that requires it), `access_key`,
`secret_key`, and optionally `session_token` and a slash-delimited `prefix`.
Do not commit that file. There is no environment, AWS config, metadata service,
or SDK credential discovery. The stdlib SigV4 client uses path-style addressing,
never follows redirects, and fails on every response except a successful request
or a GET 404 (missing object). Tests inject an in-process client or opener and use
synthetic strings only; they never read that file or real credentials.

`ObjectStoreBackend(client)` also accepts an injected client with:

- `get(key)` returning `(bytes, ETag)` or `None` for absence;
- `put(key, bytes, cache_control=..., content_type=..., if_none_match=bool,
  if_match=ETag_or_None)` performing an atomic conditional write.

The endpoint must provide atomic conditional PUT and strong read-after-write
consistency. Immutable objects use `If-None-Match: *` on creation. Identical bytes
are skipped; differing bytes are refused before any writes. Mutable objects use
`If-Match` with the observed ETag, or `If-None-Match: *` on creation. Conflicts fail
closed and require a retry. An older/equal differing index or key manifest cannot
replace a newer remote one. Never delete dependencies as part of publishing.

CORE-PLAN.md does not assign server cache lifetimes. These are the choices:

| Objects | Cache-Control |
| --- | --- |
| `blobs/sha256/*`, `bundles/*.json` | `public, max-age=31536000, immutable` |
| `keys.json`, `channels/*.json` (the channel indexes) | `no-cache, max-age=0, must-revalidate` |

JSON objects use `application/json`; blobs use `application/octet-stream`.

## GitHub Releases mirror

Use a separate mirror repository and one unique tag per bundle publication:

```sh
python3 scripts/release/publish.py --backend github \
  --gh-repository TEST-owner/TEST-mirror --gh-tag bundle-1 \
  --gh-staging /tmp/mirror-1 --gh-dry-run --gh-calls /tmp/gh-calls.json \
  --repo LOCAL_REPO --pins PINS --build BUILD --version 1 \
  --signer file:TEST_RELEASE_KEY --channel stable \
  --issued 2026-10-20T12:00:00Z --expires 2026-10-27T12:00:00Z
```

With `--gh-dry-run`, no subprocess or network operation runs. The JSON log holds
exact argv, including staging/download paths, in execution order. Simulated release
state and uploaded assets live in `--gh-staging`; `layout/` holds the original
verifier layout. Keep a staging directory per repository/tag when resuming a dry
run. Dropping `--gh-dry-run` executes the same `gh release` commands. This is code
for P1d; no real upload has been tested or authorized in P1c.

The backend creates a **draft**, uploads and downloads/checks blobs, then manifests
and keys, then `cache-policy.json`, then the channel index. Only then does it mark
the draft public. It never invokes `--clobber`. Existing assets must match exactly;
published tags are immutable. A partial draft can be retried with the same tag.
A timeout after the final edit may mean publication succeeded, but dependencies
are complete in either case. A complete identical retry is a no-op.

GitHub assets cannot contain directory separators. `/` becomes `--` in asset
names; `cache-policy.json` maps names to original paths and intended cache headers.
**GitHub controls its download response Cache-Control; gh cannot set it.** The
policy file records the same choices as S3 for an operator-controlled mirror/CDN.
Exact response-header enforcement on GitHub itself is unavailable. Provisioning
that CDN or choosing the public mirror URL belongs to P1d and needs Konrad.

Download a release's assets into an empty directory using `gh release download`,
then restore the original layout without changing any signed or blob bytes:

```sh
python3 scripts/release/github_backend.py --materialize DOWNLOADED_ASSETS --out NEW_DIRECTORY
```

The path map is unsigned and is restricted to known safe object paths. P0b remains
the authority for signatures, sizes, hashes and archive rules. Tests compare full
P0b verdicts and blob bytes for box, Mac and iOS against the local publication.

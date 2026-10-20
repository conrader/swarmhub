# Update service wire contracts (P0a)

Status: contract for plan B (`CORE-PLAN.md` §2.1, §3.1, §6; phase P0a in `CORE-PHASES.md`). Swift (P0c) and Python (P0b) verifiers implement exactly this. The executable reference is `scripts/release/reference_verify.py` with `schemas.py`, `jcs.py` and `ustar.py`; the vectors are in `Tests/Fixtures/release-bundles/`. Nothing here is deployed. All keys in the fixtures are TEST keys.

## 1. Objects

| Object | Path on the service | Signed by | `schema` |
| --- | --- | --- | --- |
| Key manifest | `keys.json` | root keys (threshold from the consumer's pins) | `swarmhub/keys/1` |
| Channel index | `channels/<channel>.json` | release key with role `index` | `swarmhub/index/1` |
| Bundle manifest | `bundles/<version>.json` | release key with role `bundle` | `swarmhub/bundle/1` |
| Blob (component archive) | `blobs/sha256/<sha256>` | none; pinned by the manifest's `sha256` and `size` | n/a |

Consumers also hold a local **pin file** (`swarmhub/pins/1`), compiled into the apps and installed on boxes by the operator bootstrap (§3.5 of the plan). It is never fetched.

## 2. Canonical JSON (JCS profile)

Signatures cover RFC 8785 (JCS) canonical bytes. Signed objects use a restricted profile, so JCS needs no number formatting:

- **No floating-point numbers.** Any number with a fraction or exponent (`1.0`, `1e3`) is rejected, as are `NaN`/`Infinity`. Integers must satisfy |n| ≤ 2^53 − 1; `-0` is rejected. Versions, `seq`, `size` and `rollout_percent` are integers; component versions are strings (§7).
- **No `null`.** Optional members are omitted, never null.
- **Member names are ASCII** and unique (duplicate names are rejected at parse time). With ASCII names, JCS's UTF-16 code-unit order equals plain byte order.
- **Strings** are UTF-8 without a byte-order mark, no lone surrogates. Canonical escaping (JCS §3.2.2.2): `"` → `\"`, `\` → `\\`, U+0008/0009/000A/000C/000D → `\b \t \n \f \r`, other U+0000–001F → `\u00xx` (lowercase hex). Everything else is literal UTF-8, including `/`, U+007F and non-ASCII.
- **Canonical form:** members sorted by name, arrays in order, no whitespace, `true`/`false` literal.
- Nesting depth ≤ 32. A signed file is at most `max_signed_bytes` (default 1 MiB).

Every signed file on the service is written as the canonical bytes of its whole envelope, but verifiers must not depend on that: they parse the file, then canonicalize `signed` to check the signature. The JCS vectors in `vectors.json` (`jcs`) pin both accepted inputs (with expected canonical text) and rejected inputs.

## 3. Envelope and signature

```json
{"signatures":[{"key_id":"TEST-release-1","sig":"<128 lowercase hex>"}],"signed":{ ... }}
```

- The envelope has exactly the members `signed` (an object) and `signatures` (a non-empty array of `{key_id, sig}`); anything else is `schema_invalid`, because the envelope itself is not signed.
- Index and bundle manifests carry **exactly one** signature. Key manifests carry one or more.
- Message signed: the ASCII bytes `swarmhub-signature/1` followed by one LF (`0x0A`), then `JCS(signed)`. Algorithm: Ed25519 (RFC 8032, pure, no prehash). Verifiers reject S ≥ L and points that do not decode.
- Hex is lowercase everywhere: public keys (64), signatures (128), SHA-256 digests (64).
- Timestamps are UTC strings `YYYY-MM-DDTHH:MM:SSZ` (exactly this form, no fractions or offsets). Because the form is fixed, string order equals time order. Expiry comparisons are strict: a key or index is valid while `now < not_after` / `now < expires`.
- Unknown members inside `signed` are ignored by `/1` verifiers (they are covered by the signature, and schema `/1` grows additively). Missing or mistyped known members are `schema_invalid`, whatever their shape (for example `roles: [{}]`, `targets: [{}]`, `kind: []`): a verifier returns the verdict and never crashes.
- Every pattern in this document (`[A-Za-z0-9._-]{1,64}`, path segments, versions, timestamps, …) must match the **whole** string. A value with a trailing newline or any other control character does not match.

## 4. Pins (local, unsigned)

`{"schema":"swarmhub/pins/1","threshold":1,"roots":[{"key_id","ed25519_pub"}, ...]}`. `threshold` is between 1 and the number of roots; plan B uses 1 of 2. The floors checkpoint and revoked key IDs (plan §3.2) live in the same protected file on boxes, as the optional members `"checkpoint": {"min_keys_version", "min_index_seq", "min_bundle_version"}` (non-negative integers, absent = 0) and `"revoked_key_ids": [key_id, ...]`; any other member except `note` makes the box updater refuse the file (`docs/update-service/UPDATER.md`). Vectors pass them as the inputs `floors` and `revoked_key_ids` (the effective floor is max(checkpoint, state), computed by the caller).

## 5. Key manifest (`swarmhub/keys/1`)

| Member | Type | Rule |
| --- | --- | --- |
| `version` | int ≥ 1 | Monotonic. Below the persisted floor → `keys_rollback`. |
| `issued` | timestamp | |
| `keys` | non-empty array | `{key_id, ed25519_pub, roles, not_after}`; `key_id` matches `[A-Za-z0-9._-]{1,64}` and is unique; `roles` is a non-empty set of `bundle`, `index`. |

Valid only when every signature is from a distinct pinned root and verifies, and their number reaches the pin threshold. A signature by a non-root key → `keys_untrusted`; one that fails → `keys_bad_signature`; too few → `keys_threshold`.

## 6. Channel index (`swarmhub/index/1`)

| Member | Type | Rule |
| --- | --- | --- |
| `channel` | string `[a-z0-9-]{1,32}` | Must equal the consumer's subscription (`channel_mismatch`). |
| `seq` | int ≥ 1 | Monotonic. Below the floor → `index_rollback`. |
| `issued`, `expires` | timestamps | `now ≥ expires` → `index_expired` (consumer keeps its last good bundle and reports "stale"). |
| `lines` | array | Each `{requires, bundle_version (int ≥ 1), manifest_sha256, rollout_percent (int 0–100)}`. |

**Line selection.** Keep lines whose `requires` the consumer satisfies (§8); none → `no_compatible_line`. Of those, keep lines whose rollout includes the consumer; none → verdict `no_update` / `not_in_rollout`. Take the highest `bundle_version`. Below the applied-bundle floor → `bundle_rollback`; equal → `no_update` / `already_applied`. The floor advances when a bundle verifies and its apply starts, even if its code components are still waiting for the local confirm (decision 2); the confirm then applies that same verified bundle's code from updater state (P2b), so a lower bundle can never be re-offered to fill the gap.

**Rollout bucket.** `bucket = uint64_be(SHA-256(UTF-8(install_id + "\n" + decimal(bundle_version)))[0:8]) mod 100`; the line includes the consumer when `bucket < rollout_percent`. `install_id` is random and local.

## 7. Bundle manifest (`swarmhub/bundle/1`) and components

| Member | Type | Rule |
| --- | --- | --- |
| `version` | int ≥ 1 | Must equal the index line's `bundle_version` (`version_mismatch`). |
| `label` | string | Display only (`2026.10.3`). |
| `created` | timestamp | |
| `code_bearing` | bool | True exactly when some component has class `code` (`code_bearing_mismatch`). |
| `requires` | requires map | Unsatisfied → `incompatible_requires` (whole bundle refused). |
| `components` | non-empty array | Names unique. |

The manifest file's SHA-256 (raw bytes as served) must equal the line's `manifest_sha256` before it is parsed (`manifest_hash_mismatch`).

**Component:** `{kind, class, name, version, targets, sha256, size, path, requires, requires_component}`.

- `kind`: `skill`, `tool`, `config` (settings, policy defaults, prompts, copy, flags) or `ui` (view documents).
- `class`: `data` or `code`; the unit of apply under decision 2 (plan §2.3 and "Decision (Oct 20, 2026)" item 2). Metadata rules (`class_mismatch`): `tool` is always `code`; `config` and `ui` are always `data`; `skill` is either. Content rule (`class_mismatch`, checked per fetched archive): content needs `code` when any file has mode 0755 or an extension outside the kind's data list — `skill`: `.md`; `config`: `.json`, `.md`, `.txt`; `ui`: `.json`. The extension is the last path segment from its last `.`, when that dot is neither the segment's first nor last character (`..md` → `.md`; `.md` and `notes.` have none). A skill with scripts is therefore `code` as a whole, SKILL.md included.
- `targets`: non-empty set of `box`, `mac`, `ios`. `skill`, `tool` and every `code` component target exactly `["box"]` (`target_invalid`): apps never consume code.
- `name`: `[a-z0-9][a-z0-9._-]{0,63}`. `version`: 1–4 dot-separated non-negative integers without leading zeros (`1.3.12`). `path`: install directory relative to the consumer's component root; segments `[A-Za-z0-9._-]+`, not `.` or `..` (as `SkillLibrary.isSafeRelativePath`).
- `sha256`, `size`: of the blob. `requires`: requires map; unsatisfied → the component is **skipped** with reason `incompatible` and the consumer keeps its previous version of it.
- `requires_component`: array of `{name, min_version}` naming other components **in the same bundle** (bundles are complete snapshots). The named component must exist, have `version ≥ min_version`, not be the component itself, and target at least every target of the dependent component; otherwise `dependency_invalid`. A component whose dependency is skipped is skipped too (`dependency_skipped`), transitively. The apply policy uses the same edges: a data component that depends on a code component the box has not applied waits for that code's local confirm (plan decision 2, dependency rule). That waiting is updater state (P2b), not a verifier verdict.

## 8. Requires maps and axes

A requires map is an object from axis name (`[a-z_]{1,32}`) to a constraint: one or more comma-separated clauses `>=V`, `<V` or `==V`, where V is a version as in §7. Versions compare numerically per segment, missing segments count as 0 (`0.21` = `0.21.0`).

| Platform | Axes it evaluates |
| --- | --- |
| `box` | `updater`, `hermes` |
| `mac`, `ios` | `app`, `ui_catalog`, `config_schema` |

A consumer evaluates only the axes of its platform and ignores the others, so one map can serve both. An axis no platform knows is unsatisfiable (fail closed). An axis of the consumer's platform with no known value (for example Hermes version unreadable) is unsatisfied, so the component is skipped (P3a).

## 9. Archives

- **Format:** POSIX ustar, uncompressed. Each header has magic `ustar\0`, version `00` and a valid checksum; the archive ends with two zero blocks, followed by nothing but zero bytes. Anything else → `archive_malformed`. The fixtures use mtime 0, uid/gid 0 and empty owner names, but verifiers do not require that.
- **Entries:** regular files (`0`) and directories (`5`) only. Hard links and symlinks (`1`, `2`) → `archive_link`; character/block devices and FIFOs (`3`, `4`, `6`) → `archive_special_file`; any other type (pax, GNU long names, …) → `archive_unsupported_entry`.
- **Paths:** `prefix/name` joined by `/`; one trailing `/` allowed on directories. Relative, segments `[A-Za-z0-9._-]+`, never `.` or `..`, at most `max_path_bytes` bytes and `max_depth` segments; else `archive_unsafe_path`. A path listed twice → `archive_duplicate_path`; a file used as a parent of another entry → `archive_path_conflict`.
- **Modes:** files 0644 or 0755, directories 0755, nothing else (no setuid/setgid/sticky, no group/world write) → `archive_bad_mode`.
- **Sizes:** declared component `size` above `max_blob_size` → `archive_oversize` (checked before download). Blob length ≠ `size` → `blob_size_mismatch`, then SHA-256 ≠ `sha256` → `blob_hash_mismatch`. More than `max_entries` entries, a file above `max_file_size`, or files totalling above `max_total_size` → `archive_oversize`.

Default limits (vectors carry them in `inputs.limits`; some cases lower one): `max_signed_bytes` 1 MiB, `max_blob_size` 64 MiB, `max_entries` 4096, `max_file_size` 8 MiB, `max_total_size` 64 MiB, `max_path_bytes` 255, `max_depth` 16.

## 10. Verification order and verdicts

The first failing check decides. Each check belongs to a stage; a reject leaves the consumer on its last good bundle (plan §3.1).

| Stage | Order of checks → reason |
| --- | --- |
| `pins` | parse + shape → `schema_invalid` |
| `keys` | size, parse (profile JSON), envelope, schema → `schema_invalid`; each signature: pinned root → `keys_untrusted`, verifies → `keys_bad_signature`; count → `keys_threshold`; `version` vs floor → `keys_rollback` |
| `index` | size, parse, envelope, schema → `schema_invalid`; signing key: revoked → `key_revoked`, listed → `unknown_key`, role `index` → `key_wrong_role`, `now < not_after` → `key_expired`, signature → `bad_signature`; `seq` → `index_rollback`; channel → `channel_mismatch`; expiry → `index_expired`; line selection → `no_compatible_line` / `not_in_rollout` / `bundle_rollback` / `already_applied` |
| `manifest` | raw SHA-256 → `manifest_hash_mismatch`; size, parse, envelope, schema → `schema_invalid`; class metadata → `class_mismatch`; flag → `code_bearing_mismatch`; targets → `target_invalid`; signing key as for the index but role `bundle`; `version` → `version_mismatch`; bundle `requires` → `incompatible_requires`; dependencies → `dependency_invalid` |
| `component` | for each component targeted at this consumer, in manifest order, after skipping `incompatible` / `dependency_skipped` ones: `max_blob_size` → `archive_oversize`; `blob_size_mismatch`; `blob_hash_mismatch`; archive rules (§9); content class → `class_mismatch` |

Verdicts: `accept` (with `bundle_version`, `apply` = component names in manifest order, `skipped` = `[{name, reason}]`), `no_update` (`not_in_rollout`, `already_applied`) or `reject` (stage + reason). Schema checks run before signature checks, so a malformed signed object is `schema_invalid` even when its signature would fail.

## 11. Test vectors

`Tests/Fixtures/release-bundles/` mirrors the service layout: `keys/` (key manifests, `pins.json`, `pins--threshold-2.json`, and `TEST-keys.json` listing each TEST key's public seed), `channels/`, `bundles/`, `blobs/sha256/`. Variant files carry a `--<case>` suffix. `vectors.json` holds `jcs` (canonicalization vectors) and `cases` (currently 54 cases: 6 `accept`, 2 `no_update`, 46 `reject`; 16 JCS vectors); each case has `id`, `description`, fully explicit `inputs` (`pins`, `keys`, `index`, `manifest` paths, `channel`, `now`, `floors`, `consumer` `{platform, versions}`, `install_id`, `revoked_key_ids`, `limits`) and `expect` (the verdict above).

Keys come from public fixed seeds: `seed = SHA-256(UTF-8("swarmhub-release-vectors/TEST-seed/" + key_id))`. Every `key_id` starts with `TEST-`; release builds must reject them (P2c).

```
python3 scripts/release/make_vectors.py            # rewrite keys/ channels/ bundles/ blobs/ vectors.json
python3 scripts/release/make_vectors.py --check    # regenerate in a temp dir; exit 1 on any byte difference
python3 scripts/test_release_vectors.py            # byte-identical regeneration + every expected verdict
```

The generator is stdlib-only (pure-Python Ed25519 in `scripts/release/ed25519_ref.py`, for TEST keys only, cross-checked against `cryptography` and RFC 8032 when that package is installed).

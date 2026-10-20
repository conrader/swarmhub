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

`{"schema":"swarmhub/pins/1","threshold":1,"roots":[{"key_id","ed25519_pub"}, ...]}`. `threshold` is between 1 and the number of roots; plan B uses 1 of 2. The floors checkpoint and revoked key IDs (plan §3.2) live in the same protected file on boxes; vectors pass them as the inputs `floors` and `revoked_key_ids` (the effective floor is max(checkpoint, state), computed by the caller).

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

## 12. App config documents (P6a)

What a `config` component means to the apps (`config.policy`, `config.prompts`, `config.copy`, `config.flags`; plan §1.2, §3.3, §4). Implemented by `ConfigDecoder.swift` / `ConfigStore.swift` in SwarmHubCore; the Python statement is `scripts/release/config_reference.py`. The apps read only the `config` components of the current verified bundle (the store holds only data components targeted at the app). Every key an app reads has a compiled default, which is what the app does today; with no bundle, or a host that cannot be reached, every read is that default.

**Documents.** In each component, only regular files at the archive root named `policy.json`, `prompts.json`, `copy.json` and `flags.json` are documents; every other file (box prompt sources, notes, `nested/policy.json`) is ignored by apps. When two components carry the same document, neither is used and that domain stays compiled (`duplicate_document`, one report per component). A component that fails the archive rules (§9) or whose content is not data is refused whole, with the §9 reason or `component_not_data`; a stored copy that no longer matches its record is `component_unreadable`.

A document is at most 262144 bytes (`config_too_large`), parses under the §2 profile (no floats, no `null`, no duplicate names; else `config_invalid`), and is an object whose `schema` is exactly `swarmhub/config-<domain>/1` (else `schema_invalid`). `note` is ignored. Any of these failures makes every key of that domain compiled. The document schema is the format; which keys and types an app understands is the `config_schema` axis (§8), used in `requires` like the others.

**Keys.** Every other member is a key. Each is checked on its own, in byte order of the names, and a refused key is reported and left compiled:

| Rule | Reason |
| --- | --- |
| Name matches `[A-Za-z0-9._-]{1,128}` (nested `policy` member names too) | `invalid_key` |
| Name not on the §4 denylist (below; nested `policy` member names too) | `denied_key` |
| `flags` values are booleans; `prompts` and `copy` values are strings | `wrong_type` |
| No `policy` string at any depth starts with `/`, contains `://`, or contains a denied fragment | `denied_value` |

**Denylist (plan §4: approval keys, approver lists, gate weakening, approval/secret endpoints).** A name is denied when, lowercased (ASCII) with `.`, `_` and `-` removed, it contains one of: `allowlist apikey approv authent authoriz bearer blacklist blocklist confirm credential denylist endpoint enroll hmac keychain nonce operationreview passphrase password permission privatekey publickey secret signingkey webhook whitelist`; or when one of its words, split at `.`, `_`, `-` and before an uppercase letter that follows a lowercase letter or digit, lowercased, is one of: `auth device devices gate gated gates gateway gating host hostname hosts key keys origin origins pin pinned pins signature signatures signer signing token tokens trust trusted uri url urls`. So `codingGate`, `gatewayURL`, `apiKey` and `teamLimits.approvalTimeout` are refused, while `delegateLimit`, `aggregateWindow` and `keyboardLayout` are not. The rule errs towards refusing: a refused name only means the compiled default. `prompts` and `copy` are text shown or sent as written and are exempt from the value rule, not from the name rule.

**Reading.** The app asks for a key with its compiled default and type: `string`, `bool`, `integer` (optional range), `string_list`, `string_map` or `integer_map` (optional range per value). Absent → the default, no report. Present with another type → the default and `wrong_type`; an integer outside the range → the default and `out_of_range` (a map with any non-integer is `wrong_type` first). Each reason is logged once per key.

**Kill switch.** In `flags`, `kill.<scope>.<name>: true` makes `<name>` compiled: scope `policy`, `prompts`, `copy` or `flags` for one key (read reason `killed`, also when the key is absent), `view` for one view type (P7 renderers use the compiled fallback for it). `false` changes nothing. An unknown scope, an empty name or a name starting with `kill.` is `invalid_kill`. Kill flags are not readable as ordinary flags, and a kill flag can only ever select compiled behaviour.

**Vectors.** `Tests/Fixtures/release-bundles/config/vectors.json` (`swarmhub/config-vectors/1`): 15 `cases`, each with `components` (archives under `config/archives/`, or `unreadable`), `reads` (`domain`, `key`, `type`, `default`, optional `min`/`max`, `expect`, optional read-time `report`), `views` and the exact decode `reports` in order (components in record order, then domains `policy`, `prompts`, `copy`, `flags`, keys in byte order). `bundle` is a signed bundle 12 (index seq 6, TEST-release-1 under the shared `keys/keys-2.json`) with one app config and one box-only config that apps must never read.

```
python3 scripts/release/make_config_vectors.py            # rewrite config/ only
python3 scripts/release/make_config_vectors.py --check    # byte-identical regeneration
python3 scripts/test_swift_config_vectors.py              # reference vs every case, P0b verify of bundle 12, Swift source parity
```

Vectors with unreadable components are checked against the decoder only. Live store snapshots are all-or-nothing:
an unreadable record (`bundle_unreadable`) or config component discards all bundle values and kill flags, so every
read uses its compiled default.

## 13. View documents (`swarmhub/ui/1`, P7a)

What a `ui` component means to the apps: server-driven UI catalogue v1 (plan §5.1, §5.3, §5.4). Implemented by `SDUIDecoder` in `Packages/SwarmHubCore/Sources/SwarmHubCore/SDUI/`; the Python statement is `scripts/release/ui_reference.py`. A view document is data read by compiled code: a closed catalogue of components, typed predicates and a closed enum of existing local commands. There are no expressions, loops, scripts, HTML or network calls, and no document can describe or reach `operation_review`, `secret_entry` or any other approval or secret surface. Renderers (P7b/P7c) are not part of this section.

**Outcome.** The app asks for a view type (`routine_result_card`, …) and gets exactly one of: `render` (the whole decoded document), `fallback` (the compiled view it ships today) or `update_required` (a compiled "update required" screen). Never part of a document. The first failing check decides:

| Order | Check → reason |
| --- | --- |
| 1 | kill switch `kill.view.<view>` (P6a flags, passed in as `isViewKilled`) → `killed` |
| 2 | size above `max_document_bytes` → `too_large` |
| 3 | profile JSON (§2: no floats, `null`, duplicates; depth ≤ 32) → `invalid_json` |
| 4 | document and node checks below → their reason; if the parsed top-level object has `"critical": true`, the verdict is `update_required` instead of `fallback` |
| 5 | kill switch on any component type the document uses → `killed` |

A kill switch always selects the compiled view, never `update_required`. A document that does not parse cannot ask for `update_required`.

**Document.** `{"schema":"swarmhub/ui/1","view":<name>,"critical"?:bool,"root":<node>}`, no other members. `schema` not a string → `schema_invalid`, another schema → `unsupported_schema`; members → `schema_invalid`; `view` matches `[a-z][a-z0-9_]{0,63}` (`schema_invalid`), does not name a denied surface (`denied_route`) and equals the requested view (`view_mismatch`).

**Nodes**, depth-first in document order. Each node: an object (`schema_invalid`); depth (root = 1) ≤ `max_depth` (`too_deep`); running node count ≤ `max_nodes` (`too_many_nodes`); `type` a string (`schema_invalid`), not a denied surface (`denied_route`), in the catalogue (`unknown_component`); members exactly as listed, unknown ones refused (`schema_invalid`). Common optional members: `id` (`[a-z][a-z0-9_]{0,63}`) and `visible_if` (predicate). Then the members in this order:

| Type | Members (`?` optional) |
| --- | --- |
| `text` | `text`, `style?` `plain`/`markdown`, `role?` `body`/`title`/`headline`/`caption`/`footnote`/`monospace` |
| `badge` | `text`, `tone?` `neutral`/`info`/`success`/`warning`/`danger` |
| `key_value` | `items`: non-empty array of `{key, value}` texts |
| `list` | `children`: non-empty array of nodes, `style?` `plain`/`bulleted`/`numbered` |
| `card` | `title?`, `subtitle?`, `children` (may be empty) |
| `form` | `id`, `title?`, `fields` (non-empty), `submit` `{label, action}` |
| `button` | `label`, `action`, `style?` `primary`/`secondary`/`destructive` |
| `flow` | `id`, `steps`: non-empty array of `{id, title, children}`, step ids unique; flows do not nest |
| `progress` | `total?` (1–1000000, default 100), `value?` (0–`total`, or a binding), `label?` |
| `diff_preview` | `text`, `title?`, `max_lines?` (1–2000) |

Every array (`children`, `items`, `fields`, `options`, `steps`) holds at most `max_children` entries (`too_many_children`), checked before its entries.

**Texts** are a literal string or `{"bind": <path>}`. A literal is at most `max_string_bytes` UTF-8 bytes (`string_too_long`) and has no control character other than tab and LF (`invalid_text`). Strings are shown as text, never markup. `text` with style `markdown` and a literal is the inline markdown subset only: any literal UTF-8 byte `[` (0x5B), `]` (0x5D) or `<` (0x3C) is refused (`markup_not_allowed`), including escaped syntax and code spans/blocks. Both decoders apply this byte rule without parsing Markdown; it blocks inline, full/collapsed/shortcut reference links, reference definitions, images, URI/email autolinks and HTML. Links reach the user only through the allowlisted, confirmed `open_url` action.

P7b renderer: render all text (including resolved bindings and plain text) with link interpretation and automatic link detection off as defence in depth.

**Bindings** name local data the app already holds; they are paths, not expressions. Path `[a-z][a-z0-9_]{0,31}(\.[a-z][a-z0-9_]{0,31}){0,5}` whose first segment is `app`, `box`, `form`, `profile`, `record`, `result` or `routine` (else `invalid_binding`). A segment is `denied_binding` when, with `_` removed, it contains `approv secret token password passphrase credential keychain apikey privatekey signingkey hmac nonce signature authent authoriz cookie session`, or one of its `_` words is `auth key keys pin pins device devices gate gates otp`. A malformed `{"bind"}` object is `schema_invalid`.

**Predicates** (`visible_if`) are one of `{"exists":{"bind":p}}`, `{"missing":{"bind":p}}`, `{"equals":{"bind":p,"value":<string|integer|boolean>}}`. Any other shape, operator or literal type → `invalid_predicate`; the path follows the binding rules.

**Actions** `{"command":<c>, "confirm"?:bool, <argument>}`. `command` a string (`schema_invalid`), not a denied surface (`denied_route`), in the enum (`unknown_action`); members exactly `command`, optional `confirm` and the command's one argument (`schema_invalid`); `routine.create` and `routine.save` only and always as a form `submit`, `flow_next` and `flow_back` only inside a flow step (`action_context`).

| Command | Argument |
| --- | --- |
| `dismiss`, `refresh`, `flow_next`, `flow_back`, `routine.create` | none |
| `copy_text` | `text` (a text) |
| `open_url` | `url`: at most 2048 bytes, `https://<host>[/path][?query]` with host `[a-z0-9-]+(\.[a-z0-9-]+)+` (no port, userinfo or fragment), host exactly in the app's compiled allowlist (empty by default) → else `url_not_allowed` |
| `navigate` | `screen`: not a denied surface (`denied_route`), one of `routines`, `chat`, `boxes`, `skills`, `settings`, `updates` (`unknown_action`) |
| `routine.open`, `routine.run_now`, `routine.pause`, `routine.resume`, `routine.save` | `routine`: a `{"bind"}` object |

`open_url` always requires a user confirmation; `confirm: false` cannot turn it off (`SDUIAction.requiresConfirmation`). `confirm: true` asks for one on any command.

**Form fields** `{id, kind, label, required?, placeholder?, options?, max_length?, types?, value?, visible_if?}`. `id` matches the name pattern (`schema_invalid`), follows the binding segment denylist (`denied_binding`) and is unique in the form; `kind` not a denied surface (`denied_route`), one of `text`, `multiline`, `choice`, `toggle`, `date`, `schedule`, `file_pick` (`unknown_component`). `placeholder` and `max_length` (1–`max_string_bytes`) only on `text`/`multiline`, `options` (required) only on `choice` as `{value [A-Za-z0-9._-]{1,64} unique, label}`, `types` (1–16 unique `[a-z0-9]+(\.[a-z0-9-]+)+` type identifiers) only on `file_pick`; `value` is a `{"bind"}` object.

**Denied surfaces.** A view, component type, command, screen or field kind is `denied_route` when, lowercased (ASCII) with `.`, `_` and `-` removed, it contains `operationreview secretentry approv secret keychain credential enroll password passphrase token apikey privatekey signingkey hmac nonce`.

**Limits** (vectors carry them in `inputs.limits`): `max_document_bytes` 65536, `max_depth` 12, `max_nodes` 256, `max_children` 64, `max_string_bytes` 4096.

**Target rules.** SwarmHubCore contains no `JavaScriptCore`, `JSContext`, `WebKit`, `dlopen`/`dlsym`, `NSClassFromString`/`NSSelectorFromString`, `NSExpression`/`NSPredicate`, `#selector`, `Bundle(path:)` or other dynamic loading entry points (checked by `SDUIDecoderTests` and `scripts/test_swift_ui_vectors.py`).

**Vectors.** `Tests/Fixtures/release-bundles/ui/vectors.json` (`swarmhub/ui-vectors/1`): every reason above, each case with `inputs` (`document` under `ui/documents/`, raw non-JSON inputs as `.bytes`; `view`, `killed`, `url_hosts`, `limits`) and `expect` (`verdict`, `reason`). `ui/fuzz.json` (`swarmhub/ui-fuzz/1`) is the shared deterministic fuzz: seed, iteration count and the reference verdict of each mutated golden (`scripts/release/ui_fuzz.py`, ported line by line in `SDUIFuzzTests.swift`).

```
python3 scripts/release/make_ui_vectors.py            # rewrite ui/ only
python3 scripts/release/make_ui_vectors.py --check    # byte-identical regeneration
python3 scripts/test_swift_ui_vectors.py              # reference vs every case, fuzz replay, Swift source parity
```

"""The release test-vector cases (P0a acceptance, CORE-PHASES.md) and the JCS vectors. Used by make_vectors.py."""

import copy

import ustar
from reference_verify import bucket
from vector_world import (INSTALL_ID, MAC, RELEASE, RELEASE_BUNDLE_ONLY, RELEASE_OLD, ROGUE, ROOT_1, ROOT_2,
                          World, f, sha256_hex)

BOX_ALL = ["swarmhub-manager", "swarmhub-feedback", "swarm-tools", "box-prompts", "policy"]


def accept(apply=BOX_ALL, skipped=(), version=11):
    return {"verdict": "accept", "stage": "component", "reason": "ok", "bundle_version": version,
            "apply": list(apply), "skipped": [dict(s) for s in skipped]}


def reject(stage, reason):
    return {"verdict": "reject", "stage": stage, "reason": reason}


def build_cases():
    w = World()
    base = w.build_base()
    files = w.files

    def case(case_id, description, expect, **inputs):
        merged = copy.deepcopy(base)
        for key, value in inputs.items():
            if key in ("floors", "limits"):
                merged[key].update(value)
            else:
                merged[key] = value
        w.cases.append({"id": case_id, "description": description, "inputs": merged, "expect": expect})

    def one_byte(rel, new_rel, old, new):
        data = files[rel]
        assert len(old) == len(new) and old in data
        return w.put(new_rel, data.replace(old, new, 1))

    def index_signed_by(case_id, signer):
        return w.signed_file(f"channels/stable--{case_id}.json", w.index([w.base_line]), [signer])

    def feedback(case_id, entries=None, raw=None, **extra):
        def mutate(signed, components):
            w.replace_component(components, "swarmhub-feedback", entries=entries, raw=raw)
        return w.variant(case_id, mutate, **extra)

    # Valid objects and selection.
    case("valid-box", "Valid chain; the box applies every box-targeted component.", accept())
    case("valid-mac", "Valid chain; the Mac takes only its data components.", accept(["policy", "routine-card"]),
         consumer=copy.deepcopy(MAC))
    w.signed_file("keys/keys-2--two-roots.json", w.key_manifest(), [ROOT_1, ROOT_2])
    case("keys-two-roots", "Key manifest signed by both roots meets a 2-of-2 pin.", accept(),
         pins="keys/pins--threshold-2.json", keys="keys/keys-2--two-roots.json")
    unpublished = {"requires": {"ui_catalog": ">=2.0"}, "bundle_version": 12,
                   "manifest_sha256": sha256_hex(b"TEST-not-published"), "rollout_percent": 100}
    selection = w.signed_file("channels/stable--line-selection.json", w.index([unpublished, w.base_line]), [RELEASE])
    case("line-selection-mac", "ui_catalog 1.3 cannot take the 2.x line and gets bundle 11.",
         accept(["policy", "routine-card"]), consumer=copy.deepcopy(MAC), index=selection)

    # Key manifest.
    case("tampered-keys", "One byte of the key manifest changed after signing.", reject("keys", "keys_bad_signature"),
         keys=one_byte("keys/keys-2.json", "keys/keys-2--tampered-byte.json",
                       b'"2027-01-01T00:00:00Z"', b'"2027-01-01T00:00:01Z"'))
    case("keys-untrusted", "Key manifest signed by a release key, not a pinned root.", reject("keys", "keys_untrusted"),
         keys=w.signed_file("keys/keys-2--untrusted.json", w.key_manifest(), [RELEASE]))
    case("keys-threshold", "One root signature against a 2-of-2 pin.", reject("keys", "keys_threshold"),
         pins="keys/pins--threshold-2.json")
    case("lower-keys-version", "Persisted keys.version 3 is above the served version 2.",
         reject("keys", "keys_rollback"), floors={"keys_version": 3})

    # Channel index.
    case("tampered-index", "One byte of the index changed after signing.", reject("index", "bad_signature"),
         index=one_byte("channels/stable.json", "channels/stable--tampered-byte.json",
                        b'"2026-10-19T00:00:00Z"', b'"2026-10-19T00:00:01Z"'))
    case("wrong-key", "Index claims TEST-release-1 but was signed with another key.", reject("index", "bad_signature"),
         index=index_signed_by("wrong-key", (RELEASE, ROGUE)))
    case("unknown-key", "Index signed by a key the key manifest does not list.", reject("index", "unknown_key"),
         index=index_signed_by("unknown-key", ROGUE))
    case("wrong-role", "Index signed by a key that only holds role bundle.", reject("index", "key_wrong_role"),
         index=index_signed_by("wrong-role", RELEASE_BUNDLE_ONLY))
    case("key-expired", "Index signed by a key past its not_after.", reject("index", "key_expired"),
         index=index_signed_by("key-expired", RELEASE_OLD))
    case("key-revoked", "The protected checkpoint revokes TEST-release-1.", reject("index", "key_revoked"),
         revoked_key_ids=[RELEASE])
    case("lower-index-seq", "Persisted index.seq 6 is above the served seq 5.", reject("index", "index_rollback"),
         floors={"index_seq": 6})
    case("expired-index", "Index expired at 2026-10-20T00:00:00Z; now is 12:00 that day.",
         reject("index", "index_expired"),
         index=w.signed_file("channels/stable--expired.json",
                             w.index([w.base_line], issued="2026-10-12T00:00:00Z", expires="2026-10-20T00:00:00Z"),
                             [RELEASE]))
    case("channel-mismatch", "A beta index served for the stable subscription.", reject("index", "channel_mismatch"),
         index=w.signed_file("channels/stable--beta.json", w.index([w.base_line], channel="beta"), [RELEASE]))
    case("float-in-signed", "rollout_percent written as 100.0: floats are not allowed.",
         reject("index", "schema_invalid"),
         index=w.put("channels/stable--float.json",
                     files["channels/stable.json"].replace(b'"rollout_percent":100}', b'"rollout_percent":100.0}')))
    case("no-compatible-line", "The only line needs updater>=2.0.", reject("index", "no_compatible_line"),
         index=w.signed_file("channels/stable--no-line.json",
                             w.index([w.line(files["bundles/11.json"], requires={"updater": ">=2.0"})]), [RELEASE]))
    percent = bucket(INSTALL_ID, 11)
    case("not-in-rollout", f"Bucket {percent} is not below rollout_percent {percent}.",
         {"verdict": "no_update", "stage": "index", "reason": "not_in_rollout"},
         index=w.signed_file("channels/stable--rollout.json",
                             w.index([w.line(files["bundles/11.json"], percent=percent)]), [RELEASE]))
    case("lower-bundle-version", "Applied bundle 12 is above the offered 11.", reject("index", "bundle_rollback"),
         floors={"bundle_version": 12})
    case("already-applied", "Bundle 11 is already applied.",
         {"verdict": "no_update", "stage": "index", "reason": "already_applied"}, floors={"bundle_version": 11})

    # Bundle manifest.
    other = w.signed_file("bundles/11--other.json", dict(w.bundle(11, w.components), label="TEST-other"), [RELEASE])
    case("manifest-hash-mismatch", "Index pins another manifest's hash; the served manifest differs.",
         reject("manifest", "manifest_hash_mismatch"),
         index=w.signed_file("channels/stable--hash-mismatch.json", w.index([w.line(files[other])]), [RELEASE]))
    case("manifest-version-mismatch", "Index line says 11; the signed manifest says 12.",
         reject("manifest", "version_mismatch"),
         **w.variant("version-mismatch", lambda s, c: None, line_version=11, manifest_version=12))
    case("incompatible-bundle-requires", "Bundle requires updater>=2.0.", reject("manifest", "incompatible_requires"),
         **w.variant("bundle-requires", lambda s, c: s.update(requires={"updater": ">=2.0"})))
    case("code-bearing-mismatch", "code_bearing false although code components are present.",
         reject("manifest", "code_bearing_mismatch"),
         **w.variant("code-bearing", lambda s, c: s.update(code_bearing=False)))
    case("class-mismatch-tool", "A tool labelled class data.", reject("manifest", "class_mismatch"),
         **w.variant("tool-data", lambda s, c: c[2].update({"class": "data"})))
    case("target-invalid", "A tool targeted at the Mac.", reject("manifest", "target_invalid"),
         **w.variant("tool-mac", lambda s, c: c[2].update(targets=["box", "mac"])))
    case("dependency-invalid", "box-prompts requires a component the bundle does not carry.",
         reject("manifest", "dependency_invalid"),
         **w.variant("dependency", lambda s, c: c[3].update(
             requires_component=[{"name": "missing-tool", "min_version": "1.0.0"}])))

    # Components: compatibility.
    skipped = [{"name": "swarm-tools", "reason": "incompatible"}, {"name": "box-prompts", "reason": "dependency_skipped"}]
    kept = ["swarmhub-manager", "swarmhub-feedback", "policy"]
    case("incompatible-component", "swarm-tools needs hermes>=0.30; it and box-prompts (requires it) are skipped.",
         accept(kept, skipped),
         **w.variant("component-requires",
                     lambda s, c: w.replace_component(c, "swarm-tools", requires={"hermes": ">=0.30"})))
    case("hermes-unknown", "The box cannot read its Hermes version; Hermes-ranged components are skipped.",
         accept(kept, skipped), consumer={"platform": "box", "versions": {"updater": "1.0.0"}})

    # Components: blobs, archives, classes.
    tampered = feedback("tampered-blob", w.feedback_entries(b"#!/bin/sh\necho TEST tampered-blob original\n"))
    blob = [k for k in files if k.startswith("blobs/") and b"tampered-blob original" in files[k]]
    assert len(blob) == 1
    w.put(blob[0], files[blob[0]].replace(b"original", b"0riginal"), replace=True)
    case("tampered-blob", "One byte of a component archive changed.", reject("component", "blob_hash_mismatch"),
         **tampered)

    def size_plus_one(signed, components):
        components[1]["size"] += 1
    case("blob-size-mismatch", "Declared size is one byte larger than the blob.",
         reject("component", "blob_size_mismatch"), **w.variant("size", size_plus_one))
    script = f("scripts/swarmhub-report", b"#!/bin/sh\necho TEST\n", 0o755)
    skill = f("SKILL.md", b"---\nname: swarmhub-feedback\n---\nTEST\n")
    archive_cases = [
        ("archive-dotdot", "Entry path ../evil.sh.", "archive_unsafe_path",
         [skill, f("../evil.sh", b"#!/bin/sh\n", 0o755)]),
        ("archive-absolute", "Entry path /tmp/evil.sh.", "archive_unsafe_path",
         [skill, f("/tmp/evil.sh", b"#!/bin/sh\n", 0o755)]),
        ("archive-symlink", "Symlink entry to /etc/passwd.", "archive_link",
         [skill, {"name": "scripts/link", "type": "symlink", "mode": 0o777, "linkname": "/etc/passwd"}]),
        ("archive-hardlink", "Hard-link entry.", "archive_link",
         [skill, {"name": "scripts/hard", "type": "hardlink", "mode": 0o644, "linkname": "SKILL.md"}]),
        ("archive-device", "Character device entry.", "archive_special_file",
         [skill, {"name": "scripts/dev", "type": "char", "mode": 0o644, "devmajor": 1, "devminor": 3}]),
        ("archive-bad-mode-setuid", "Setuid script (04755).", "archive_bad_mode",
         [skill, f("scripts/swarmhub-report", b"#!/bin/sh\n", 0o4755)]),
        ("archive-bad-mode-writable", "World-writable file (0666).", "archive_bad_mode",
         [f("SKILL.md", b"---\nname: swarmhub-feedback\n---\n", 0o666), script]),
        ("archive-duplicate-path", "SKILL.md appears twice.", "archive_duplicate_path", [skill, skill, script]),
        ("archive-path-conflict", "scripts is a file and also a parent directory.", "archive_path_conflict",
         [skill, f("scripts", b"x\n"), script]),
    ]
    for case_id, description, reason, entries in archive_cases:
        case(case_id, description, reject("component", reason), **feedback(case_id, entries))
    bad = bytearray(ustar.build([skill, script]))
    bad[0] ^= 0x01
    case("archive-malformed", "Header checksum does not match.", reject("component", "archive_malformed"),
         **feedback("archive-malformed", raw=bytes(bad)))
    case("archive-oversize-file", "A 5000-byte file against max_file_size 4096.", reject("component", "archive_oversize"),
         limits={"max_file_size": 4096}, **feedback("oversize-file", [skill, f("notes.md", b"n" * 5000), script]))
    case("archive-oversize-total", "Files totalling more than max_total_size 1500.",
         reject("component", "archive_oversize"), limits={"max_total_size": 1500},
         **feedback("oversize-total", [skill, f("a.md", b"a" * 1000), f("b.md", b"b" * 1000), script]))
    case("archive-oversize-blob", "Declared blob size above max_blob_size 1024.", reject("component", "archive_oversize"),
         limits={"max_blob_size": 1024})
    case("class-mismatch-skill", "A skill labelled data that contains a Python file.",
         reject("component", "class_mismatch"),
         **w.variant("skill-data-code", lambda s, c: w.replace_component(
             c, "swarmhub-manager", entries=[f("SKILL.md", b"---\nname: swarmhub-manager\n---\n"),
                                             f("helper.py", b"print('TEST')\n")])))
    case("class-mismatch-exec-data", "A config component whose JSON file is executable (0755).",
         reject("component", "class_mismatch"),
         **w.variant("exec-data", lambda s, c: w.replace_component(
             c, "policy", entries=[f("policy.json", b'{"coding_job_limit":2}\n', 0o755)])))
    return w


JCS_VECTORS = [
    ("sort-members", '{"b":2,"a":1,"c":{"z":true,"y":false}}', '{"a":1,"b":2,"c":{"y":false,"z":true}}'),
    ("strip-whitespace", ' { "a" : [ 1 , 2 ] ,\n "b" : "x" } ', '{"a":[1,2],"b":"x"}'),
    ("string-escapes", '{"s":"q\\" b\\\\ s\\/ n\\n t\\t r\\r b\\b f\\f c\\u0001 d\\u001F"}',
     '{"s":"q\\" b\\\\ s/ n\\n t\\t r\\r b\\b f\\f c\\u0001 d\\u001f"}'),
    ("non-ascii-literal", '{"k":"\\u00e9\\u20ac\\ud83d\\ude00 za\\u017c\\u00f3\\u0142\\u0107"}',
     '{"k":"é€\U0001F600 zażółć"}'),
    ("del-literal", '{"k":"\\u007f"}', '{"k":"\x7f"}'),
    ("integers", '{"n":-5,"m":9007199254740991,"z":0}', '{"m":9007199254740991,"n":-5,"z":0}'),
    ("nested-arrays", '{"a":[{"y":1,"x":[true,false]},[]]}', '{"a":[{"x":[true,false],"y":1},[]]}'),
]
JCS_ERRORS = [
    ("float", '{"a":1.0}'), ("exponent", '{"a":1e3}'), ("big-integer", '{"a":9007199254740992}'),
    ("negative-zero", '{"a":-0}'), ("null", '{"a":null}'), ("duplicate-member", '{"a":1,"a":2}'),
    ("lone-surrogate", '{"a":"\\ud800"}'), ("nan", '{"a":NaN}'), ("non-ascii-member", '{"é":1}'),
]

# Webhook operations

These tools implement swapdesign3 PR 6. They use only SwarmHub's skill modules;
they neither patch Hermes nor install services, change nginx/DNS, or switch a wake
automatically. Python on the box always runs with `-B`. Run operational probes
only during an authorized canary window: accepted requests wake the profile.

`webhook-probe` and `wake-enroll` run on ovh. `--box` selects an SSH alias with
batch authentication; omit it when running on the receiver's box. The same
checkout, including `ops/`, must already exist at `--box-checkout` on that box.
The default local checkout is the directory containing these scripts. No remote
files are uploaded by either tool. `--account` must be the profile owner's Unix
account; it defaults to `hb-<profile>`. Shared profiles require `--account hermes`.
Registration, key reads and receipt queries execute as that account with
`sudo -n -H -u`, not as the SSH login user. Receiver/control installation and the
registry belong to PR 4; these tools take the account and receiver port explicitly.

## Verify before enrollment

Prerequisites: the migrated profile's gateway, receiver and delivery worker are
running; the canary's innocuous `probe` messages are safe for that bot; HTTPS has
a valid certificate; the dedicated receiver is routed by profile. The shared
receiver still listens on 8745, and the migrated profile must be absent there.
`--base-url` is an HTTPS origin without a path prefix for automated verification.

During the canary window, the operator adds this temporary nginx configuration
in the `http` block, with an `access_log` in the relevant TLS server:

```nginx
map $http_x_swarmhub_key $swh_key { "" absent; default present; }
log_format swh_probe '$http_cf_ray $swh_key';
# In the server for konrad.agenthut.net:
access_log /var/log/nginx/swh-probe.log swh_probe;
```

The log records only the ray and header presence, never its value. Keep the
normal access/error logs too. The operator validates and reloads nginx through
the deployment procedure, then removes this map, format and extra access log
after the canary, including after a failed probe. The tool does not edit nginx.
It needs read access through `sudo -n nginx -T` and `sudo -n cat -- <log>`.

```sh
python3 -B ops/webhook-probe pilot \
  --box hermes-box --box-checkout /srv/swarmhub \
  --account hb-pilot --receiver-port 8746 \
  --base-url https://konrad.agenthut.net --origin-ip 192.0.2.10 \
  --presence-log /var/log/nginx/swh-probe.log \
  --access-log /var/log/nginx/access.log --error-log /var/log/nginx/error.log \
  --evidence /private/evidence/webhook-probe-20261024.json
python3 -B ops/webhook-probe --verify /private/evidence/webhook-probe-20261024.json
```

Use a real origin IP; the documentation address above is a placeholder. If the
origin firewall accepts only Cloudflare, run the probe on the box instead with
its local checkout and a reachable origin address. Do not relax the firewall.
Only `curl --resolve` bypasses DNS; certificate checks remain enabled.

The tool stops on failure, removes its unique `canary-<date>-<random>` routine
in `finally`, and saves a new owner-only evidence file even on failure. Cleanup
failure is also a failure. It never rotates an existing routine or alters a
production wake. Accepted deliveries remain in the journal for verification.

| Check | Required result |
| --- | --- |
| V1 | `nginx -T`: matching TLS vhost, per-profile loopback port, POST-only, 32k, buffering on/default, health hidden, no key/body log format |
| V2 a–e, origin | Valid 202 JSON pending; missing key **400** JSON bad request; wrong key **403** JSON webhook rejected; wrong slug **403** JSON webhook rejected; absent routine **404** JSON unknown webhook |
| V2 f, on-box | Same three-segment absent-routine path with a non-empty dummy key to **127.0.0.1:8745** gives **400 JSON**; 404 means the migrated profile remains in the shared home |
| V3 a–e, normal DNS | Same results, with `cf-ray` on every response |
| V4 | Both V3 a and e rays appear with `present` in the temporary origin log |
| V5 | Every accepted delivery becomes `deliveries.status=delivered` AND `receipts.status=received`, in the selected account, within 5 minutes |
| V6, origin and normal DNS | Health GET 404 HTML; canary GET/PUT 403 HTML; 33,000-byte body 413 HTML; chunked valid body 202 JSON; `message` 202 JSON after receiver PR 2 |
| V6, origin only | 32,500-byte body 400 JSON |
| V6 logs | Zero occurrences of the actual key in access, error and presence logs |

Every HTTP assertion checks status, Content-Type and body. An unknown path shape
or a GET's JSON 404 proves less than e, which is a **POST** to
`/<profile>/absent-<random>/x` with dummy header `probe`. No-key b never sends a
body key. A passed-through Transfer-Encoding gives receiver 400; a raw receiver
PUT gives Python 501 HTML. Neither may pass as nginx's expected answer.
For a pre-PR-2 receiver, use `--message-status 400`; this is recorded in evidence.

Evidence includes UTC timestamps, response headers and base64-encoded raw bodies,
safe request metadata, V4 matching lines, V5 states and log/config SHA-256 hashes.
Outbound keys and request header files are never saved; curl receives the key
through a temporary 0600 `-H @file`. Key echoes in responses abort before saving
them. The verifier rechecks HTTP assertions and completeness without contacting
the box. The V1 and log hashes let a separate verifier correlate independently
collected configuration/logs; hashes alone do not prove their contents. This is
an evidence replay, not proof that a live provider or the live box was tested.

If origin a/e are 202/404 but Cloudflare a/e are both 400 JSON, the diagnostic
identifies a stripped header. A 403 for a means alteration: stop and investigate.
Never enroll after red checks. No live verification is performed by unit tests.

## Enroll and undo

After a green canary, explicitly enroll the bot on the host that runs sb-codejob:

```sh
python3 -B ops/wake-enroll pilot --box hermes-box \
  --box-checkout /srv/swarmhub --account hb-pilot \
  --base-url https://konrad.agenthut.net
```

This registers/reuses `job-done` inside hb-pilot's account, reads its owner-only
key over captured SSH output, and atomically updates
`~/.config/sb-jobs/wake.env`. It writes `WAKE_AGENT_PILOT_URL`, `_KEY`,
`_AUTH_HEADER=X-SwarmHub-Key` and `_KEY_IN=header`. Agent names use sb-codejob's
alphanumeric uppercase normalization (`pilot-one` → `PILOTONE`). Unrelated rows
and comments survive. An advisory file lock serializes concurrent enrollments.
The file and each `wake.env.<UTC timestamp>` pre-image have mode 0600. Repeating
enrollment preserves the routine's slug/key; a hashed-only existing key is refused
because it cannot authenticate a sender. Choose a separately provisioned routine
or resolve its credentials rather than rotating it implicitly.

`--shadow-url https://…` adds `_SHADOW_URL`; omission preserves an existing shadow
setting. `--key-in body` sets `_KEY_IN=body`. Sending those fields requires sb
PR 1; body-key authentication also requires receiver PR 2. PR 6's implementation
and header-based tests have no strict dependency on PR 1.

To undo, restore the chosen private pre-image over `wake.env`, retaining mode
0600. An initial enrollment's pre-image is empty. Restore the nginx location
through its deployment procedure if exposure is being undone. No rollback is
performed automatically, and no keys are printed.

## DNS-only fallback

If a provider strips headers, provision `hooks.konrad.agenthut.net` as a
**DNS-only** A/AAAA record pointing to the origin (Cloudflare proxy off), through
the normal DNS/deployment procedure. Obtain a valid certificate using certbot's
DNS challenge; do not expose a plaintext webhook or put DNS API tokens into this
repository. Add that hostname to a dedicated TLS server with the same profile
routes, POST limit, buffering, 32k bound and hidden health route from
[the exposure recipe](../docs/webhooks-exposure.md). Keep unrelated services out
of that server. Ensure the firewall admits the intended callers for this host.

Run `webhook-probe` with the new `--base-url` and `--dns-only`. Normal DNS must
have **no** cf-ray. Evidence explicitly marks transport `dns-only` and V4
inapplicable; it does not claim Cloudflare passed the header. Supply an empty
owner-readable presence log for the unchanged log scan if no temporary ray log
is used. After verification, enroll with that base URL. Set `webhook_base` in the
bot account through `swarmctl policy set` if app-displayed URLs should also use
the fallback; enrollment itself changes only sb's wake file.

## Tests on ovh

Copy this checkout to an sbtest-owned scratch directory, then run:

```sh
sudo -u sbtest -- unshare -r -p -f --mount-proc \
  sh -c 'cd /path/to/sbtest-owned-copy && python3 -B -m unittest discover -s Tests/Ops -p "test_*.py"'
```

The suite uses temporary HOME directories, the stock receiver, real curl and a
private foreground nginx on loopback. All children are test-owned and stopped
by exact PID only. It tests the baseline `message` 400 as well as PR-2-style
202 fixtures. Cloudflare, live gateways and live Hermes are not contacted.

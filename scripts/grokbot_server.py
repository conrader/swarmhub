"""Read-only client for Grok Bot's server-side transcript history (used by export-grokbot.py).

Speaks the same Connect (binary protobuf) RPCs as `/Applications/Grok Bot.app` (see docs/P8a-findings.md):
`aiserver.v1.GrokBotService/ListGrokBotTranscriptEntries` and `/PresignSandBoxStoreReads`, plus a plain GET of
each presigned blob URL. Nothing else is ever called. Python 3 stdlib only.

Secrets (Keychain password, derived key, access token, machine id) live only in local variables and request
headers; they are never printed, logged or written. Errors carry status codes, never request headers.
"""
import base64
import ctypes
import gzip
import hashlib
import http.client
import json
import os
import subprocess
import time
import urllib.error
import urllib.request
import uuid

BASE_URL = "https://api2.cursor.sh"
SERVICE = "aiserver.v1.GrokBotService"
CLIENT_VERSION_FALLBACK = "0.70.2"
SECRETS = "~/Library/Application Support/Grok Bot/sand-secrets.json"
APP_PACKAGE = "/Applications/Grok Bot.app/Contents/Info.plist"
KEYCHAIN_SERVICE = "Grok Bot Safe Storage"
KEYCHAIN_NOTICE = "KEYCHAIN PROMPT COMING — Konrad: click Allow (not Always Allow)"
PAGE_LIMIT = 500  # the app's own cap per page
MIN_INTERVAL = 0.5  # <= 2 requests per second, RPCs and blob GETs together


class HistoryError(Exception):
    """Stops the run. The message never contains secrets."""


# --- protobuf (just the wire types these messages use) ---

def _varint(value):
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


def _key(field, wire):
    return _varint(field << 3 | wire)


def _bytes_field(field, data):
    return _key(field, 2) + _varint(len(data)) + data


def _read_varint(data, pos):
    shift = value = 0
    while True:
        if pos >= len(data):
            raise HistoryError("truncated protobuf varint")
        byte = data[pos]
        pos += 1
        value |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return value, pos
        shift += 7


def parse_message(data):
    """Wire-level decode: {field: [value, ...]} with varints as int and length-delimited as bytes."""
    fields, pos = {}, 0
    while pos < len(data):
        tag, pos = _read_varint(data, pos)
        field, wire = tag >> 3, tag & 7
        if wire == 0:
            value, pos = _read_varint(data, pos)
        elif wire == 2:
            size, pos = _read_varint(data, pos)
            value, pos = data[pos:pos + size], pos + size
        elif wire == 1:
            value, pos = data[pos:pos + 8], pos + 8
        elif wire == 5:
            value, pos = data[pos:pos + 4], pos + 4
        else:
            raise HistoryError("unsupported protobuf wire type %d" % wire)
        fields.setdefault(field, []).append(value)
    return fields


def encode_list_request(agent_id, limit, before_seq=None, session_id=""):
    """ListGrokBotTranscriptEntriesRequest: 1 agent_id, 3 before_seq?, 4 limit, 5 session_id."""
    out = _bytes_field(1, agent_id.encode())
    if before_seq is not None:
        out += _key(3, 0) + _varint(before_seq)
    out += _key(4, 0) + _varint(limit)
    if session_id:
        out += _bytes_field(5, session_id.encode())
    return out


def decode_list_response(data):
    """ListGrokBotTranscriptEntriesResponse.entries (field 1) as GrokBotTranscriptEntry dicts."""
    rows = []
    for raw in parse_message(data).get(1, []):
        f = parse_message(raw)
        first = lambda n, default=None: f[n][0] if n in f else default  # noqa: E731
        rows.append({"seq": first(1, 0), "entry_kind": first(2, b"").decode("utf-8", "replace"),
                     "body": first(3), "blob_hash": first(4).decode() if 4 in f else None,
                     "entry_id": first(6).decode() if 6 in f else None, "body_omitted": bool(first(7, 0))})
    return rows


def encode_presign_request(rel_paths):
    return b"".join(_bytes_field(1, p.encode()) for p in rel_paths)


def decode_presign_response(data):
    """PresignSandBoxStoreReadsResponse.instructions -> {rel_path: url}."""
    out = {}
    for raw in parse_message(data).get(1, []):
        f = parse_message(raw)
        if 1 in f and 2 in f:
            out[f[1][0].decode()] = f[2][0].decode()
    return out


# --- Electron safeStorage + request headers, as the app builds them ---

def _cccrypt(operation, key, data):
    lib = ctypes.CDLL("/usr/lib/system/libcommonCrypto.dylib")
    out = ctypes.create_string_buffer(len(data) + 16)
    moved = ctypes.c_size_t(0)
    # kCCAlgorithmAES128 = 0, kCCOptionPKCS7Padding = 1, IV = 16 spaces (Chromium OSCrypt on macOS).
    status = lib.CCCrypt(ctypes.c_uint32(operation), ctypes.c_uint32(0), ctypes.c_uint32(1), key, ctypes.c_size_t(len(key)),
                         b" " * 16, data, ctypes.c_size_t(len(data)), out, ctypes.c_size_t(len(out)), ctypes.byref(moved))
    if status != 0:
        raise HistoryError("safeStorage decryption failed (CommonCrypto status %d)" % status)
    return out.raw[:moved.value]


def safe_storage_key(password):
    return hashlib.pbkdf2_hmac("sha1", password, b"saltysalt", 1003, 16)


def decrypt_safe_storage(value_b64, key):
    """Electron safeStorage string: base64('v10' + AES-128-CBC(PKCS7))."""
    raw = base64.b64decode(value_b64)
    if not raw.startswith(b"v10"):
        raise HistoryError("unexpected safeStorage version prefix")
    return _cccrypt(1, key, raw[3:]).decode("utf-8")


def keychain_password(run=subprocess.run, timeout=180):
    """One `security` read. The password stays in this process; denial or timeout stops the run."""
    print(KEYCHAIN_NOTICE, flush=True)
    try:
        result = run(["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"],
                     capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise HistoryError("Keychain read timed out (no answer within %d s); not retrying" % timeout)
    if result.returncode != 0:
        raise HistoryError("Keychain read denied or failed (security exit %d); not retrying" % result.returncode)
    return result.stdout.rstrip(b"\n")


def read_credentials(secrets_path, key):
    """Active account's access token, the machine id and the selected team id (if any)."""
    with open(os.path.expanduser(secrets_path), encoding="utf-8") as handle:
        secrets = json.load(handle)
    accounts = json.loads(secrets.get("cursor-accounts") or "null") or {}
    account = (accounts.get("accounts") or {}).get(accounts.get("active") or "")
    if not account or not account.get("cursor-access-token"):
        raise HistoryError("no signed-in Grok Bot account in sand-secrets.json")

    def unwrap(value):
        if value.startswith("scoped:v1:"):
            value = value.split(":", 3)[3]
        return decrypt_safe_storage(value, key)

    token = unwrap(account["cursor-access-token"])
    machine_id = unwrap(secrets["cursor-machine-id"]).strip() if secrets.get("cursor-machine-id") else ""
    team = account.get("cursor-selected-team-id")
    team_id = unwrap(team).strip() if team else None
    team_id = team_id if team_id and team_id.isdigit() and int(team_id) > 0 else None
    return token, machine_id if 0 < len(machine_id) <= 127 else "", team_id


def token_expired(token, now=None):
    try:
        payload = token.split(".")[1]
        claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
    except (IndexError, ValueError):
        return False
    exp = claims.get("exp")
    return isinstance(exp, (int, float)) and exp <= (now if now is not None else time.time())


def cursor_checksum(machine_id, now_ms=None):
    """`AA()` in main-app.cjs: 6 timestamp bytes (ms / 1e6), XOR-chained from 165, base64url, then the machine id."""
    t = int((now_ms if now_ms is not None else time.time() * 1000) // 1e6)
    # JS `>>` works on int32 with the shift count mod 32, so `t>>40` is `t>>8` and `t>>32` is `t`.
    t32 = (t & 0xFFFFFFFF) - (1 << 32 if t & 0x80000000 else 0)
    data = bytearray((t32 >> (shift % 32)) & 255 for shift in (40, 32, 24, 16, 8, 0))
    prev = 165
    for i in range(len(data)):
        data[i] = ((data[i] ^ prev) + i % 256) & 255
        prev = data[i]
    return base64.urlsafe_b64encode(bytes(data)).decode().rstrip("=") + machine_id


def client_version(plist=APP_PACKAGE):
    try:
        import plistlib
        with open(plist, "rb") as handle:
            version = plistlib.load(handle).get("CFBundleShortVersionString") or ""
    except OSError:
        version = ""
    parts = version.split("-")[0].split(".")
    return version.split("-")[0] if len(parts) == 3 and all(p.isdigit() for p in parts) else CLIENT_VERSION_FALLBACK


def request_headers(token, machine_id, team_id, version):
    """`getSandBackendClientHeaders` + `o_e`; x-ghost-mode uses the app's privacy-safe value."""
    headers = {"user-agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Sand/%s Safari/537.36" % version,
               "x-cursor-client-type": "sand", "x-cursor-client-version": version, "x-sand-box-namespace": "prod",
               "x-cursor-client-os": "darwin", "x-cursor-client-source": "sand-desktop",
               "authorization": "Bearer " + token, "x-ghost-mode": "true"}
    if team_id:
        headers["x-cursor-team-id"] = team_id
    if machine_id:
        headers["x-cursor-checksum"] = cursor_checksum(machine_id)
    return headers


# --- transport ---

class Client:
    def __init__(self, base_url, headers, min_interval=None, urlopen=urllib.request.urlopen,
                 clock=time.monotonic, sleep=time.sleep):
        self.base_url, self._headers = base_url.rstrip("/"), headers
        self.min_interval = MIN_INTERVAL if min_interval is None else min_interval
        self.urlopen, self.clock, self.sleep = urlopen, clock, sleep
        self._last = None
        self.requests = 0

    def _pace(self):
        if self._last is not None:
            wait = self.min_interval - (self.clock() - self._last)
            if wait > 0:
                self.sleep(wait)
        self._last = self.clock()
        self.requests += 1

    def _open(self, request, timeout):
        try:
            with self.urlopen(request, timeout=timeout) as response:
                data = response.read()
                if response.headers.get("content-encoding") == "gzip":
                    data = gzip.decompress(data)
                return response.status, data
        except urllib.error.HTTPError as error:
            body = error.read() if error.fp else b""
            return error.code, body
        except urllib.error.URLError as error:
            raise HistoryError("network error: %s" % type(error.reason).__name__)
        except (OSError, http.client.HTTPException) as error:
            raise HistoryError("network error: %s" % type(error).__name__)

    def rpc(self, method, body):
        self._pace()
        headers = dict(self._headers)
        headers.update({"content-type": "application/proto", "connect-protocol-version": "1",
                        "connect-timeout-ms": "15000", "accept-encoding": "gzip", "x-request-id": str(uuid.uuid4())})
        request = urllib.request.Request("%s/%s/%s" % (self.base_url, SERVICE, method), data=body, headers=headers, method="POST")
        status, data = self._open(request, 30)
        if status != 200:
            try:
                code = json.loads(data.decode("utf-8")).get("code", "")
            except (ValueError, UnicodeDecodeError, AttributeError):
                code = ""
            raise HistoryError("%s failed: HTTP %d %s" % (method, status, code))
        return data

    def get_blob(self, url):
        """Presigned GET, no auth headers (as the app's fetch). 404 means the blob is gone."""
        self._pace()
        status, data = self._open(urllib.request.Request(url, method="GET"), 30)
        if status == 404:
            return None
        if status != 200:
            raise HistoryError("blob read failed: HTTP %d" % status)
        return data


# --- history paging ---

def _entry_from_body(body, row):
    try:
        entry = json.loads(body.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return None
    if not isinstance(entry, dict):
        return None
    entry["seq"] = row["seq"]
    if not isinstance(entry.get("id"), str) and row.get("entry_id"):
        entry["id"] = row["entry_id"]
    return entry


def resolve_rows(client, agent_id, rows, stats):
    """Bodies for one page: inline, from presigned blobs, or by re-listing omitted rows one by one."""
    hashes = sorted({r["blob_hash"] for r in rows if r["body"] is None and r["blob_hash"]})
    blobs = {}
    if hashes:
        urls = decode_presign_response(client.rpc("PresignSandBoxStoreReads", encode_presign_request(["blobs/" + h for h in hashes])))
        for h in hashes:
            url = urls.get("blobs/" + h)
            body = client.get_blob(url) if url else None
            if body is None:
                stats["blobs_missing"] += 1
            else:
                blobs[h] = body
                stats["blobs_read"] += 1
    entries = []
    for row in rows:
        body = row["body"] if row["body"] is not None else blobs.get(row["blob_hash"])
        if body is None and row["body_omitted"]:
            again = decode_list_response(client.rpc("ListGrokBotTranscriptEntries", encode_list_request(agent_id, 1, row["seq"] + 1)))
            again = [r for r in again if r["seq"] == row["seq"]]
            stats["omitted_refetched"] += 1
            if again:
                # The single row comes back inline or as a blob; never re-list it a second time.
                entries.extend(resolve_rows(client, agent_id, [dict(again[0], body_omitted=False)], stats))
                continue
        entry = _entry_from_body(body, row) if body is not None else None
        if entry is None:
            stats["unreadable"] += 1
        else:
            entries.append(entry)
    return entries


def fetch_older(client, agent_id, before_seq=None, limit=PAGE_LIMIT, log=None):
    """Pages backwards from `before_seq` (exclusive) to seq 1. Returns (entries, stats)."""
    stats = {"pages": 0, "rows": 0, "blobs_read": 0, "blobs_missing": 0, "omitted_refetched": 0, "unreadable": 0}
    entries = []
    while before_seq is None or before_seq > 1:
        rows = decode_list_response(client.rpc("ListGrokBotTranscriptEntries", encode_list_request(agent_id, limit, before_seq)))
        stats["pages"] += 1
        if before_seq is not None:
            rows = [r for r in rows if r["seq"] < before_seq]
        if not rows:
            break
        stats["rows"] += len(rows)
        entries.extend(resolve_rows(client, agent_id, rows, stats))
        oldest = min(r["seq"] for r in rows)
        if log:
            log(stats["pages"], oldest)
        if len(rows) < limit:
            break
        before_seq = oldest
    return entries, stats


def merge_entries(cached, fetched):
    """Union by seq; the app's cached entry wins on a collision. Sorted by seq."""
    by_seq = {}
    for entry in fetched:
        if isinstance(entry.get("seq"), int):
            by_seq[entry["seq"]] = entry
    for entry in cached:
        if isinstance(entry.get("seq"), int):
            by_seq[entry["seq"]] = entry
    return [by_seq[s] for s in sorted(by_seq)]


def coverage(entries):
    """{min, max, count, gaps: [[from, to], ...], complete} over seq 1..max."""
    seqs = sorted({e["seq"] for e in entries if isinstance(e.get("seq"), int)})
    if not seqs:
        return {"min": None, "max": None, "count": 0, "gaps": [], "complete": False}
    gaps, expected = [], 1
    for s in seqs:
        if s > expected:
            gaps.append([expected, s - 1])
        expected = s + 1
    return {"min": seqs[0], "max": seqs[-1], "count": len(seqs), "gaps": gaps, "complete": not gaps}

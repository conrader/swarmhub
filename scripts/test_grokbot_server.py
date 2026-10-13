#!/usr/bin/env python3
"""Unit tests for --fetch-server-history against a local fake Grok server. Synthetic data only; no Keychain."""
import base64
import contextlib
import http.server
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import grokbot_server as g  # noqa: E402

spec = importlib.util.spec_from_file_location("export_grokbot", os.path.join(HERE, "export-grokbot.py"))
exporter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(exporter)

TOKEN = "synthetic-token-SECRETVALUE-123"
MACHINE = "synthetic-machine-id-456"
ALPHA = "00000000-0000-4000-8000-0000000000a1"
BETA = "00000000-0000-4000-8000-0000000000b2"
# PBKDF2-SHA1('synthetic-pass', 'saltysalt', 1003, 16) + AES-128-CBC(IV 16 spaces) of 'synthetic-token-123', made with openssl.
VECTOR = "djEwLxWA72RiFyJjJwUyVOZUeOfLRjarBACKhRdBmH8/9Hc="


def read(path):
    with open(path) as handle:
        return handle.read()


def entry(seq, text=None):
    return {"kind": "message", "id": "e%d" % seq, "seq": seq, "role": "user", "content": text or "synthetic %d" % seq,
            "timestampMs": 1760000000000 + seq * 1000}


def row_bytes(seq, body=None, blob_hash=None, entry_id=None, omitted=False):
    out = g._key(1, 0) + g._varint(seq) + g._bytes_field(2, b"message")
    if body is not None:
        out += g._bytes_field(3, body)
    if blob_hash:
        out += g._bytes_field(4, blob_hash.encode())
    if entry_id:
        out += g._bytes_field(6, entry_id.encode())
    if omitted:
        out += g._key(7, 0) + g._varint(1)
    return out


class FakeGrok:
    """Serves `history[agent]` = {seq: entry}. Seqs in `blob_seqs` come as blobs, `omitted_seqs` as body_omitted."""

    def __init__(self, history, blob_seqs=(), omitted_seqs=(), gone_blobs=()):
        self.history, self.blob_seqs, self.omitted_seqs, self.gone = history, set(blob_seqs), set(omitted_seqs), set(gone_blobs)
        self.calls, self.headers = [], []
        fake = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def _send(self, status, body, content_type="application/proto"):
                self.send_response(status)
                self.send_header("content-type", content_type)
                self.send_header("content-length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                fake.calls.append(("GET", self.path))
                h = self.path.rsplit("/", 1)[1]
                if h in fake.gone:
                    return self._send(404, b"")
                agent, seq = h.split("-s")
                self._send(200, json.dumps(fake.history[agent][int(seq)]).encode(), "application/octet-stream")

            def do_POST(self):
                body = self.rfile.read(int(self.headers["content-length"]))
                fake.calls.append(("POST", self.path))
                fake.headers.append({k.lower(): v for k, v in self.headers.items()})
                method = self.path.rsplit("/", 1)[1]
                if method == "ListGrokBotTranscriptEntries":
                    return self._send(200, fake.list(g.parse_message(body)))
                if method == "PresignSandBoxStoreReads":
                    paths = [p.decode() for p in g.parse_message(body).get(1, [])]
                    out = b"".join(g._bytes_field(1, g._bytes_field(1, p.encode()) + g._bytes_field(
                        2, ("http://127.0.0.1:%d/blob/%s" % (fake.port, p[len("blobs/"):])).encode())) for p in paths)
                    return self._send(200, out)
                self._send(404, json.dumps({"code": "unimplemented"}).encode(), "application/json")

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def list(self, req):
        agent = req[1][0].decode()
        before = req[3][0] if 3 in req else None
        limit = req[4][0]
        seqs = sorted((s for s in self.history.get(agent, {}) if before is None or s < before), reverse=True)[:limit]
        out = b""
        for s in seqs:  # newest first, like the real service
            e = self.history[agent][s]
            if s in self.blob_seqs:
                r = row_bytes(s, blob_hash="%s-s%d" % (agent, s), entry_id=e["id"])
            elif s in self.omitted_seqs and limit != 1:
                r = row_bytes(s, entry_id=e["id"], omitted=True)
            else:
                r = row_bytes(s, body=json.dumps(e).encode(), entry_id=e["id"])
            out += g._bytes_field(1, r)
        return out

    def close(self):
        self.server.shutdown()
        self.server.server_close()


def client_for(fake):
    return g.Client("http://127.0.0.1:%d" % fake.port, g.request_headers(TOKEN, MACHINE, None, "0.70.2"), min_interval=0)


def write_cache(directory, rows, transcripts):
    os.makedirs(directory)

    def put(key, value):
        name = base64.b32encode(key.encode()).decode().rstrip("=").lower() + ".blob"
        with open(os.path.join(directory, name), "w") as handle:
            json.dump({"value": value}, handle)
    put("sand.client.slice.account.x.roster.last-roster", {"rows": rows})
    for agent, entries in transcripts.items():
        put("sand.client.slice.account.x.transcript.replicas." + agent, {"entries": entries})


class ProtoAndCryptoTests(unittest.TestCase):
    def test_list_request_round_trip(self):
        req = g.parse_message(g.encode_list_request(ALPHA, 500, 2928))
        self.assertEqual((req[1][0].decode(), req[3][0], req[4][0]), (ALPHA, 2928, 500))
        self.assertNotIn(3, g.parse_message(g.encode_list_request(ALPHA, 500)))
        self.assertEqual(g.parse_message(g._key(300, 0) + g._varint(1 << 40)), {300: [1 << 40]})

    def test_decodes_entry_rows(self):
        data = g._bytes_field(1, row_bytes(7, body=b"{}", entry_id="e7")) + g._bytes_field(1, row_bytes(6, blob_hash="h", omitted=True))
        rows = g.decode_list_response(data)
        self.assertEqual([r["seq"] for r in rows], [7, 6])
        self.assertEqual((rows[0]["body"], rows[0]["entry_id"], rows[1]["blob_hash"], rows[1]["body_omitted"]), (b"{}", "e7", "h", True))

    def test_safe_storage_vector_from_openssl(self):
        key = g.safe_storage_key(b"synthetic-pass")
        self.assertEqual(key.hex(), "c3b228bd930628aa1baab3f1a0f9911a")
        self.assertEqual(g.decrypt_safe_storage(VECTOR, key), "synthetic-token-123")
        with self.assertRaises(g.HistoryError):
            g.decrypt_safe_storage(base64.b64encode(b"v11xxxx").decode(), key)

    def test_checksum_matches_app_js(self):
        # node: AA('mid') from main-app.cjs with Date.now() = 1760000000000.
        self.assertEqual(g.cursor_checksum("mid", now_ms=1760000000000), "fn-BnklOmid")

    def test_headers_match_the_app(self):
        h = g.request_headers(TOKEN, MACHINE, "42", "0.70.2")
        self.assertEqual(h["x-cursor-client-type"], "sand")
        self.assertEqual(h["x-cursor-client-source"], "sand-desktop")
        self.assertEqual(h["x-ghost-mode"], "true")
        self.assertEqual(h["x-cursor-team-id"], "42")
        self.assertTrue(h["x-cursor-checksum"].endswith(MACHINE))
        self.assertIn("Sand/0.70.2", h["user-agent"])
        self.assertNotIn("x-cursor-team-id", g.request_headers(TOKEN, "", None, "0.70.2"))

    def test_token_expiry(self):
        def jwt(exp):
            return "x." + base64.urlsafe_b64encode(json.dumps({"exp": exp}).encode()).decode().rstrip("=") + ".y"
        self.assertTrue(g.token_expired(jwt(100), now=200))
        self.assertFalse(g.token_expired(jwt(300), now=200))

    def test_keychain_called_once_and_denial_stops(self):
        calls = []

        def denied(cmd, **kw):
            calls.append(cmd)
            return subprocess.CompletedProcess(cmd, 51, b"", b"")
        with contextlib.redirect_stdout(io.StringIO()) as out, self.assertRaises(g.HistoryError):
            g.keychain_password(run=denied)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][:4], ["security", "find-generic-password", "-s", "Grok Bot Safe Storage"])
        self.assertIn("KEYCHAIN PROMPT COMING", out.getvalue())

        def slow(cmd, **kw):
            raise subprocess.TimeoutExpired(cmd, kw["timeout"])
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(g.HistoryError):
            g.keychain_password(run=slow)

    def test_rate_limit_spaces_every_request(self):
        now, sleeps = [0.0], []

        def sleep(s):
            sleeps.append(s)
            now[0] += s
        client = g.Client("http://x", {}, min_interval=0.5, clock=lambda: now[0], sleep=sleep)
        for _ in range(4):
            client._pace()
            now[0] += 0.1
        self.assertEqual(client.requests, 4)
        self.assertEqual([round(s, 3) for s in sleeps], [0.4, 0.4, 0.4])

    def test_merge_and_coverage(self):
        merged = g.merge_entries([entry(5, "cached"), entry(6)], [entry(4), entry(5, "server"), entry(1)])
        self.assertEqual([e["seq"] for e in merged], [1, 4, 5, 6])
        self.assertEqual(merged[2]["content"], "cached")
        self.assertEqual(g.coverage(merged), {"min": 1, "max": 6, "count": 4, "gaps": [[2, 3]], "complete": False})
        self.assertTrue(g.coverage([entry(1), entry(2)])["complete"])


class FetchTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        alpha = {s: entry(s) for s in range(1, 1201) if s not in (300, 301)}
        beta = {s: entry(s) for s in range(1, 11)}
        self.fake = FakeGrok({ALPHA: alpha, BETA: beta}, blob_seqs={10, 11, 999}, omitted_seqs={500, 7}, gone_blobs={"%s-s11" % ALPHA})

    def tearDown(self):
        self.fake.close()
        shutil.rmtree(self.tmp)

    def test_pages_back_to_seq_one_with_blobs_and_omitted_rows(self):
        entries, stats = g.fetch_older(client_for(self.fake), ALPHA, before_seq=1150, limit=500)
        seqs = sorted(e["seq"] for e in entries)
        self.assertEqual(seqs[0], 1)
        self.assertEqual(seqs[-1], 1149)
        self.assertNotIn(11, seqs)  # blob gone (404)
        self.assertIn(10, seqs)
        self.assertIn(500, seqs)
        self.assertEqual(stats["blobs_missing"], 1)
        self.assertEqual(stats["omitted_refetched"], 2)
        self.assertEqual(stats["pages"], 3)
        methods = {p for m, p in self.fake.calls if m == "POST"}
        self.assertEqual(methods, {"/aiserver.v1.GrokBotService/ListGrokBotTranscriptEntries", "/aiserver.v1.GrokBotService/PresignSandBoxStoreReads"})
        self.assertTrue(all(p.startswith("/blob/") for m, p in self.fake.calls if m == "GET"))
        h = self.fake.headers[0]
        self.assertEqual(h["content-type"], "application/proto")
        self.assertEqual(h["authorization"], "Bearer " + TOKEN)

    def test_http_error_stops(self):
        client = client_for(self.fake)
        with self.assertRaises(g.HistoryError) as ctx:
            client.rpc("SomethingElse", b"")
        self.assertIn("HTTP 404 unimplemented", str(ctx.exception))
        self.assertNotIn(TOKEN, str(ctx.exception))

    def test_exporter_merges_cache_and_reports_coverage_without_leaking_secrets(self):
        cache = os.path.join(self.tmp, "cache")
        out = os.path.join(self.tmp, "SwarmHub Grok Export")
        rows = [{"id": ALPHA, "name": "Alpha"}, {"id": BETA, "name": "Beta"}]
        write_cache(cache, rows, {ALPHA: [entry(s, "cached %d" % s) for s in range(1150, 1201)], BETA: []})
        original = exporter.load_credentials
        exporter.load_credentials = lambda path: (TOKEN, MACHINE, None)
        g_min, g.MIN_INTERVAL = g.MIN_INTERVAL, 0
        try:
            stdout, stderr = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                code = exporter.main(["--cache", cache, "--out", out, "--fetch-server-history",
                                      "--base-url", "http://127.0.0.1:%d" % self.fake.port])
        finally:
            exporter.load_credentials = original
            g.MIN_INTERVAL = g_min
        self.assertEqual(code, 0, stderr.getvalue())
        index = json.loads(read(os.path.join(out, "index.json")))
        self.assertEqual(index["source"], "grok-bot-app-cache+server-history")
        alpha = next(b for b in index["bots"] if b["source_id"] == ALPHA)
        self.assertEqual(alpha["seq_coverage"]["gaps"], [[11, 11], [300, 301]])
        self.assertEqual(alpha["seq_coverage"]["max"], 1200)
        beta = next(b for b in index["bots"] if b["source_id"] == BETA)
        self.assertTrue(beta["seq_coverage"]["complete"])
        bundle = json.loads(read(os.path.join(out, alpha["bundle"])))
        texts = {m["seq"]: m["text"] for m in bundle["messages"]}
        self.assertEqual(texts[1150], "cached 1150")
        self.assertEqual(texts[1], "synthetic 1")
        self.assertEqual(len(bundle["messages"]), 1197)
        self.assertIn("300-301", bundle["limitations"][0])
        blob = json.dumps(index) + read(os.path.join(out, "redaction-report.json")) + stdout.getvalue() + stderr.getvalue()
        for root, _, files in os.walk(out):
            for name in files:
                blob += read(os.path.join(root, name))
        self.assertNotIn(TOKEN, blob)
        self.assertNotIn(MACHINE, blob)

    def test_stop_leaves_previous_export_untouched(self):
        cache = os.path.join(self.tmp, "cache")
        out = os.path.join(self.tmp, "SwarmHub Grok Export")
        write_cache(cache, [{"id": ALPHA, "name": "Alpha"}], {ALPHA: []})
        os.makedirs(out)
        open(os.path.join(out, "marker"), "w").close()

        def deny(path):
            raise g.HistoryError("Keychain read denied or failed (security exit 51); not retrying")
        original, exporter.load_credentials = exporter.load_credentials, deny
        try:
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()) as err:
                code = exporter.main(["--cache", cache, "--out", out, "--fetch-server-history", "--base-url", "http://127.0.0.1:1"])
        finally:
            exporter.load_credentials = original
        self.assertEqual(code, 2)
        self.assertIn("denied", err.getvalue())
        self.assertEqual(os.listdir(out), ["marker"])


if __name__ == "__main__":
    unittest.main()

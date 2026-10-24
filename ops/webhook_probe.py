"""V1–V6 verification. Evidence contains responses, never outbound credentials or request bodies."""
import base64
from datetime import datetime, timezone
import hashlib
import fnmatch
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import subprocess
import tempfile
import time
from urllib.parse import urlsplit


def nginx_nodes(text):
    lexer = shlex.shlex(text, posix=True, punctuation_chars="{};")
    lexer.whitespace_split = True
    tokens = iter(piece for token in lexer for piece in
                  (list(token) if token and set(token) <= set("{};") else [token]))

    def block(nested=False):
        result, head = [], []
        for piece in tokens:
            if piece == "{":
                result.append((head, block(True)))
                head = []
            elif piece == ";":
                if head:
                    result.append((head, None))
                head = []
            elif piece == "}":
                if head or not nested:
                    raise ValueError("unbalanced nginx config")
                return result
            else:
                head.append(piece)
        if nested or head:
            raise ValueError("incomplete nginx config")
        return result
    return block()


def nginx_tree(text):
    # nginx -T dumps included files separately, not inline. Resolve only those dumped files.
    chunks = re.split(r"(?m)^# configuration file (.+):\n", text)
    if len(chunks) == 1:
        return nginx_nodes(text)
    files = dict(zip(chunks[1::2], chunks[2::2]))
    main = chunks[1]
    prefix = str(Path(main).parent)

    def expand(nodes, stack):
        result = []
        for head, body in nodes:
            if head[0] == "include" and body is None:
                pattern = head[1] if head[1].startswith("/") else prefix + "/" + head[1]
                matched = [path for path in files if fnmatch.fnmatchcase(path, pattern)]
                if not matched and not any(char in pattern for char in "*?["):
                    raise ValueError("nginx include was not dumped")
                for path in matched:
                    if path in stack:
                        raise ValueError("recursive nginx include")
                    result.extend(expand(nginx_nodes(files[path]), stack + [path]))
            else:
                result.append((head, expand(body, stack) if body is not None else None))
        return result
    return expand(nginx_nodes(files[main]), [main])


def directives(nodes, key):
    return [head[1:] for head, body in nodes if head and head[0] == key and body is None]


def config_checks(text, host, profile, port):
    """Check nginx -T's expanded config. Ambiguous/unsupported layouts fail closed."""
    tree = nginx_tree(text)
    http = [body for head, body in tree if head == ["http"]]
    if len(http) != 1:
        return False
    http = http[0]
    servers = [body for head, body in http if head == ["server"] and
               any(host in names for names in directives(body, "server_name")) and
               any("ssl" in listen and any(value in ("443", "[::]:443", "0.0.0.0:443") for value in listen)
                   for listen in directives(body, "listen"))]
    # Multiple same-name vhosts require manual review; never accept a check on the wrong one.
    if len(servers) != 1:
        return False
    server = servers[0]
    locations = [(head[1:], body) for head, body in server if head[0] == "location"]

    def location(path):
        exact = [body for head, body in locations if head == ["=", path]]
        if exact:
            return exact[0]
        prefixes = [(head[-1], body, head[0] == "^~") for head, body in locations
                    if head[0] not in ("=", "~", "~*") and path.startswith(head[-1])]
        prefix = max(prefixes, key=lambda item: len(item[0])) if prefixes else None
        if not prefix or not prefix[2]:
            for head, body in locations:
                if head[0] in ("~", "~*") and re.search(head[1], path, re.I if head[0] == "~*" else 0):
                    return body
        return prefix[1] if prefix else []

    route = location(f"/swarmhub/webhook/{profile}/canary/x")
    health = location("/swarmhub/webhook/health")
    effective = http + server + route
    limit = directives(effective, "client_max_body_size")
    buffering = directives(effective, "proxy_request_buffering")
    upstream = directives(route, "proxy_pass")
    post_only = any(head == ["limit_except", "POST"] and directives(body, "deny") == [["all"]]
                    for head, body in route if body is not None)
    formats = directives(http, "log_format")
    no_secret_logging = not any(re.search(r"\$(?:http_x_swarmhub_key|request_body)\b", " ".join(fmt))
                                for fmt in formats)
    return (post_only and limit[-1:] == [["32k"]] and buffering[-1:] in ([], [["on"]])
            and upstream == [[f"http://127.0.0.1:{port}"]]
            and directives(health, "return") == [["404"]]
            and not directives(route, "rewrite") and no_secret_logging)


class Curl:
    def __init__(self, base, key):
        self.base, self.key = base.rstrip("/"), key

    def request(self, path, method="POST", payload=None, auth="valid", origin=None, chunked=False):
        with tempfile.TemporaryDirectory(prefix="webhook-probe-") as folder:
            folder = Path(folder)
            header, body = folder / "request.headers", folder / "request.body"
            headers, output = folder / "response.headers", folder / "response.body"
            lines = ["Content-Type: application/json", "Expect:"]
            if auth != "none":
                lines.append("X-SwarmHub-Key: " + (self.key if auth == "valid" else auth))
            if chunked:
                lines.append("Transfer-Encoding: chunked")
            header.touch(mode=0o600)
            header.write_text("\n".join(lines) + "\n")
            body.touch(mode=0o600)
            body.write_bytes(payload if isinstance(payload, bytes) else json.dumps(payload or {"text": "probe"}).encode())
            # -q first ignores ~/.curlrc; redirects, proxies and verbose output are never enabled.
            argv = ["curl", "-q", "--silent", "--show-error", "--noproxy", "*", "--connect-timeout", "10",
                    "--max-time", "30", "--request", method, "--header", "@" + str(header),
                    "--dump-header", str(headers), "--output", str(output), "--write-out", "%{http_code}"]
            if method != "GET":
                argv += ["--data-binary", "@" + str(body)]
            if origin:
                parsed = urlsplit(self.base)
                address = str(ipaddress.ip_address(origin))
                if ":" in address:
                    address = "[" + address + "]"
                argv += ["--resolve", f"{parsed.hostname}:{parsed.port or 443}:{address}"]
            result = subprocess.run([*argv, self.base + path], capture_output=True, timeout=35)
            if result.returncode:
                raise ValueError("curl transport failed (details withheld)")
            raw_headers = headers.read_bytes()
            raw_body = output.read_bytes()
            # A misconfigured proxy could echo the key. Refuse before persisting any evidence.
            if self.key.encode() in raw_headers + raw_body:
                raise ValueError("response exposed the key; evidence withheld")
            blocks = re.split(rb"\r?\n\r?\n", raw_headers.strip())
            fields = {}
            for line in blocks[-1].splitlines()[1:]:
                if b":" in line:
                    k, v = line.split(b":", 1)
                    fields[k.decode().lower()] = v.strip().decode("utf-8", "replace")
            return {"status": int(result.stdout), "headers": fields,
                    "raw_headers": raw_headers.decode("utf-8", "replace"),
                    "body_b64": base64.b64encode(raw_body).decode()}


def expected(response, status, kind, body):
    if response["status"] != status or response["headers"].get("content-type", "").split(";", 1)[0].strip().lower() != kind:
        return False
    raw = base64.b64decode(response["body_b64"])
    if kind == "application/json":
        try:
            obj = json.loads(raw)
        except (ValueError, UnicodeError):
            return False
        if not isinstance(obj, dict) or any(obj.get(k) != v for k, v in body.items()):
            return False
        return status != 202 or (isinstance(obj.get("delivery"), str) and bool(obj["delivery"]))
    return bool(re.search(rb"<(?:!doctype\s+html|html)\b", raw, re.I) and str(status).encode() in raw)


class Probe:
    def __init__(self, box, profile, base, origin, shared, port, access_log, error_log, presence_log,
                 evidence, message_status=202, delivery_timeout=300, pause=time.sleep, dns_only=False):
        self.box, self.profile, self.base, self.origin = box, profile, base, origin
        self.shared, self.port = shared, port
        self.logs = [access_log, error_log, presence_log]
        self.evidence, self.message_status = Path(evidence), message_status
        self.delivery_timeout, self.pause = delivery_timeout, pause
        self.records, self.deliveries, self.rays = [], [], []
        self.key = None
        self.dns_only = dns_only

    def record(self, check, ok, **details):
        self.records.append({"at": datetime.now(timezone.utc).isoformat(), "check": check,
                             "ok": bool(ok), **details})
        if not ok:
            raise ValueError(check + " failed")

    def check(self, label, client, path, status, kind="application/json", body=None, cloud=False, **request):
        response = client.request(path, **request)
        ray = response["headers"].get("cf-ray", "")
        ok = expected(response, status, kind, body or {}) and (bool(ray) != self.dns_only if cloud else True)
        self.record(label, ok, response=response, request={"path": path, "method": request.get("method", "POST"),
                    "auth": request.get("auth", "valid"), "origin": bool(request.get("origin")),
                    "chunked": request.get("chunked", False)})
        if status == 202:
            self.deliveries.append(json.loads(base64.b64decode(response["body_b64"]))["delivery"])
        return ray

    def matrix(self, client, path, prefix, cloud=False, origin=None):
        p = path.rsplit("/", 1)[0]
        absent = f"/swarmhub/webhook/{self.profile}/absent-{secrets.token_hex(8)}/x"
        pending = {"status": "pending", "profile": self.profile}
        error = lambda text: {"error": text}
        common = {"cloud": cloud, "origin": origin}
        try:
            a = self.check(prefix + ".a", client, path, 202, body=pending, **common)
        except ValueError:
            if cloud and self.records[-1].get("response", {}).get("status") == 400:
                response = client.request(absent, auth="probe")
                self.records.append({"check": prefix + ".e", "ok": False, "response": response,
                                     "request": {"path": absent, "method": "POST", "auth": "probe"}})
                stripped = expected(response, 400, "application/json", error("bad request"))
                self.records.append({"check": "diagnosis", "ok": False, "reason":
                                     "header stripped; use body-key or DNS-only fallback" if stripped else
                                     "unexpected Cloudflare response; investigate"})
            raise
        self.check(prefix + ".b", client, path, 400, auth="none", body=error("bad request"), **common)
        self.check(prefix + ".c", client, path, 403, auth="wrong", body=error("webhook rejected"), **common)
        self.check(prefix + ".d", client, p + "/wrongslug", 403, body=error("webhook rejected"), **common)
        e = self.check(prefix + ".e", client, absent, 404, auth="probe", body=error("unknown webhook"), **common)
        if cloud:
            self.rays = [a, e]
        return absent

    def negatives(self, client, path, prefix, cloud=False, origin=None):
        common = {"cloud": cloud, "origin": origin}
        self.check(prefix + ".health", client, "/swarmhub/webhook/health", 404, "text/html", method="GET", **common)
        for method in ("GET", "PUT"):
            self.check(prefix + "." + method, client, path, 403, "text/html", method=method, **common)
        # Valid JSON plus whitespace isolates the length limit from JSON/text validation.
        small = json.dumps({"text": "probe"}).encode()
        self.check(prefix + ".33KB", client, path, 413, "text/html", payload=small.ljust(33000, b" "), **common)
        self.check(prefix + ".chunked", client, path, 202, chunked=True, body={"status": "pending"}, **common)
        self.check(prefix + ".message", client, path, self.message_status, payload={"message": "probe"},
                   body={"status": "pending"} if self.message_status == 202 else {"error": "bad request"}, **common)
        if origin:
            self.check(prefix + ".32500B", client, path, 400, payload=small.ljust(32500, b" "),
                       body={"error": "bad request"}, **common)

    def last_hop(self):
        deadline = time.monotonic() + self.delivery_timeout
        while True:
            states = self.box.rpc("receipts", profile=self.profile, deliveries=self.deliveries)
            if len(states) == len(self.deliveries) and all(row == ["delivered", "received"] for row in states):
                return self.record("V5", True, deliveries=self.deliveries, states=states)
            if time.monotonic() >= deadline:
                return self.record("V5", False, deliveries=self.deliveries, states=states)
            self.pause(1)

    def save(self):
        self.evidence.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        data = json.dumps({"schema": "swarmhub/webhook-probe/1", "profile": self.profile,
                           "transport": "dns-only" if self.dns_only else "cloudflare",
                           "message_status": self.message_status,
                           "checks": self.records}, indent=2).encode()
        if self.key and self.key.encode() in data:
            raise ValueError("key in evidence; refused")
        # Never overwrite a previous verifier's evidence.
        fd = os.open(self.evidence, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as fd:
            fd.write(data)

    def run(self):
        routine = "canary-" + datetime.now(timezone.utc).strftime("%Y%m%d") + "-" + secrets.token_hex(6)
        registered = False
        try:
            config = self.box.system("nginx", "-T")
            self.record("V1", config_checks(config, urlsplit(self.base).hostname, self.profile, self.port),
                        config_sha256=hashlib.sha256(config.encode()).hexdigest())
            # Mark before the RPC: if registration's reply is lost, cleanup is still attempted.
            registered = True
            record = self.box.rpc("register", profile=self.profile, routine=routine)
            self.key = record["key"]
            client = Curl(self.base, self.key)
            path = f"/swarmhub/webhook/{self.profile}/{routine}/{record['slug']}"
            absent = self.matrix(client, path, "V2", origin=self.origin)
            # This request must execute on the box, not on the ovh caller's loopback.
            response = self.box.run(["python3", "-B", str(Path(self.box.checkout) / "ops/webhook-probe"),
                                     "--wrong-account", self.profile, "--path", absent])
            response = json.loads(response)
            self.record("V2.f", expected(response, 400, "application/json", {"error": "bad request"}), response=response,
                        request={"path": absent, "method": "POST", "auth": "probe", "on_box": True, "port": 8745})
            self.matrix(client, path, "V3", cloud=True)
            if self.dns_only:
                self.record("V4", True, not_applicable="DNS-only host; no Cloudflare rays")
            else:
                presence = self.box.read(self.logs[2])
                matches = [line for line in presence.splitlines() if any(line.split() == [ray, "present"] for ray in self.rays)]
                self.record("V4", all(any(line.split() == [ray, "present"] for line in matches) for ray in self.rays),
                            rays=self.rays, presence=matches)
            self.negatives(client, path, "V6.origin", origin=self.origin)
            self.negatives(client, path, "V6.cloudflare", cloud=True)
            self.last_hop()
        except Exception:
            self.records.append({"check": "failure", "ok": False})
            raise
        finally:
            try:
                if registered:
                    self.box.rpc("delete", profile=self.profile, routine=routine)
                    self.records.append({"check": "cleanup.canary", "ok": True})
            finally:
                try:
                    if self.key:
                        for index, log in enumerate(self.logs):
                            content = self.box.read(log)
                            self.record("V6.log." + str(index), self.key not in content,
                                        sha256=hashlib.sha256(content.encode()).hexdigest())
                finally:
                    self.save()


def verify_evidence(path):
    data = json.loads(Path(path).read_text())
    checks = {row["check"]: row for row in data["checks"]}
    if data.get("transport") not in ("cloudflare", "dns-only"):
        return False
    dns_only = data["transport"] == "dns-only"
    message_status = data.get("message_status")
    if message_status not in (400, 202):
        return False
    required = {"V1", "V2.f", "V4", "V5", "cleanup.canary", "V6.log.0", "V6.log.1", "V6.log.2"}
    for prefix in ("V2", "V3"):
        for case, status, body in (("a", 202, {"status": "pending"}), ("b", 400, {"error": "bad request"}),
                                   ("c", 403, {"error": "webhook rejected"}), ("d", 403, {"error": "webhook rejected"}),
                                   ("e", 404, {"error": "unknown webhook"})):
            key = prefix + "." + case
            required.add(key)
            response = checks.get(key, {}).get("response", {})
            if not response or not expected(response, status, "application/json", body):
                return False
            if prefix == "V3" and bool(response["headers"].get("cf-ray")) == dns_only:
                return False
            request = checks[key].get("request", {})
            if request.get("method") != "POST" or not re.fullmatch(
                    r"/swarmhub/webhook/" + re.escape(data["profile"]) + r"/[^/]+/[^/]+", request.get("path", "")):
                return False
            if case == "e" and (request.get("auth") != "probe" or "/absent-" not in request["path"]):
                return False
            if case == "b" and request.get("auth") != "none":
                return False
    for prefix in ("V6.origin", "V6.cloudflare"):
        for case, status, kind, body in (("health", 404, "text/html", {}), ("GET", 403, "text/html", {}),
                                       ("PUT", 403, "text/html", {}), ("33KB", 413, "text/html", {}),
                                       ("chunked", 202, "application/json", {"status": "pending"})):
            key = prefix + "." + case
            required.add(key)
            response = checks.get(key, {}).get("response")
            if not response or not expected(response, status, kind, body):
                return False
            if prefix.endswith("cloudflare") and bool(response["headers"].get("cf-ray")) == dns_only:
                return False
        key = prefix + ".message"
        required.add(key)
        response = checks.get(key, {}).get("response")
        if not response or not expected(response, message_status, "application/json",
                {"status": "pending"} if message_status == 202 else {"error": "bad request"}):
            return False
        if prefix.endswith("cloudflare") and bool(response["headers"].get("cf-ray")) == dns_only:
            return False
    required.add("V6.origin.32500B")
    for key, status, body in (("V2.f", 400, {"error": "bad request"}),
                              ("V6.origin.32500B", 400, {"error": "bad request"})):
        response = checks.get(key, {}).get("response")
        if not response or not expected(response, status, "application/json", body):
            return False
    v4, v5 = checks.get("V4", {}), checks.get("V5", {})
    if dns_only:
        if v4.get("not_applicable") != "DNS-only host; no Cloudflare rays":
            return False
    else:
        rays = [checks["V3." + case]["response"]["headers"]["cf-ray"] for case in ("a", "e")]
        if v4.get("rays") != rays or not all(any(line.split() == [ray, "present"] for line in v4.get("presence", [])) for ray in rays):
            return False
    delivered = [json.loads(base64.b64decode(row["response"]["body_b64"]))["delivery"]
                 for row in checks.values() if row.get("response", {}).get("status") == 202]
    if v5.get("deliveries") != delivered:
        return False
    if not v5.get("deliveries") or len(v5["deliveries"]) != len(v5.get("states", [])) or not all(
            state == ["delivered", "received"] for state in v5["states"]):
        return False
    return (data.get("schema") == "swarmhub/webhook-probe/1" and required <= checks.keys()
            and all(row.get("ok") is True for row in checks.values()))

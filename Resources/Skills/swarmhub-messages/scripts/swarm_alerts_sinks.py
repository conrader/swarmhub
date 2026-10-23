"""Where an off-app alert goes: ntfy (default) and optional SMTP email. Each sink is one function
`send(settings, title, body) -> None` that raises on failure; `deliver` runs every configured sink and returns
{"ntfy": "sent" | "error: …", "email": …}. Error text is passed through `redact` so a token or password never
reaches the status, a log line or the app.
"""
import email.message
import smtplib
import ssl
import urllib.error
import urllib.parse
import urllib.request

TIMEOUT = 15
LOCAL = ("127.0.0.1", "localhost", "::1")


def secrets(config):
    return [value for value in ((config.get("ntfy") or {}).get("token"), (config.get("email") or {}).get("password"))
            if isinstance(value, str) and value]


def redact(text, config):
    text = str(text)[:300]
    for value in secrets(config):
        text = text.replace(value, "…")
    return text


def check_ntfy(settings):
    parts = urllib.parse.urlsplit(settings.get("url", ""))
    if parts.scheme not in ("https", "http") or not parts.hostname or parts.query or parts.fragment or parts.username:
        raise ValueError("ntfy needs a topic URL like https://ntfy.sh/your-topic")
    if parts.scheme == "http" and parts.hostname not in LOCAL:
        raise ValueError("ntfy over plain http is only allowed on this box (127.0.0.1)")
    if not parts.path.strip("/"):
        raise ValueError("the ntfy URL needs a topic: https://ntfy.sh/your-topic")
    token = settings.get("token") or ""
    if not isinstance(token, str) or any(c.isspace() for c in token) or len(token) > 512:
        raise ValueError("the ntfy token is not usable")


def check_email(settings):
    for field in ("host", "from", "to"):
        if not isinstance(settings.get(field), str) or not settings[field].strip() or len(settings[field]) > 320:
            raise ValueError(f"email needs {field}")
    if settings.get("security", "starttls") not in ("starttls", "ssl", "none"):
        raise ValueError("email security is starttls, ssl or none")
    if settings.get("security") == "none" and settings["host"] not in LOCAL:
        raise ValueError("unencrypted SMTP is only allowed to a relay on this box (127.0.0.1)")
    port = settings.get("port", 587)
    if type(port) is not int or not 0 < port < 65536:
        raise ValueError("email port must be a number")
    if any("\n" in str(settings.get(f, "")) or "\r" in str(settings.get(f, "")) for f in ("from", "to", "user")):
        raise ValueError("email addresses must be one line")


def ntfy(settings, title, body):
    request = urllib.request.Request(settings["url"], data=body.encode("utf-8"), method="POST")
    # Header values must be latin-1; ntfy reads an RFC 2047 title as well, but a plain fallback keeps it simple.
    request.add_header("Title", title.encode("ascii", "replace").decode()[:200])
    request.add_header("Tags", "robot")
    if settings.get("priority") in ("min", "low", "default", "high", "urgent"):
        request.add_header("Priority", settings["priority"])
    if settings.get("token"):
        request.add_header("Authorization", "Bearer " + settings["token"])
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}) if urllib.parse.urlsplit(settings["url"]).hostname
                                         in LOCAL else urllib.request.ProxyHandler())
    try:
        with opener.open(request, timeout=TIMEOUT) as response:
            response.read(4096)
    except urllib.error.HTTPError as exc:
        raise ValueError(f"ntfy answered HTTP {exc.code}") from None
    except (urllib.error.URLError, OSError) as exc:
        raise ValueError("ntfy unreachable: " + str(getattr(exc, "reason", exc))) from None


def smtp(settings, title, body):
    message = email.message.EmailMessage()
    message["Subject"], message["From"], message["To"] = title[:200], settings["from"], settings["to"]
    message.set_content(body)
    host, port, security = settings["host"], settings.get("port", 587), settings.get("security", "starttls")
    context = ssl.create_default_context()
    try:
        if security == "ssl":
            client = smtplib.SMTP_SSL(host, port, timeout=TIMEOUT, context=context)
        else:
            client = smtplib.SMTP(host, port, timeout=TIMEOUT)
        with client:
            if security == "starttls":
                client.starttls(context=context)
            if settings.get("user"):
                client.login(settings["user"], settings.get("password") or "")
            client.send_message(message)
    except smtplib.SMTPAuthenticationError:
        raise ValueError("the mail server refused the login") from None
    except (smtplib.SMTPException, OSError, ssl.SSLError) as exc:
        raise ValueError("mail not sent: " + type(exc).__name__ + (f" ({exc})" if str(exc) else "")) from None


SINKS = {"ntfy": ntfy, "email": smtp}


def deliver(config, title, body, sinks=None):
    """Send to every configured sink; one result line per sink."""
    results = {}
    for name, send in (sinks or SINKS).items():
        settings = config.get(name)
        if not settings:
            continue
        try:
            send(settings, title, body)
            results[name] = "sent"
        except Exception as exc:  # noqa: BLE001  One sink failing never stops the other.
            results[name] = "error: " + redact(exc, config)
    return results

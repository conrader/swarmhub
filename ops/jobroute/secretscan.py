"""Secret-shaped values in text: one place for the patterns, used by every net.

crm.redact() (the generator), bin/sb-ermes audit() (the check before a page
lands) and bin/sb-lint (the sweep over the whole wiki) all call this module, so
a form one of them learns is a form all of them catch. Before 2026-10-08 each
had its own regex, and all of them only knew `key: value` / `key=value`: the
free-text "credentials user X / password Y" form slipped through and a live
credential sat on wiki/personal/context.md for seven weeks.

Named secretscan, not secrets, so running a lib/sbscan file directly can never
shadow the stdlib `secrets` module.

Three forms, plus the vendor token shapes:
  * kv    -- `pitch_password: x`, `api_key=x`, `hasło: x`, `pass: x`. The
             keyword may sit inside a compound key. The value is taken as a
             secret unless it is a stopword, a placeholder, a path/URL/env
             reference or a short number (`max_tokens: 4096` is not a leak).
  * free  -- "password Abc123", "hasło Qwerty1". "hasło" is also Polish for
             slogan and "password manager" is prose, so the value must LOOK
             like a secret: a digit, a symbol, or mixed case.
  * pair  -- "credentials user X / password Y", "login X / hasło Y". The
             explicit pairing is evidence enough; only a stopword clears Y.
"""
from __future__ import annotations

import pathlib
import re
from typing import NamedTuple

REPLACEMENT = "‹stored in password manager›"

_KEYWORD = (r"(?:password|passwd|pwd|has[lł]o|haslo|token|secret|api[_-]?key|klucz|"
            r"credential)")
# A value never starts with a backtick (a `password:` pattern description), a
# quote's partner, or ‹ (already redacted).
_VALUE = r"[^\s\"'„”“`‹,;)\]}|]+"

# The keyword must END the key (`pitch_password`, `accessToken`, `secret_key`):
# a keyword mid-word is prose or another field -- `TOKEN_LIMITS_MODE=enforce`,
# Polish `kluczowych:`, `wykluczone:`, `tokenu =`.
_KV = re.compile(
    rf"(?<![\w-])(?P<key>[A-Za-z_]*{_KEYWORD}(?:[_-]?key)?s?|pass)(?![\w])"
    rf"(?:\*\*)?[ \t]*[:=][ \t]*(?:\*\*)?[\"'„“]?(?P<val>{_VALUE})", re.I)
# A bare keyword before a colon is often a prose label ("a real ingest pass:
# read…", "Hasło: kampania…"); only a compound key is specific enough to take
# any non-stopword value on trust.
_BARE = frozenset("""pass pwd password passwords passwd hasło haslo token tokens
secret secrets klucz credential credentials""".split())
_FREE = re.compile(
    rf"(?<![\w-])(?P<key>password|passwd|has[lł]o|haslo)[ \t]+[\"'„“]?(?P<val>{_VALUE})",
    re.I)
_PAIR = re.compile(
    r"(?<![\w-])(?P<lead>credentials?|login|dane logowania)[ \t:]+"
    r"(?:(?:user(?:name)?|login|użytkownik|uzytkownik)[ \t:]+)?[^\s/]+[ \t]*/[ \t]*"
    rf"(?P<key>password|passwd|has[lł]o|haslo|pass)(?![\w])(?:[ \t]*[:=])?[ \t]*[\"'„“]?"
    rf"(?P<val>{_VALUE})", re.I)
# Vendor shapes: a JWT, OpenAI/GitHub/Slack/Meta tokens.
# Vendor shapes: a JWT, OpenAI/GitHub/Slack/Meta tokens. Not mid-word: page
# slugs like `zgloszenia-de-cz-sk-bitelab-…` and `aifirstdesk-audyt-…` are not keys.
_TOKEN = re.compile(r"(?<![\w-])(?:eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_.-]*|"
                    r"(?:sk-|ghp_|xox[baprs]-|EAA)[A-Za-z0-9_-]{16,})")

# Words that follow a secret keyword in prose or config, never as the secret.
STOPWORDS = frozenset("""
true false null none nil yes no na tbd todo empty required optional unset set
redacted hidden masked stored storage store manager reset recovery recover policy
change changed changes protected field fields hash hashed expired expires expiry
rotated rotation rotate vault sejf sejfie env file str string int bool any value
values placeholder example missing ok was is are be been were for to of the and
or in on at with from by via see as it this that not here there only
do w i z na jest nie brak został zostało została zostały dla oraz albo lub przez
menedżer menedzer menedżerze menedzerze zmiana zmienić resetu reset
login logowania user username użytkownik uzytkownik email mail
unknown unverified nieznany nieznane nieznana
""".split())


class Hit(NamedTuple):
    start: int
    end: int       # the span to replace (value only for kv/free, whole for pair)
    key: str       # the keyword that introduced it -- safe to print
    kind: str      # kv | free | pair | token


def _core(val: str) -> str:
    # Markdown emphasis/code marks around a value are formatting, not part of it:
    # "tokens: unknown.**" must read as the word "unknown", not a symbol-laden value.
    return val.strip("\"'„”“‚’()[]<>*_`~").rstrip(".,;:").strip("*_`~")


def _is_stopword(val: str) -> bool:
    word = re.sub(r"[^\w]", "", _core(val)).lower()
    return not word or word in STOPWORDS


def _looks_secret(val: str) -> bool:
    """A digit, a symbol (hyphen and apostrophes are prose), or mixed case."""
    v = _core(val)
    if any(c.isdigit() for c in v):
        return True
    if any(not c.isalnum() and c not in "-'’" for c in v):
        return True
    return any(c.islower() for c in v) and any(c.isupper() for c in v[1:])


def _kv_ok(val: str) -> bool:
    v = _core(val)
    if len(v) < 4 or _is_stopword(v):
        return False
    if v.startswith(("/", "~", "http", "$", "{", "<", "%", "…", "...", "*")):
        return False  # a path, URL, env/template reference or placeholder
    if re.fullmatch(r"[\d.,]+[kKmM]?", v) and len(v) <= 7:
        return False  # a count: `tokens: 240`, `max_tokens: 4096`
    return True


def _trim(m: re.Match, start: int) -> tuple[int, int]:
    """Span of the value without trailing sentence punctuation."""
    end = m.end("val")
    while end > start and m.string[end - 1] in ".:":
        end -= 1
    return start, end


def find(text: str, aggressive: bool = False) -> list[Hit]:
    """Every secret-shaped value in text, leftmost first, non-overlapping.

    aggressive=True also takes any non-stopword value after a bare keyword
    (`password: sunflower`). The generator redacts that way -- a prose label
    blanked on a CRM page costs nothing -- while lint and audit stay strict so
    the wiki-wide sweep reports leaks, not every "Hasło:" heading."""
    hits: list[Hit] = []
    for m in _PAIR.finditer(text):
        if not _is_stopword(m.group("val")):
            s, e = _trim(m, m.start())
            hits.append(Hit(m.end("lead"), e, m.group("key").lower(), "pair"))
    for m in _KV.finditer(text):
        val, key = m.group("val"), m.group("key").lower()
        if key in _BARE and not (aggressive and key != "pass") \
                and not _looks_secret(val):
            continue
        if _kv_ok(val):
            s, e = _trim(m, m.start("val"))
            hits.append(Hit(s, e, m.group("key"), "kv"))
    for m in _FREE.finditer(text):
        val = m.group("val")
        if len(_core(val)) >= 6 and not _is_stopword(val) and _looks_secret(val):
            s, e = _trim(m, m.start("val"))
            hits.append(Hit(s, e, m.group("key").lower(), "free"))
    for m in _TOKEN.finditer(text):
        hits.append(Hit(m.start(), m.end(), m.group(0)[:3], "token"))
    # Overlaps (a pair contains a free match) resolve to the earliest, widest.
    hits.sort(key=lambda h: (h.start, -h.end))
    out: list[Hit] = []
    for h in hits:
        if out and h.start < out[-1].end:
            continue
        out.append(h)
    return out


def redact(text: str, aggressive: bool = True) -> str:
    """text with every secret-shaped value replaced; idempotent."""
    for h in reversed(find(text, aggressive)):
        sep = " " if h.kind == "pair" else ""
        text = text[:h.start] + sep + REPLACEMENT + text[h.end:]
    return text


def scan_tree(root: pathlib.Path) -> list[str]:
    """sb-lint's sweep: `path:line: <kind> after '<key>'` -- never the value --
    for wiki/**/*.md and index.md under root."""
    root = pathlib.Path(root)
    files = sorted((root / "wiki").rglob("*.md"))
    if (root / "index.md").is_file():
        files.append(root / "index.md")
    found = []
    for path in files:
        text = path.read_text(errors="replace")
        for h in find(text):
            line = text.count("\n", 0, h.start) + 1
            found.append(f"{path.relative_to(root)}:{line}: secret-shaped value "
                         f"({h.kind}) after '{h.key}'")
    return found

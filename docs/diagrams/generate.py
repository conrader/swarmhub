#!/usr/bin/env python3
"""Writes the architecture diagrams in docs/diagrams/ as SVG, in a light and a dark version.

    python3 docs/diagrams/generate.py            # the SVG files
    python3 docs/diagrams/generate.py --png      # also PNG renders (needs google-chrome or chromium, and Pillow)
    python3 docs/diagrams/generate.py --png overview message-flow    # only the drawings named

Every box and arrow stands for something in the code; docs/architecture.md says what. Colours mean the same in
all four drawings: orange is what you send on its way to an agent, green is what an agent sends back, grey is the rest.
The drawing uses the system font of whoever looks at it, so boxes leave room for wider letters.
"""
import html
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent.parent
SANS = "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', Helvetica, Arial, sans-serif"
MONO = "ui-monospace, 'SF Mono', SFMono-Regular, Menlo, Consolas, 'Liberation Mono', monospace"

THEMES = {
    "light": dict(card="#f7f7f2", zone="#ffffff", zone_line="#e2e3d9", node="#f7f7f2", node_line="#d9dace",
                  text="#262821", soft="#676a5f", line="#8d9085", send="#cf4a22", back="#4f7040",
                  chip="#ecede4", ghost="#b9bbb0", tile="#f7f7f2", tile_line="#d9dace"),
    "dark": dict(card="#191a16", zone="#21231e", zone_line="#33362e", node="#2a2c26", node_line="#41443b",
                 text="#f2f2ec", soft="#a6a99d", line="#80837a", send="#ff8a61", back="#a8c9a0",
                 chip="#33362e", ghost="#565950", tile="#f7f7f2", tile_line="#f7f7f2"),
}


# Every letter is drawn this much larger than the sizes below say, so the drawings stay readable at a README's width.
LARGER = 1.08


def width(text, size, mono=False, bold=False):
    """A cautious guess at how wide `text` is drawn: a little wider than Helvetica, for San Francisco."""
    size *= LARGER
    if mono:
        return len(text) * size * 0.62
    wide = sum(1 for c in text if c in "mwMW@") * 0.3 + sum(1 for c in text if c.isupper()) * 0.12
    narrow = sum(1 for c in text if c in "ilj.,:;'|!·() ") * 0.26
    return (len(text) * 0.56 + wide - narrow) * size * (1.06 if bold else 1.0)


class Drawing:
    def __init__(self, name, w, h, title, desc, theme):
        self.name, self.w, self.h, self.title, self.desc = name, w, h, title, desc
        self.t = THEMES[theme]
        self.theme = theme
        self.out = []
        self.problems = []

    # --- shapes -----------------------------------------------------------------------------------------------
    def zone(self, x, y, w, h, label, note=None, dashed=False, bottom=False):
        dash = ' stroke-dasharray="5 5"' if dashed else ""
        self.out.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="18" fill="{self.t["zone"]}" stroke="{self.t["zone_line"]}"{dash}/>')
        base = y + h - 18 if bottom else y + 27
        self.text(x + 20, base, label.upper(), size=11.5, weight=700, fill=self.t["soft"], spacing=1.1)
        if note:
            self.text(x + w - 20, base, note, size=12, fill=self.t["soft"], anchor="end")
            if width(label.upper(), 11.5, bold=True) + 1.1 * len(label) + width(note, 12) > w - 52:
                self.problems.append(f"zone label and note collide: {label}")

    def node(self, x, y, w, h, title, lines=(), mono=(), ghost=False, mark=False, star=False):
        t = self.t
        dash = ' stroke-dasharray="5 4"' if ghost else ""
        fill = "none" if ghost else t["node"]
        self.out.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="12" fill="{fill}" stroke="{t["ghost"] if ghost else t["node_line"]}"{dash}/>')
        tx = x + 14
        if mark:
            self.mark(x + 12, y + 10, 30)
            tx = x + 52
        colour = t["soft"] if ghost else t["text"]
        self.text(tx, y + 25 + (5 if mark else 0), title, size=14.5, weight=600, fill=colour)
        used = width(title, 14.5, bold=True)
        if star:
            sx = tx + used + 9
            self.out.append(f'<path transform="translate({sx:.1f} {y + 20 + (5 if mark else 0)})" d="M0-7.6 2.2-2.4 7.8-2 3.5 1.7 4.8 7.2 0 4.2-4.8 7.2-3.5 1.7-7.8-2-2.2-2.4Z" fill="{t["send"]}"/>')
            used += 22
        if tx - x + used > w - 10:
            self.problems.append(f"title too wide: {title}")
        ly = y + 46 + (8 if mark else 0)
        for line in lines:
            self.text(x + 14, ly, line, size=12.5, fill=t["soft"])
            if 14 + width(line, 12.5) > w - 8:
                self.problems.append(f"line too wide in '{title}': {line}")
            ly += 18
        for line in mono:
            self.text(x + 14, ly, line, size=11.5, fill=t["soft"], family=MONO)
            if 14 + width(line, 11.5, mono=True) > w - 8:
                self.problems.append(f"mono line too wide in '{title}': {line}")
            ly += 18
        if ly - 18 > y + h - 8:
            self.problems.append(f"too many lines in '{title}'")

    def chip(self, x, y, label, mono=True, anchor="start"):
        """A small label on a filled pill, for a command or a route."""
        size = 11.5
        w = width(label, size, mono=mono) + 16
        left = x if anchor == "start" else (x - w if anchor == "end" else x - w / 2)
        self.out.append(f'<rect x="{left:.1f}" y="{y - 14}" width="{w:.1f}" height="20" rx="6" fill="{self.t["chip"]}"/>')
        self.text(left + 8, y, label, size=size, fill=self.t["text"], family=MONO if mono else SANS)
        return w

    def text(self, x, y, s, size=13, weight=400, fill=None, anchor="start", family=SANS, spacing=None, italic=False, halo=None):
        extra = (f' letter-spacing="{spacing}"' if spacing else "") + (' font-style="italic"' if italic else "")
        if halo:  # keeps a label readable where a line runs behind it
            extra += f' stroke="{halo}" stroke-width="6" stroke-linejoin="round" paint-order="stroke"'
        self.out.append(f'<text x="{x:.1f}" y="{y:.1f}" font-family="{family}" font-size="{size * LARGER:.2f}" font-weight="{weight}" '
                        f'fill="{fill or self.t["text"]}" text-anchor="{anchor}"{extra}>{html.escape(s)}</text>')

    def label(self, x, y, s, kind="line", anchor="middle", mono=False, size=12, halo=None):
        colour = {"send": self.t["send"], "back": self.t["back"], "line": self.t["soft"], "text": self.t["text"]}[kind]
        self.text(x, y, s, size=size if not mono else 11.5, fill=colour, anchor=anchor, family=MONO if mono else SANS, weight=500,
                  halo=self.t[halo] if halo else None)

    def arrow(self, points, kind="line", dashed=False, both=False, head=True):
        colour = {"send": self.t["send"], "back": self.t["back"], "line": self.t["line"]}[kind]
        d = "M" + " L".join(f"{x:.1f} {y:.1f}" for x, y in rounded(points))
        dash = ' stroke-dasharray="5 4"' if dashed else ""
        end = f' marker-end="url(#head-{kind})"' if head else ""
        start = f' marker-start="url(#tail-{kind})"' if both else ""
        self.out.append(f'<path d="{d}" fill="none" stroke="{colour}" stroke-width="1.6" stroke-linejoin="round" stroke-linecap="round"{dash}{end}{start}/>')

    def line(self, x1, y1, x2, y2, dashed=True):
        dash = ' stroke-dasharray="3 5"' if dashed else ""
        self.out.append(f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{self.t["zone_line"]}" stroke-width="1.4"{dash}/>')

    def mark(self, x, y, size):
        """The app's mark (Resources/AppIcon/SwarmHub-mark.svg) on a cream tile, as the icon shows it."""
        source = (ROOT / "Resources/AppIcon/SwarmHub-mark.svg").read_text()
        inner = re.search(r"<svg[^>]*>(.*)</svg>", source, re.S).group(1)
        inner = re.sub(r"<title>.*?</title>", "", inner, flags=re.S)
        box = re.search(r'viewBox="([^"]+)"', source).group(1)
        r = size * 0.26
        self.out.append(f'<rect x="{x}" y="{y}" width="{size}" height="{size}" rx="{r:.1f}" fill="{self.t["tile"]}" stroke="{self.t["tile_line"]}"/>')
        pad = size * 0.1
        self.out.append(f'<svg x="{x + pad:.1f}" y="{y + pad:.1f}" width="{size - 2 * pad:.1f}" height="{size - 2 * pad:.1f}" viewBox="{box}">{inner}</svg>')

    def legend(self, x, y, items):
        for kind, words in items:
            self.arrow([(x, y - 4), (x + 30, y - 4)], kind)
            self.text(x + 40, y, words, size=12, fill=self.t["soft"])
            x += 40 + width(words, 12) + 30

    # --- output -----------------------------------------------------------------------------------------------
    def svg(self):
        t = self.t
        heads = "".join(
            f'<marker id="head-{k}" viewBox="0 0 10 10" refX="8.5" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">'
            f'<path d="M1 1.5 8.5 5 1 8.5" fill="none" stroke="{c}" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"/></marker>'
            f'<marker id="tail-{k}" viewBox="0 0 10 10" refX="8.5" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">'
            f'<path d="M1 1.5 8.5 5 1 8.5" fill="none" stroke="{c}" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"/></marker>'
            for k, c in (("send", t["send"]), ("back", t["back"]), ("line", t["line"])))
        body = "\n  ".join(self.out)
        return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{self.w}" height="{self.h}" viewBox="0 0 {self.w} {self.h}" role="img" aria-labelledby="t d">\n'
                f'  <title id="t">{html.escape(self.title)}</title>\n  <desc id="d">{html.escape(self.desc)}</desc>\n'
                f'  <defs>{heads}</defs>\n'
                f'  <rect width="{self.w}" height="{self.h}" rx="22" fill="{t["card"]}"/>\n  {body}\n</svg>\n')


def rounded(points, r=10):
    """The corners of a path of straight pieces, cut so that it reads as bent, not broken."""
    if len(points) < 3:
        return points
    out = [points[0]]
    for before, corner, after in zip(points, points[1:], points[2:]):
        for other in (before, after):
            dx, dy = other[0] - corner[0], other[1] - corner[1]
            length = max((dx * dx + dy * dy) ** 0.5, 0.001)
            cut = min(r, length / 2)
            out.append((corner[0] + dx / length * cut, corner[1] + dy / length * cut))
    out.append(points[-1])
    return out


# === 1. Who runs where =============================================================================================
def overview(d):
    # Your Mac
    d.zone(24, 70, 250, 420, "Your Mac")
    d.node(44, 112, 210, 110, "SwarmHub", ["The Mac app (SwiftUI)", "Bots and chats: store.json", "Access keys: Keychain"], mark=True)
    d.node(44, 266, 210, 72, "ssh port forward", ["Only for a server that is", "reached over SSH"])
    d.node(44, 394, 210, 72, "A browser", ["Optional: the workspace", "the bridge also serves"], ghost=True)

    # The Herdr server
    d.zone(366, 70, 430, 500, "The Herdr server", note="one OS account")
    d.node(386, 112, 390, 104, "SwarmHub bridge", ["HTTP API and events stream, loopback only", "Journal of tasks and replies (SQLite)"], mono=["swarmhub-herdr · 127.0.0.1:8787"])
    d.node(386, 284, 114, 72, "skillshare", ["Optional", "program"])
    d.node(606, 284, 170, 72, "Herdr Core", ["Runs agent programs", "in terminals"])
    d.node(386, 428, 390, 118, "Agent programs", ["One agent per bot, started from a Core template.", "Helpers: short-lived agents under a bot's agent."])
    d.chip(400, 526, "Claude Code", mono=False)
    d.chip(497, 526, "Codex", mono=False)
    d.chip(554, 526, "other templates", mono=False)

    # Other machines
    d.zone(864, 70, 192, 198, "Project servers")
    d.node(878, 112, 164, 132, "Your projects", ["Named folders.", "Core logs in with", "the Herdr server's", "own SSH key.", "Optional."])
    d.zone(864, 384, 192, 186, "Outside")
    d.node(878, 426, 164, 120, "Model providers", ["Each agent program", "signs in by itself.", "SwarmHub holds", "no model keys."])

    # You -> agent
    d.arrow([(254, 146), (386, 146)], "send")
    d.label(320, 122, "HTTP with", "send")
    d.label(320, 138, "access key", "send")
    d.arrow([(686, 216), (686, 284)], "send")
    d.label(694, 245, "JSON-RPC,", "send", anchor="start")
    d.label(694, 261, "Unix socket", "send", anchor="start")
    d.arrow([(686, 356), (686, 428)], "send")
    d.label(694, 388, "starts, types,", "send", anchor="start")
    d.label(694, 404, "interrupts", "send", anchor="start")
    # agent -> you
    d.arrow([(588, 428), (588, 216)], "back")
    d.label(579, 298, "hooks,", "back", anchor="end")
    d.label(579, 314, "helper and", "back", anchor="end")
    d.label(579, 330, "project", "back", anchor="end")
    d.label(579, 346, "commands", "back", anchor="end")
    d.arrow([(386, 180), (254, 180)], "back")
    d.label(320, 171, "events", "back")
    # the rest
    d.arrow([(149, 222), (149, 266)], "line")
    d.label(157, 249, "starts", "line", anchor="start")
    d.arrow([(254, 430), (296, 430), (296, 204), (386, 204)], "line", dashed=True)
    d.label(304, 318, "same", "line", anchor="start")
    d.label(304, 333, "API", "line", anchor="start")
    d.arrow([(438, 216), (438, 284)], "line")
    d.label(446, 254, "runs", "line", anchor="start")
    d.arrow([(438, 356), (438, 428)], "line")
    d.label(446, 388, "links skills", "line", anchor="start")
    d.label(446, 404, "into folders", "line", anchor="start")
    d.arrow([(776, 320), (820, 320), (820, 178), (878, 178)], "line")
    d.label(812, 338, "SSH", "line", anchor="end")
    d.arrow([(776, 486), (878, 486)], "line")
    d.label(827, 478, "own sign-in", "line")

    d.legend(24, 540, [("send", "what you send"), ("back", "what comes back")])
    d.text(24, 46, "Who runs where", size=20, weight=700)
    d.text(1056, 46, "This Mac can also be the Herdr server: then everything in the middle runs on it.", size=12.5, fill=d.t["soft"], anchor="end")


# === 2. One message, there and back ===============================================================================
def flow(d):
    lanes = [("Mac app", 230), ("Bridge and its journal", 500), ("Herdr Core", 740), ("Agent program", 960)]
    top, bottom = 96, 640
    for name, x in lanes:
        w = width(name, 13.5, bold=True) + 28
        d.line(x, top, x, bottom)
        d.out.append(f'<rect x="{x - w / 2:.1f}" y="{top - 30}" width="{w:.1f}" height="30" rx="10" fill="{d.t["node"]}" stroke="{d.t["node_line"]}"/>')
        d.text(x, top - 10, name, size=13.5, weight=600, anchor="middle")
    app, bridge, core, agent = (x for _, x in lanes)

    def phase(y1, y2, name):
        d.out.append(f'<rect x="24" y="{y1}" width="124" height="{y2 - y1}" rx="12" fill="{d.t["zone"]}" stroke="{d.t["zone_line"]}"/>')
        d.text(86, (y1 + y2) / 2 + 4, name.upper(), size=11.5, weight=700, fill=d.t["soft"], anchor="middle", spacing=1.1)

    def step(y, a, b, words, kind, mono=False, dashed=False):
        d.arrow([(a + (8 if b > a else -8), y), (b - (8 if b > a else -8), y)], kind, dashed=dashed)
        d.label((a + b) / 2, y - 8, words, kind, mono=mono, halo="card")

    def note(x, y, words):
        d.text(x, y, words, size=12, fill=d.t["soft"], anchor="middle", italic=True, halo=d.t["card"])

    phase(112, 256, "Send")
    step(138, app, bridge, "POST /api/agents/…/messages", "send", mono=True)
    note(bridge, 166, "saves the task")
    step(190, bridge, core, "terminal.send", "send", mono=True)
    step(190, core, agent, "types the text", "send")
    note((app + bridge) / 2, 226, "No agent yet? POST /api/agents starts")
    note((app + bridge) / 2, 242, "one: instructions first, then the message.")
    step(234, bridge, core, "terminal.run", "send", mono=True, dashed=True)

    phase(268, 440, "Stream")
    step(296, app, bridge, "GET /api/agents/…/events", "send", mono=True)
    step(328, bridge, app, "snapshot", "back", mono=True)
    step(366, agent, bridge, "tool hooks: each tool call, as it starts and ends", "back")
    step(366, bridge, app, "tool", "back", mono=True)
    step(412, agent, bridge, "the reply so far, as it is written", "back")
    step(412, bridge, app, "draft, draft_append", "back", mono=True)

    phase(452, 536, "Reply")
    step(482, agent, bridge, "Stop hook: saves the finished reply in the journal", "back")
    step(514, bridge, app, "history (the saved reply)", "back", mono=True)

    phase(548, 632, "Steer, stop")
    step(576, app, bridge, "POST …/messages, mid-answer", "send", mono=True)
    step(576, bridge, core, "terminal.send", "send", mono=True)
    step(576, core, agent, "typed into the answer", "send")
    step(612, app, bridge, "POST …/interrupt", "send", mono=True)
    step(612, bridge, core, "terminal.interrupt", "send", mono=True)
    step(612, core, agent, "its own stop key", "send")

    d.text(24, 46, "One message, there and back", size=20, weight=700)
    d.text(1056, 46, "When the stream cannot be used, the app polls /api/history and …/draft for the same rows.", size=12.5, fill=d.t["soft"], anchor="end")


# === 3. Bots, the main bot and helpers ============================================================================
def bots(d):
    d.zone(24, 70, 1032, 266, "In the Mac app", note="A bot is a record in the app. The app reads the swarmhub blocks in a finished reply and acts on them.", bottom=True)
    d.node(60, 138, 220, 92, "Main bot", ["One per server.", "Only it creates bots."], star=True)
    d.node(440, 138, 220, 92, "Bot", ["A name, instructions,", "agent program, model."])
    d.node(800, 138, 220, 92, "New bot", ["Added at once, or when", "you press Create."], ghost=True)

    d.arrow([(440, 166), (280, 166)], "send")
    d.chip(360, 156, "request_bot", anchor="middle")
    d.arrow([(280, 202), (440, 202)], "back")
    d.label(360, 220, "answer passed back", "back")
    words = "“decided”: added at once · “ask”: you choose"
    d.arrow([(170, 138), (170, 104), (430, 104)], "send", head=False)
    d.arrow([(540 + width(words, 12) + 10, 104), (910, 104), (910, 138)], "send")
    d.chip(480, 108, "create_bot", anchor="middle")
    d.label(540, 108, words, "line", anchor="start")
    d.arrow([(550, 230), (550, 268), (170, 268), (170, 230)], "line", both=True)
    d.chip(360, 272, "message_bot", anchor="middle")
    d.label(570, 262, "Passed on by the app and shown in both chats.", "line", anchor="start")
    d.label(570, 278, "Limits: 8 messages per pair, 6 per bot in 10 minutes.", "line", anchor="start")

    d.zone(24, 400, 1032, 212, "On the Herdr server", note="The agent names only a difficulty. The bridge picks the agent program and the model.", bottom=True)
    d.node(60, 428, 220, 76, "The main bot's agent", ["A terminal in Herdr Core"])
    d.node(330, 428, 220, 76, "The bot's agent", ["A terminal in Herdr Core"])
    d.node(650, 416, 216, 100, "Bridge", ["Checks the helper policy:", "difficulty → program, model,", "limits, no nested helpers"])
    d.node(908, 416, 128, 44, "Helper", [])
    d.node(908, 472, 128, 44, "Helper", [])
    d.arrow([(550, 450), (650, 450)], "send")
    d.label(600, 441, "asks", "send")
    d.arrow([(650, 484), (550, 484)], "back")
    d.label(600, 503, "the answer", "back")
    d.label(330, 548, "In its own shell, the agent runs", "line", anchor="start")
    d.chip(536, 548, "swarmhub-herdr helper start --difficulty hard \"TASK\"")
    d.arrow([(866, 446), (908, 440)], "send")
    d.arrow([(866, 486), (908, 494)], "send")
    d.label(887, 470, "starts", "send")

    d.arrow([(170, 336), (170, 428)], "line", both=True)
    d.arrow([(440, 336), (440, 428)], "line", both=True)
    d.label(460, 364, "One agent per bot, started on its first message", "line", anchor="start")
    d.label(460, 380, "or when its chat opens, and reused while it runs.", "line", anchor="start")

    d.text(24, 46, "Bots, the main bot and helpers", size=20, weight=700)


# === 4. Where bots run ============================================================================================
def deployment(d):
    def row_title(y, number, name, words):
        d.text(24, y, f"{number}  {name}", size=15, weight=700)
        d.text(24, y + 20, words, size=12.5, fill=d.t["soft"])

    core = ["Agent programs in terminals"]
    # 1 This Mac
    row_title(96, "1", "This Mac", "Everything runs on your Mac. The app reads the access key from the bridge's own file.")
    d.zone(24, 132, 1032, 124, "Your Mac")
    d.node(44, 168, 330, 68, "SwarmHub", ["Reads ~/.config/swarmhub-herdr/token"], mark=True)
    d.node(502, 168, 220, 68, "Bridge", mono=["127.0.0.1:8787"])
    d.node(776, 168, 260, 68, "Herdr Core", core)
    d.arrow([(374, 202), (502, 202)], "send")
    d.label(438, 192, "loopback", "send")
    d.arrow([(722, 202), (776, 202)], "send")

    # 2 SSH
    row_title(296, "2", "A server I reach over SSH", "The app runs the system ssh, keeps the forward open, and reads the access key from the server's file.")
    d.zone(24, 332, 400, 140, "Your Mac")
    d.node(44, 368, 360, 84, "SwarmHub", ["Starts and restarts the forward:"], mono=["ssh -N -L 127.0.0.1:8787:127.0.0.1:8787"], mark=True)
    d.zone(596, 332, 460, 140, "Your server")
    d.node(616, 368, 170, 84, "Bridge", mono=["127.0.0.1:8787"])
    d.node(816, 368, 220, 84, "Herdr Core", core)
    d.arrow([(404, 410), (616, 410)], "send")
    d.label(510, 386, "SSH, with your keys", "send")
    d.label(510, 401, "and known hosts", "send")
    d.arrow([(786, 410), (816, 410)], "send")

    # 3 Address
    row_title(512, "3", "A server by address and access key", "You forward the port yourself, with the same number on both ends, and paste the access key.")
    d.zone(24, 548, 400, 124, "Your Mac")
    d.node(44, 584, 360, 68, "SwarmHub", ["Connects to the address you type"], mark=True)
    d.zone(596, 548, 460, 124, "Your server")
    d.node(616, 584, 170, 68, "Bridge", mono=["127.0.0.1:8787"])
    d.node(816, 584, 220, 68, "Herdr Core", core)
    d.arrow([(404, 618), (616, 618)], "send", dashed=True)
    d.label(510, 594, "a forward you opened,", "send")
    d.label(510, 609, "for example with ssh -L", "send")
    d.arrow([(786, 618), (816, 618)], "send")

    # 4 Placeholder
    d.zone(24, 700, 1032, 64, "", dashed=True)
    d.text(44, 728, "4  Get a ready-made server from us", size=15, weight=700, fill=d.t["soft"])
    d.text(44, 748, "Shown in the setup window as “Coming soon”. It does nothing: no server is created and nothing is sent.", size=12.5, fill=d.t["soft"])

    d.text(24, 46, "Where bots run", size=20, weight=700)
    d.text(1056, 46, "The bridge answers on loopback only, so a server is always reached through a forward of its port.", size=12.5, fill=d.t["soft"], anchor="end")


DRAWINGS = [
    ("overview", 1080, 594, overview, "SwarmHub: who runs where",
     "The SwarmHub Mac app talks over HTTP, with an access key, to the SwarmHub bridge on a Herdr server. The bridge talks to Herdr Core over a Unix socket; "
     "Core runs the agent programs (Claude Code, Codex) in terminals. The agents report back to the bridge through hooks, and the bridge sends events to the app. "
     "Core reaches project servers over SSH, and each agent program signs in to its own model provider."),
    ("message-flow", 1080, 660, flow, "One message, from the app to an agent and back",
     "A sequence: the app posts a message to the bridge, which saves it and has Herdr Core type it into the agent's terminal. The app follows the turn on the "
     "bridge's event stream: tool calls and the reply so far arrive from the agent's hooks, and the finished reply is saved in the journal by the Stop hook. "
     "A message sent meanwhile steers the running agent, and Stop presses the agent's interrupt key."),
    ("bots-and-helpers", 1080, 636, bots, "Bots, the main bot and helpers",
     "In the Mac app, a bot asks the main bot for a new bot, the main bot creates bots, and bots write to each other; the app passes these on by reading "
     "swarmhub blocks in replies. On the Herdr server each bot has one agent, and an agent starts helpers through the bridge, which picks their model from the helper policy."),
    ("deployment", 1080, 788, deployment, "The ways to choose where bots run",
     "Three working ways: everything on this Mac; a server over SSH, where the app opens the port forward itself; a server by address, where you forward the port "
     "and paste the access key. A fourth, a ready-made server, is a placeholder that does nothing."),
]


def chrome():
    return next((p for p in ("google-chrome", "chromium", "chromium-browser") if shutil.which(p)), None)


def main():
    png = "--png" in sys.argv
    only = [a for a in sys.argv[1:] if not a.startswith("--")]
    failed = False
    for name, w, h, draw, title, desc in DRAWINGS:
        if only and name not in only:
            continue
        for theme in THEMES:
            d = Drawing(name, w, h, title, desc, theme)
            draw(d)
            for problem in d.problems:
                failed = True
                print(f"{name}: {problem}", file=sys.stderr)
            target = HERE / f"{name}-{theme}.svg"
            target.write_text(d.svg())
            if png:
                program = chrome()
                if not program:
                    sys.exit("No Chrome or Chromium found for --png.")
                from PIL import Image
                with tempfile.TemporaryDirectory() as scratch:
                    page = pathlib.Path(scratch) / "page.html"
                    page.write_text(f'<html><body style="margin:0;background:transparent"><img src="{target.as_uri()}" width="{w}" height="{h}"></body></html>')
                    shot = pathlib.Path(scratch) / "shot.png"
                    subprocess.run([program, "--headless=new", "--no-sandbox", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=2",
                                    "--default-background-color=00000000", f"--window-size={w},{h}", f"--screenshot={shot}", page.as_uri()],
                                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    Image.open(shot).save(HERE / f"{name}-{theme}.png", optimize=True)
            print(target.relative_to(ROOT))
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()

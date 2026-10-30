"""Private progress journal for hb-move and its resumable undo."""
import json
import os
import time

JOURNAL = "/var/lib/swarmhub/hb-move"


class Journal:
    def __init__(self, box, profile):
        self.box, self.path = box, box.path(JOURNAL) / f"{profile}.json"
        self.data = json.loads(self.path.read_text()) if self.path.exists() else None

    def start(self, **fields):
        self.data = dict(fields, steps=[], started=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
        self.save()

    def done(self, step, **fields):
        self.data["steps"].append(step)
        self.data.update(fields)
        self.save()

    def undone(self, step, **fields):
        """Undo's own progress, so an undo that failed part way (a restart, nginx) runs again from where it stopped."""
        self.data.setdefault("undone", []).append(step)
        self.data.update(fields)
        self.save()

    def save(self):
        if self.box.dry:
            return
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        temp = self.path.with_suffix(".tmp")
        temp.write_text(json.dumps(self.data, indent=2, sort_keys=True) + "\n")
        temp.chmod(0o600)
        os.replace(temp, self.path)


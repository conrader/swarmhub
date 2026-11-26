"""Read account status through the authenticated workspace and its Core machine, using literal launch templates."""
import json
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path


def fixtures(root, templates, bridge):
    helper = root / "account-tools/swarmhub-herdr"
    helper.parent.mkdir()
    helper.symlink_to(bridge)
    cli = root / "cli-account"
    cli.write_text("""#!/usr/bin/python3
import json, os, sys
from pathlib import Path
fixture = Path(os.environ['ACCOUNT_FIXTURE'])
with fixture.with_suffix('.calls').open('a') as calls:
    calls.write('call\\n')
value = json.loads(fixture.read_text())
if sys.argv[1:4] == ['auth','status','--json']:
    print(json.dumps(value))
    sys.exit(0 if value.get('loggedIn') else 1)
assert sys.argv[1] == 'app-server' and 'check_for_update_on_startup=false' in sys.argv
for line in sys.stdin:
    message=json.loads(line)
    method=message['method']
    if method=='initialized':continue
    if method=='initialize':
        result={}
    else:
        assert method=='account/read' and message['params']=={'refreshToken':False}
        result=value
    print(json.dumps({'id':message['id'],'result':result}),flush=True)
""")
    cli.chmod(0o700)
    def add(name, provider, data):
        f = root / (name + ".json")
        f.write_text(json.dumps(data))
        (templates / (name + ".md")).write_text(
            f"---\ndescription: Account fixture\ncommand: SWARMHUB_{provider.upper()}_BIN={cli} "
            f"ACCOUNT_FIXTURE={f} {helper} run-{provider}\n---\n")
    add("account-plus", "codex", {"account":{"type":"chatgpt","email":"private@example.test","planType":"plus"}})
    add("account-key", "codex", {"account":{"type":"apiKey","credential":"secret"}})
    add("account-external", "codex", {"account":None,"requiresOpenaiAuth":False})
    add("account-absent", "codex", {"account":None,"requiresOpenaiAuth":True})
    add("account-max", "claude", {"loggedIn":True,"subscriptionType":"max","authMethod":"claude.ai","organizationId":"private"})
    add("account-logout", "claude", {"loggedIn":False,"error":"private diagnostic"})
    add("account-error", "claude", {"error":"private diagnostic"})


def exercise(root, request):
    def status(template):
        return request("/api/runtime-account/" + template)
    plus = {"state":"signed_in","billing":"Subscription · Plus"}
    with ThreadPoolExecutor(max_workers=5) as pool:
        assert list(pool.map(status, ["account-plus"] * 5)) == [plus] * 5
    assert (root / "account-plus.calls").read_text().splitlines() == ["call"]
    for template, expected in [
        ("account-key", {"state":"signed_in", "billing":"API key"}),
        ("account-max", {"state":"signed_in", "billing":"Subscription · Max"}),
        ("account-logout", {"state":"signed_out"}), ("account-absent", {"state":"signed_out"}),
        ("account-external", {"state":"unreported"}), ("account-error", {"state":"unreported"}),
        ("fixture", {"state":"unreported"}), ("missing-template", {"state":"unreported"}),
    ]:
        assert status(template) == expected, template
    print("Account labels matched the selected CLI and launch environment. Concurrent reads shared one probe.")

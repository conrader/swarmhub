"""Exercise a restricted OpenCode launch, follow-up, and warm restart with a local model."""
import json


class DocumentReview:
    owner = "3752aa72-2f35-4619-88af-73a61ac72ba1"

    def __init__(self, root):
        self.document = root / "contract.txt"
        self.document.write_text("Contract review fixture 79ef.\n")
        self.private = root / "permission-fixture.txt"
        self.tools = []
        self.results = []

    def model(self, request):
        message = request["messages"][-1]
        prompt = message.get("content")
        if message["role"] == "user" and prompt in ("Read the contract", "Read the private file"):
            self.tools.append(sorted(tool["function"]["name"] for tool in request.get("tools", [])))
            path = self.document if prompt == "Read the contract" else self.private
            call = {"index": 0, "id": f"call_contract_{len(self.tools)}", "type": "function",
                    "function": {"name": "read", "arguments": json.dumps({"path": str(path)})}}
            return (({"role": "assistant", "tool_calls": [call]}, None), ({}, "tool_calls"))
        if message["role"] == "tool":
            self.results.append(json.dumps(prompt))
        return (({"role": "assistant", "content": "Review finished."}, None), ({}, "stop"))

    def exercise(self, request, core, until):
        settings = "/api/bot-agent-settings/" + self.owner
        launch = {"name": "legal-role-qa", "workspace_id": self.owner, "template": "local-model",
                  "expected_document_read_only": True, "task": "Read the contract"}
        request("/api/agents", launch, status=409)
        request(settings, {"document_read_only": True})
        request(settings, {"session_cap_cents": 200})
        assert request(settings)["document_read_only"] and request(settings)["session_cap_cents"] == 200
        request(settings, {"document_read_only": False}, status=422)
        for warm in (False, True):
            body = dict(launch, expected_session_cap_cents=200)
            if warm:
                body.update(warm=True, task="")
            agent = request("/api/agents", body, status=201, timeout=45)
            session = f"{agent['address']}/{agent['created_ms']}"
            route = "/api/agents/" + session
            try:
                row = next(a for a in request("/api/workspace")["agents"] if a["address"] == agent["address"])
                assert row["document_read_only"] and row["session_cap_cents"] == 200
                if warm:
                    request(route + "/messages", {"text": "Read the contract"})
                expected = 3 if warm else 1
                try:
                    until(lambda: len(self.results) == expected, seconds=18)
                except AssertionError as error:
                    raise AssertionError((warm, self.tools, self.results, request(route + "/output"))) from error
                assert self.document.read_text().strip() in self.results[-1]
                history = f"/api/history/{core}/{session}"
                until(lambda: any(item["kind"] == "reply" for item in request(history)["items"]), seconds=20)
                request(route + "/messages", {"text": "Read the private file"})
                until(lambda: len(self.results) == expected + 1, seconds=20)
                assert self.private.read_text().strip() not in self.results[-1], self.results[-1]
                assert self.tools[-2:] == [["read"], ["read"]], self.tools
            finally:
                request(route + "/end", {})
        print("OpenCode restricted both launches and both follow-ups to one read tool, preserved file denials and the spending limit.")

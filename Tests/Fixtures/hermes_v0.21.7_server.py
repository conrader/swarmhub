"""Deterministic fixture for the v0.21.7 API-server wire contract."""
import asyncio, json, sys
from aiohttp import web

created_session = None
mode = sys.argv[2] if len(sys.argv) > 2 else "native"

@web.middleware
async def authenticate(request, handler):
    if request.headers.get("Authorization") != "Bearer fixture":
        return web.json_response({"error":"missing fixture bearer key"}, status=401)
    if mode == "legacy" and request.path.startswith("/api/sessions"):
        return web.json_response({"error":"legacy fixture forbids Sessions routes"}, status=500)
    return await handler(request)

async def health(_): return web.json_response({"status":"ok","version":"0.21.7"})
async def capabilities(_):
    if mode == "legacy": return web.json_response({"error":"not found"}, status=404)
    return web.json_response({"features":{"session_chat_streaming":True,"run_stop":True,"run_approval_response":True}})
async def models(_): return web.json_response({"object":"list","data":[{"id":"hermes-agent"}]})
async def sessions(request):
    assert request.query.get("source") == "api_server"
    rows = [] if created_session is None else [{"id":created_session,"title":"AgentApp integration","source":"api_server"}]
    return web.json_response({"object":"list","data":rows})
async def create_session(request):
    global created_session
    body = await request.json(); assert body.get("source") == "api_server"; assert body.get("id", "").startswith("agentapp_")
    created_session = body["id"]
    return web.json_response({"object":"hermes.session","session":{"id":created_session,"title":body.get("title"),"source":"api_server"}}, status=201)
async def messages(request):
    assert request.query.get("order") == "oldest"; assert request.query.get("limit") == "500"
    return web.json_response({"object":"list","data":[]})
async def stop(_): print("fixture: stop called", flush=True); return web.json_response({"status":"stopping"})
async def approval(request):
    body = await request.json(); assert body == {"choice":"deny","request_id":"req-1"}
    print("fixture: approval called", flush=True); return web.json_response({"object":"hermes.run.approval_response","resolved":1})

async def stream(request):
    response = web.StreamResponse(headers={"Content-Type":"text/event-stream"}); await response.prepare(request)
    events = [
        ("run.started", {"run_id":"run_fixture","session_id":created_session}),
        ("assistant.delta", {"run_id":"run_fixture","delta":"fixture reply"}),
        ("subagent.start", {"run_id":"run_fixture","task":"Research","profile":"research"}),
        ("subagent.complete", {"run_id":"run_fixture","task":"Research","status":"completed","summary":"done","child_session_id":"child-1","delegation_id":"deleg-1"}),
        ("approval.request", {"run_id":"run_fixture","request_id":"req-1","description":"Run command?","command":"printf test","choices":["once","deny"]}),
        ("assistant.completed", {"run_id":"run_fixture","content":"fixture reply"}),
    ]
    for name, payload in events: await response.write(f"event: {name}\ndata: {json.dumps(payload)}\n\n".encode())
    await asyncio.sleep(0.5)
    await response.write(b'event: run.cancelled\ndata: {"run_id":"run_fixture","interrupted":true}\n\nevent: done\ndata: {}\n\n'); await response.write_eof()
    return response

async def legacy_stream(request):
    assert mode == "legacy"; assert request.headers.get("X-Hermes-Session-Id") == "agentapp_legacy_integration"
    body = await request.json(); assert body.get("stream") is True; assert body.get("messages", [])[-1].get("content") == "Reply with echo"
    response = web.StreamResponse(headers={"Content-Type":"text/event-stream"}); await response.prepare(request)
    await response.write(b'data: {"choices":[{"delta":{"content":"legacy fixture reply"}}]}\n\ndata: [DONE]\n\n'); await response.write_eof()
    return response

app = web.Application(middlewares=[authenticate])
app.add_routes([
    web.get('/health/detailed', health), web.get('/v1/capabilities', capabilities), web.get('/v1/models', models),
    web.get('/api/sessions', sessions), web.post('/api/sessions', create_session), web.get('/api/sessions/{id}/messages', messages),
    web.post('/api/sessions/{id}/chat/stream', stream), web.post('/v1/chat/completions', legacy_stream), web.post('/v1/runs/{id}/stop', stop), web.post('/v1/runs/{id}/approval', approval),
])
web.run_app(app, host='127.0.0.1', port=int(sys.argv[1] if len(sys.argv) > 1 else 18643), print=None)

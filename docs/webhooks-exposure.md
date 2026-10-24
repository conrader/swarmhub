# Exposing Swarm Hub webhooks (optional)

The webhook receiver (`swarmctl webhook serve`, run by the `swarmhub-webhook.service` systemd user unit, its fallback
supervisor, or the `com.swarmhub.webhook` LaunchAgent) listens on **127.0.0.1:8745 only**. Out of the box a webhook works from the box
itself: `curl` on the box, a local cron job, another service on the same machine. To let an outside service (GitHub,
Stripe, Zapier, a phone shortcut…) call it, the box owner puts a reverse proxy or a tunnel in front of that port. This
page is a recipe only: nothing here is deployed by Swarm Hub, and the receiver itself never binds a public address.

## What to forward

- Forward **only** `POST /swarmhub/webhook/…` to `http://127.0.0.1:8745`, path unchanged. Everything else can be
  refused. `GET /swarmhub/webhook/health` is for the box itself (the app's status check); it reveals nothing, but
  there is no reason to publish it.
- Keep the `X-SwarmHub-Key` header and the JSON body as they are. The receiver accepts bodies up to 32,000 bytes.
- Use HTTPS. The key travels in a header, so plain HTTP on the internet exposes it.
- Don't log request headers at the proxy (the key is in one). Access logs with method, path and status are fine:
  the path holds an unguessable slug but no key, a call without a key is refused (400) and one with a wrong key too (403).
- If a proxy in the path strips `X-SwarmHub-Key`, a sender may put the key in the JSON body as `"key"` instead. The
  receiver reads it only when the header is missing or empty; a header that arrives is never overridden by the body.
  Don't log request bodies either. The text may come as `"text"` or, when `text` is missing or blank, `"message"`.

## One receiver per account, on its own port

Each box account runs one receiver for the profiles in its own home. Profiles moved into their own account get their
own port: `swarmctl webhook receiver install --port <n>` writes it into the unit, LaunchAgent or fallback supervisor,
and later installs (skill setup, the app) keep it. `webhook receiver status` reports it and, without `webhook_base`,
printed addresses use it. Route each profile path to its account's port at the proxy. A profile the receiver's own
account doesn't hold answers 400, so a 400 where you expected 404 for an unknown routine means the request reached the
wrong account's receiver.

## Then publish the public address

The URL the app and `swarmctl webhook show` print comes from the policy setting `webhook_base`. Set it to the public
origin (and path prefix, if your proxy strips one):

```sh
printf '%s\n' '{"webhook_base":"https://hooks.example.com"}' | <skill-dir>/scripts/swarmctl policy set
```

Existing webhooks keep their slug and key; only the printed address changes. Refresh the app's Webhooks section to
see the new addresses. Without `webhook_base` the addresses stay `http://127.0.0.1:8745/…` and the app says they
answer only on the box.

## Caddy

```caddy
hooks.example.com {
	@webhook {
		method POST
		path /swarmhub/webhook/*
	}
	handle @webhook {
		request_body {
			max_size 32KB
		}
		reverse_proxy 127.0.0.1:8745
	}
	handle {
		respond 404
	}
}
```

Caddy obtains the certificate itself and writes no access log unless you add a `log` directive; if you do, drop the
`X-SwarmHub-Key` request header with its `filter` log encoder. `webhook_base` is then `https://hooks.example.com`.

## nginx

```nginx
server {
    listen 443 ssl;
    server_name hooks.example.com;
    # ssl_certificate / ssl_certificate_key as for your other sites (e.g. certbot)

    location /swarmhub/webhook/ {
        limit_except POST { deny all; }
        client_max_body_size 32k;
        proxy_pass http://127.0.0.1:8745;   # no trailing slash: the path is passed unchanged
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $remote_addr;
    }
    location = /swarmhub/webhook/health { return 404; }
    location / { return 404; }
}
```

The default `combined` log format records no request headers, so the key stays out of the access log.

With a path prefix (for example a shared domain where webhooks live under `/hooks/`), strip it at the proxy and
include it in `webhook_base`:

```nginx
location /hooks/swarmhub/webhook/ {
    limit_except POST { deny all; }
    proxy_pass http://127.0.0.1:8745/swarmhub/webhook/;
}
```

and `{"webhook_base":"https://example.com/hooks"}`.

## Cloudflare Tunnel (no open port)

When the box should not accept inbound connections at all, `cloudflared` can carry the calls out through an
outbound tunnel. In the tunnel's `config.yml`:

```yaml
ingress:
  - hostname: hooks.example.com
    path: ^/swarmhub/webhook/
    service: http://127.0.0.1:8745
  - service: http_status:404
```

Cloudflare terminates TLS. Restrict the hostname to `POST` with a WAF rule if you like. `webhook_base` is
`https://hooks.example.com`.

## Checking it

On the box: `swarmctl webhook receiver status` (or the app's Webhooks section) should say `running`. From outside,
a call with a wrong key must answer 403 (no key at all: 400) and one with the key 202. Every receiver answer is JSON;
an HTML page came from the proxy:

```sh
curl -sS -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: application/json' \
  -H 'X-SwarmHub-Key: wrong' -d '{"text":"ping"}' \
  https://hooks.example.com/swarmhub/webhook/<profile>/<routine>/<slug>   # 403
```

A 502 from the proxy means the receiver is not running. `swarmctl webhook receiver status` names its log:
`journalctl --user -u swarmhub-webhook.service` (systemd user unit), `~/.hermes/swarmhub/logs/webhook-receiver.log`
(the fallback supervisor used where the box account has no systemd user manager) or
`~/Library/Logs/SwarmHub/webhook-receiver.log` (macOS).

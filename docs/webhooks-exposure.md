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
  the path holds an unguessable slug but no key, and a call without the key is refused (400).

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
        proxy_request_buffering on;       # receiver refuses passed-through Transfer-Encoding
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
a call without the key must answer 400 JSON and one with the key 202 JSON. A wrong non-empty key or
wrong slug on an existing routine gives 403 JSON. Health's external 404 alone does not prove proxying:

```sh
curl -sS -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: application/json' \
  -d '{"text":"ping"}' https://hooks.example.com/swarmhub/webhook/<profile>/<routine>/<slug>   # 400
```

A 502 from the proxy means the receiver is not running. `swarmctl webhook receiver status` names its log:
`journalctl --user -u swarmhub-webhook.service` (systemd user unit), `~/.hermes/swarmhub/logs/webhook-receiver.log`
(the fallback supervisor used where the box account has no systemd user manager) or
`~/Library/Logs/SwarmHub/webhook-receiver.log` (macOS).

For migrated accounts, route `/swarmhub/webhook/<profile>/` to that account's receiver port and retain
8745 for shared profiles. The automated [V1–V6 probe, enrollment and DNS-only fallback](../ops/README.md)
check account ownership with a dummy-key absent-routine POST and verify the delivery/receipt journals.
They also distinguish nginx HTML errors from receiver JSON errors and check header presence through Cloudflare.

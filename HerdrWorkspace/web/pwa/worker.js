"use strict";

const offline = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="theme-color" media="(prefers-color-scheme: dark)" content="#16181e"><meta name="theme-color" media="(prefers-color-scheme: light)" content="#f4f5fa">
<title>SwarmHub · Workspace unreachable</title>
<style>
:root{color-scheme:dark;--bg:#16181e;--ink:#f0f0f5;--panel:#20222c;--line:#373b4b;--muted:#c2c5d0;--accent:#bdc2ff;--accent-ink:#171945;--focus:#d1d5ff;background:var(--bg);color:var(--ink);font:16px/1.55 system-ui,sans-serif}
@media (prefers-color-scheme:light){:root{color-scheme:light;--bg:#f4f5fa;--ink:#202238;--panel:#fff;--line:#737b97;--muted:#505670;--accent:#3d469b;--accent-ink:#fff;--focus:#3447b4}}
body{margin:0;padding:clamp(18px,5vw,48px);min-height:100dvh;display:grid;place-items:center}
main{box-sizing:border-box;width:min(100%,448px);background:var(--panel);border:1px solid var(--line);border-radius:16px;padding:clamp(20px,6vw,32px)}
h1{font-size:1.5rem;line-height:1.2;margin:.5rem 0}p{color:var(--muted)}strong{color:var(--accent)}
a{display:inline-grid;place-items:center;min-height:44px;padding:0 16px;border-radius:9px;background:var(--accent);color:var(--accent-ink);font-weight:650;text-decoration:none}
a:focus-visible{outline:2px solid var(--focus);outline-offset:3px}
</style></head><body><main>
<strong>SwarmHub</strong><h1>Workspace unreachable</h1>
<p>Reconnect to your SwarmHub server to open conversations, read files, or run agents. No workspace content is available on this screen.</p>
<a href="/">Try again</a>
</main></body></html>`;

self.addEventListener("install", (event) => event.waitUntil(self.skipWaiting()));
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()));
self.addEventListener("fetch", (event) => {
  const {request} = event;
  const url = new URL(request.url);
  // The only handled request is the main HTML navigation. APIs, downloads,
  // OAuth callbacks, assets and any other requests proceed past this worker.
  if (request.method !== "GET" || request.mode !== "navigate" || request.destination !== "document"
    || url.origin !== self.location.origin || url.pathname !== "/" || request.headers.has("Authorization")) return;
  event.respondWith(fetch(request, {cache:"no-store"}).catch(() => new Response(offline, {
    status:503, headers:{"Content-Type":"text/html; charset=utf-8", "Cache-Control":"no-store",
      "Content-Security-Policy":"default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
      "Referrer-Policy":"no-referrer", "X-Content-Type-Options":"nosniff"},
  })));
});

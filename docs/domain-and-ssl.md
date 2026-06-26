# Domain and SSL via Coolify

KilnCMS runs in production behind [Coolify](https://coolify.io/), whose built-in
reverse proxy (Traefik) terminates TLS and forwards plain HTTP to the app
container. This guide covers the Phase 9 deployment work (issue #58): pointing a
domain at the Coolify service, letting Coolify issue a Let's Encrypt certificate,
and configuring the app so that **HTTPS is enforced** and every **generated
absolute URL matches the live domain**.

This page is about networking and URL correctness. For the broader Coolify
service setup (env vars, build, health checks) see
[deployment-coolify.md](deployment-coolify.md); for serving media off object
storage / a CDN see [cdn.md](cdn.md) and
[frontend-assets.md](frontend-assets.md).

## Architecture: where TLS lives

```
   client ──HTTPS:443──▶  Coolify proxy (Traefik)  ──HTTP──▶  KilnCMS container
                          • terminates TLS                    Bandit on $PORT
                          • Let's Encrypt cert                 (default 4000)
                          • adds X-Forwarded-Proto: https
```

The app itself does **not** terminate TLS. The proxy speaks HTTPS to the world,
then proxies a plain HTTP request to the container and stamps it with
`X-Forwarded-Proto: https`. Everything below depends on that header being
trustworthy — it is, because only the Coolify proxy can reach the container's
port.

## 1. Point the domain at Coolify

In your DNS provider, create records that resolve the site hostname to the
machine running Coolify:

| Record | Name              | Value                       |
|--------|-------------------|-----------------------------|
| `A`    | `@` / `cms`       | IPv4 of the Coolify host    |
| `AAAA` | `@` / `cms`       | IPv6 of the Coolify host (if any) |

Notes:

- Use the **public** IP of the server Coolify runs on. If you use a `www`
  subdomain (or both apex and `www`), add a record for each — Coolify can request
  a certificate covering multiple domains.
- If the records sit behind another proxy (e.g. Cloudflare orange-cloud), set it
  to **Full (strict)** TLS so the chain stays HTTPS end-to-end and
  `X-Forwarded-Proto` is not rewritten to `http`.
- Wait for DNS to propagate before enabling TLS — Let's Encrypt's HTTP-01
  challenge needs the domain to already resolve to the Coolify host.

Then, in the Coolify service:

1. Open the application → **Domains**.
2. Add the domain **with the `https://` scheme** (e.g. `https://cms.example.com`).
   Coolify uses the scheme to decide whether to provision a certificate.
3. Save and redeploy. Coolify automatically requests and renews a **Let's Encrypt**
   certificate for that domain and routes `:443` traffic to the container's
   `$PORT`. No certificate files are mounted into the app — `config/runtime.exs`
   deliberately leaves the commented-out `https:` endpoint block unused.

## 2. HTTPS enforcement: `force_ssl` (already configured)

HTTPS redirection and HSTS are handled in the app, not the proxy, so a request
that somehow arrives over plain HTTP is still upgraded. This is already set in
[`config/prod.exs`](../config/prod.exs):

```elixir
config :kiln_cms, KilnCMSWeb.Endpoint,
  force_ssl: [
    rewrite_on: [:x_forwarded_proto],
    exclude: [
      # paths: ["/health"],
      hosts: ["localhost", "127.0.0.1"]
    ]
  ]
```

What this does:

- **Redirects HTTP → HTTPS.** Any request `force_ssl` considers insecure gets a
  `301` redirect to the `https://` URL. Combined with Coolify routing `:80` to the
  container, a user hitting `http://cms.example.com` is bounced to
  `https://cms.example.com`.
- **Sets HSTS.** `Plug.SSL` adds a `Strict-Transport-Security` header
  (`max-age=31536000`) on HTTPS responses, telling browsers to refuse plain HTTP
  to this host for a year. Submitting the domain to the HSTS preload list is
  optional and out of scope here.

### Why `rewrite_on: [:x_forwarded_proto]` is required

Because the proxy terminates TLS, the request the app sees is **plain HTTP** —
`conn.scheme` is `:http` for every request, even the ones the client made over
HTTPS. Without help, `force_ssl` would think every request is insecure and
redirect-loop forever (`https → proxy → http → redirect to https → …`).

`rewrite_on: [:x_forwarded_proto]` tells `Plug.SSL` to **trust the
`X-Forwarded-Proto` header** the Coolify proxy injected and treat the request's
effective scheme as that value. So a request the client made over HTTPS carries
`X-Forwarded-Proto: https`, the plug sees it as already-secure, and serves it
directly (adding HSTS) instead of redirecting. This is the standard pattern for
any app sitting behind a TLS-terminating reverse proxy.

> Trust note: `X-Forwarded-Proto` is only safe to trust because the container's
> HTTP port is reachable solely from the Coolify proxy. Never expose the
> container port directly to the internet, or a client could forge the header and
> defeat the redirect.

### The localhost exclusion

`exclude: [hosts: ["localhost", "127.0.0.1"]]` skips the HTTPS upgrade when the
request host is `localhost` or `127.0.0.1`. This keeps in-container, loopback
traffic on plain HTTP — most importantly **health checks**: Coolify (or Docker)
probing the container over `http://localhost:$PORT/...` must get a `200`, not a
`301` to HTTPS. The commented `paths: ["/health"]` line is the alternative
approach — exclude a specific health-check path by URL instead of (or in addition
to) by host. Use it if your health probe hits the public hostname rather than
loopback.

`force_ssl` is a **compile-time** setting (note the comment in `config/prod.exs`),
so changes to it require a rebuild/redeploy, not just a restart.

## 3. Make generated URLs match the live domain

Enforcing HTTPS is only half of issue #58. The other half is that **absolute URLs
the app generates** — canonical tags, the sitemap, `hreflang` alternates,
structured-data links, and editor links in notification emails — must point at
the real domain over `https://`, or they leak `example.com` / `localhost:4000`
into production output and break SEO and email links.

KilnCMS builds absolute URLs from **two independent sources**. Both must be set
for the live domain.

### a. `PHX_HOST` — the Phoenix endpoint URL

Set in [`config/runtime.exs`](../config/runtime.exs):

```elixir
host = System.get_env("PHX_HOST") || "example.com"

config :kiln_cms, KilnCMSWeb.Endpoint,
  url: [host: host, port: 443, scheme: "https"],
  ...
```

This configures the endpoint's URL, which is what verified-route URL helpers
(`url(~p"/...")`) use. In KilnCMS that path covers **editor links in workflow
notification emails** — see
[`KilnCMS.Notifications.WorkflowMailWorker`](../lib/kiln_cms/notifications/workflow_mail_worker.ex),
where `editor_url/2` calls `url(~p"/editor/...")`. With `PHX_HOST=cms.example.com`
those become `https://cms.example.com/editor/...`.

Set it on the Coolify service as an environment variable:

```
PHX_HOST=cms.example.com
```

**Consequence of getting it wrong:** if `PHX_HOST` is unset it falls back to the
literal `example.com`, so reviewers receive emails linking to
`https://example.com/editor/...` — a domain you don't control. Set it to the
**bare hostname** (no scheme, no path, no port): `cms.example.com`, not
`https://cms.example.com/`.

### b. `:public_base_url` — the public delivery base URL

The public frontend's SEO/discovery surfaces read a **separate** application
config, `:kiln_cms, :public_base_url`, which is **not** derived from `PHX_HOST`.
It is defined in [`config/config.exs`](../config/config.exs):

```elixir
config :kiln_cms, :public_base_url, "http://localhost:4000"
```

This value is the base for:

- the **sitemap** and `robots.txt` —
  [`KilnCMSWeb.SitemapController`](../lib/kiln_cms_web/controllers/sitemap_controller.ex)
  (`base_url/0` reads `:public_base_url`),
- **canonical / hreflang URLs** built in
  [`KilnCMSWeb.ContentController`](../lib/kiln_cms_web/controllers/content_controller.ex)
  (the `<link rel="canonical">` in
  [`root.html.heex`](../lib/kiln_cms_web/components/layouts/root.html.heex)),
- **JSON-LD structured data** in
  [`KilnCMSWeb.StructuredData`](../lib/kiln_cms_web/structured_data.ex).

> ⚠️ **This is the easy one to miss.** `:public_base_url` defaults to
> `http://localhost:4000` in `config/config.exs` and is **not overridden in
> `config/runtime.exs`** the way `PHX_HOST` is. If you only set `PHX_HOST`, your
> sitemap, canonical tags, and JSON-LD will still emit
> `http://localhost:4000/...` in production — pointing search engines at a dead,
> non-HTTPS address. Override `:public_base_url` for production to the **full
> `https://` origin** of the live domain, with **no trailing slash**:
> `https://cms.example.com`.

To override it at runtime, add to the `config_env() == :prod` block in
`config/runtime.exs` (or wherever your release reads it):

```elixir
config :kiln_cms, :public_base_url,
  System.get_env("PUBLIC_BASE_URL") || "https://#{host}"
```

so it tracks `PHX_HOST` automatically (note the `https://` scheme prefix and no
trailing slash). Whichever mechanism you use, the rule is: `:public_base_url`
must equal the **scheme + live domain** of the delivery frontend.

### c. Media `public_base_url` is a different thing entirely

Do not confuse the **site** base URL with the **media** base URL. Object-storage
media is served from `KilnCMS.Storage.S3`'s own `:public_base_url`, configured
from `S3_PUBLIC_BASE_URL` in
[`config/runtime.exs`](../config/runtime.exs) and used by
[`KilnCMS.Storage.S3.url/1`](../lib/kiln_cms/storage/s3.ex):

```
S3_BUCKET=...                # opts the app into S3 storage
S3_PUBLIC_BASE_URL=https://cdn.example.com   # required when S3_BUCKET is set
```

That URL is the bucket/CDN origin for uploaded files and is **expected to differ**
from the site host (it usually points at a CDN or storage subdomain). The site
domain (`PHX_HOST` / `:public_base_url`) and the media origin
(`S3_PUBLIC_BASE_URL`) are configured and changed independently. See
[cdn.md](cdn.md) for the media/CDN side.

### Summary of the three URL settings

| Setting | Source | Drives | Example value |
|---------|--------|--------|---------------|
| `PHX_HOST` | env → endpoint `url:` in `runtime.exs` | `url(~p"…")` helpers, email editor links | `cms.example.com` (bare host) |
| `:kiln_cms, :public_base_url` | `config.exs` default; override in `runtime.exs` | sitemap, `robots.txt`, canonical, hreflang, JSON-LD | `https://cms.example.com` (scheme, no slash) |
| `S3_PUBLIC_BASE_URL` | env → `KilnCMS.Storage.S3` | uploaded media / asset URLs | `https://cdn.example.com` |

## 4. Verification checklist

After DNS, TLS, and the env vars are in place, redeploy and verify from outside
the network.

**HTTPS is enforced and HSTS is present:**

```bash
# HTTPS request returns 200 with an HSTS header
curl -sI https://cms.example.com/ | grep -i 'strict-transport-security'
# => strict-transport-security: max-age=31536000; ...

# Plain HTTP is redirected (301) to HTTPS
curl -sI http://cms.example.com/
# => HTTP/1.1 301 Moved Permanently
# => location: https://cms.example.com/
```

**The certificate is valid (Let's Encrypt):**

```bash
curl -sI https://cms.example.com/ >/dev/null && echo "TLS handshake OK"
# (a cert error makes curl exit non-zero; add -v to inspect the issuer)
```

**Generated URLs use the right host and scheme:**

```bash
# sitemap entries use https://cms.example.com (NOT localhost / example.com)
curl -s https://cms.example.com/sitemap.xml | grep -o '<loc>[^<]*</loc>' | head

# robots.txt points the Sitemap line at the live host
curl -s https://cms.example.com/robots.txt | grep -i sitemap

# canonical tag on a published page resolves to the live https host
curl -s https://cms.example.com/<some-slug> | grep -i 'rel="canonical"'
```

**Health check still works over loopback** (the localhost exclusion): confirm the
Coolify service shows the container as healthy after deploy — the loopback probe
gets a `200`, not a `301`.

**Email links** (optional, harder to script): trigger a workflow notification and
confirm the editor link in the email is `https://cms.example.com/editor/...`,
proving `PHX_HOST` is set correctly.

When all of the above pass — `curl -I` shows the HSTS header and an http→https
`301`, and the sitemap/canonical URLs use the live `https://` host — issue #58's
acceptance criteria (HTTPS enforced + `public_base_url` matches the live domain)
are met.

## See also

- [deployment-coolify.md](deployment-coolify.md) — Coolify service, env vars,
  build and health checks.
- [cdn.md](cdn.md) — serving media from object storage / a CDN
  (`S3_PUBLIC_BASE_URL`).
- [frontend-assets.md](frontend-assets.md) — how JS/CSS bundles are served
  (self-hosted, no CDN).

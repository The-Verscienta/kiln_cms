# Code injection (#490)

Per-site custom `<head>` / footer HTML for the **delivery site** — the Ghost
"code injection" analogue. This is where an org puts its own analytics snippet,
a search-console verification tag, or a support widget.

It is also the answer to the recurring analytics question: Kiln ships **no**
tracker and does not need to. An org admin adds Plausible, Matomo or GA
themselves, as their decision.

Configure it at `/editor/code-injection` (org admin only).

## The trust model, stated plainly

Everything you paste is emitted **verbatim**. There is no sanitizer, because a
sanitizer would defeat the feature — the point is to run a `<script>`. So this
is stored XSS by design, and what bounds it is *who* can write it and *where* it
lands:

- **Org admins only** may write, resolved against the request's org. It lives on
  its own resource (`KilnCMS.CMS.SiteCodeInjection`) rather than alongside
  branding, so the much larger blast radius is not attached to an ordinary
  settings surface.
- **Delivery only** may render it. `KilnCMSWeb.Plugs.CodeInjection` runs in the
  `:delivery` pipeline and nowhere else. The root layout is shared with the
  editor console, so this is enforced by *which pipeline the plug lives in*
  rather than by a condition in a template — an org admin's script can never
  execute in a Kiln operator's authenticated console session, and no reviewer has
  to keep remembering that.
- **Every change is versioned and attributed.** "When did this site start
  loading that script, and who added it" is answerable from the version trail.

If you administer several sites, note the direction of trust: you are trusting
each site's own admins with their own site's visitors, not with each other's and
not with your console.

## CSP: why your snippet needs an allowlist

Delivery serves a strict policy — `script-src 'self' 'nonce-…'`. Under it a
pasted vendor snippet does nothing at all: an external `<script src>` is blocked
on origin, an inline one on the missing nonce. Silently breaking every snippet
would make this a support trap, so the settings form carries what the snippet
needs to run:

| Field | Adds to | Use for |
|-------|---------|---------|
| Scripts | `script-src` | the host your `<script src>` loads from |
| Connections | `connect-src` | where the script `fetch`es / beacons to |
| Images | `img-src` | tracking pixels, remote badges |

One origin per line, e.g. `https://plausible.io`. A leading `*.` and a port are
allowed. Keyword sources (`'unsafe-inline'`, `'unsafe-eval'`, a bare `*`,
`data:`) are **refused** — each of them would switch off the policy the list
exists to extend. Plain `http://` is refused except for `localhost` /
`127.0.0.1`, so a local Matomo works in development without a published site
shipping a plaintext tracker.

**Inline `<script>` blocks need nothing from you.** On save, Kiln hashes each
inline script body and adds it to the policy as `'sha256-…'`. The saved hashes
are listed on the settings page, so you can confirm the browser will permit the
script you just pasted without opening a console.

### Why hashes and not nonces

A nonce is per-request, so it cannot survive into anything cached or exported. A
hash is a property of the snippet, so the same policy is correct whether the page
was rendered live or came from a cache. Editing the snippet re-derives the
hashes on the same write, so the two can never drift apart — a snippet whose
hash was stale would be blocked, and blocked-with-no-explanation is the worst
failure this feature can have.

The extraction is deliberately literal about what a browser hashes: the bytes
between `<script …>` and the first `</script`, with no entity decoding. One
known limit — a `>` inside a quoted attribute of the start tag ends the tag
early, so that script's hash will not match and the browser will block it. Put
such an attribute on a wrapper element, not on the `<script>`.

## Example: Plausible

Head HTML:

```html
<script defer data-domain="example.com" src="https://plausible.io/js/script.js"></script>
```

Scripts: `https://plausible.io`
Connections: `https://plausible.io`

## What this does not cover

- **The editor console.** By design — see above.
- **Headless consumers.** They own their own `<head>`; nothing here reaches
  `/api/*` or GraphQL.
- **Static export.** `mix kiln.export.static` writes *fired artifacts* — body
  fragments and JSON, never a full HTML document — so there is no `<head>` for
  it to inject into. Whatever renders those fragments into a page owns its own
  `<head>`, and its own CSP. The same is true of a CDN in front of the delivery
  site: the policy is a response header, so it comes from whatever serves the
  response.
- **Per-content injection.** Deliberately out of scope; that is what blocks are
  for.

## Turning it off

The settings page has a **Serve these snippets** switch, separate from clearing
the fields, so an operator debugging a broken third-party script can disable it
and re-enable it without losing the snippet — and without that round trip being
invisible in the version trail. **Remove** deletes the row entirely.

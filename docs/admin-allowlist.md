# Restricting sign-in to your networks

A site admin can limit the console and every sign-in page to a list of IP
addresses and ranges, such as an office network or a VPN (#2248). From any
other network, those pages answer "Not available from this network", so a
stolen password is of no use to someone outside.

The list belongs to one site (organization). It is **off** until you add an
entry, and an empty list means off. A list on one site does not apply to
another site on the same installation.

By default the list gates sign-in too, for everyone. A site whose members or
apps sign in from anywhere can turn **Also restrict sign-in** off (#2493): the
console stays behind the list, and sign-in opens to every network. See
"Let members sign in from anywhere".

## What it covers, and what it does not

While the list is on, everything in the first column is refused from an
address that is not on it. The second column is never affected. The rows
marked † follow **Also restrict sign-in**: with it off, they are not affected
either.

| Refused from outside the list | Not affected |
|---|---|
| The console: every `/editor/**` page, `/media` (the media library), editor previews under `/editor/preview/...`, and plugin console pages | The public site, `/membership`, forms, feeds and search |
| The console's downloads: the content, fields, translations, forms entries, analytics, governance and security-log exports, and `/editor/account/export.json` | `/account` (a reader's own settings page) and `/sign-out` |
| `/setup` (the first-run wizard) | Media downloads, transforms and streams (`/media/:id/...`), `/uploads/*` and static assets |
| † Every sign-in route, for **everyone**, members included: `/sign-in`, `/register`, password reset, magic links, passkeys, single sign-on (`/auth/*`), the two-factor prompt `/sign-in/verify`, sign-in unlock links (`/sign-in/unlock`, `/auth/unlock/...`), account confirmation and invitations (`/auth/invite/...`) | `/preview/...` links (token preview) |
| † Headless sign-in: `POST /api/auth/sign_in` and `/api/auth/sign_in/verify` | JSON:API, GraphQL (`/gql`, `/ws/gql`), MCP, REST and `/ws/bridge`, with an API key or a token already issued (except the security posture endpoint, left) |
| The security posture for monitoring, `GET /api/security/posture`, with any credential, API keys included (#2521) | |
| Opening a console page's live connection (LiveView), and pages already open when the list changes; † the same for a sign-in page | `/up` and `/ready` health checks |
| The collaborative-editing socket, `/ws/collab` | |

Consequences to plan for before you turn it on:

- **Members and readers sign in through the same pages.** If your site has
  members who sign in for gated content, they can only sign in from listed
  networks while the list is on and **Also restrict sign-in** is on (the
  default). People already signed in keep reading.
- **Apps that sign people in are restricted too**, under the same setting. A single-page app, a native
  or mobile app, or a website's own sign-in form that calls
  `POST /api/auth/sign_in` from the user's device only works from listed
  networks. A front end that signs in from its own server needs that server's
  address on the list. Tokens already issued and API keys keep working
  anywhere, except on the security posture endpoint below.
- **Posture monitors need a listed network.** `GET /api/security/posture`
  ([monitoring](api.md#security-posture-monitoring)) is a map of what is off
  on the site, so it is gated like the console, even for an API key. Add the
  monitor's outgoing address to the list.

The gate runs after the site's [block list](ip-blocking.md): an address that is
both blocked and allowlisted is blocked.

## Turn on the allowlist

You need the admin role on the site. Editors and viewers do not see the page.
Before you start, find out which addresses your network uses: your office's
public IPv4 address or range, your VPN's exit addresses, and the IPv6 range
too if your network has IPv6.

1. Open **Admin allowlist** under **Configure → Sign-in & access** in the
   console sidebar, or go to `/editor/admin-allowlist`. The page reads "Off:
   people can sign in from any network." and shows **Your address** with the
   address Kiln sees you at.
2. If the page shows **Kiln can't see your real address.**, stop here and fix
   your proxy settings first (see "Behind a proxy" below). **Save** is
   disabled until then.
3. In **Allowed addresses and ranges**, type one entry per line: an IPv4 or
   IPv6 address (`203.0.113.7`, `2001:db8::5`) or a range
   (`198.51.100.0/24`, `2001:db8:1:2::/64`). Commas and spaces also separate
   entries.
4. Select **Add my address** to put your own address in the list: the address
   itself for IPv4, its `/64` for IPv6 (your device's IPv6 address changes
   within that range as it rotates). If Kiln sees you at two addresses, one
   IPv4 and one IPv6, both are added.
5. Select **Save**. You see "Admin allowlist saved." and the status line reads,
   for example, "On: 3 networks can open the console and sign in."

From then on, a request from any other address gets the refusal page, on every
node, at once (see "How fast a change takes effect").

A complete list for an office with a fixed IPv4 range, a dual-stack IPv6
prefix and a VPN exit address:

```text
198.51.100.0/24
2001:db8:1200::/48
203.0.113.7
```

Each entry is stored in one spelling: a bare address gets its `/32` or `/128`,
host bits are cleared (`198.51.100.9/24` becomes `198.51.100.0/24`), IPv6 is
compressed and lowercased, an IPv4-mapped IPv6 range is stored as the IPv4
range it means, and duplicates are dropped. So the list above is saved as
`198.51.100.0/24`, `2001:db8:1200::/48` and `203.0.113.7/32`.

To turn the list off, select **Turn off** and confirm "Turn the admin allowlist
off? Anyone will be able to sign in from any network." You see "Admin
allowlist turned off." Emptying the text box and saving does the same.

## Let members sign in from anywhere

**Also restrict sign-in** is a checkbox in the same form, on by default, so a
list saved before the setting existed keeps gating sign-in after an upgrade.

To let members, readers and apps sign in from any network while the console
stays behind the list:

1. Open `/editor/admin-allowlist`.
2. Clear **Also restrict sign-in**.
3. Select **Save**. The status line reads, for example, "On: 3 networks can
   open the console. Anyone can sign in from any network."

With it off:

- Every sign-in route (the † rows above) and the headless
  `POST /api/auth/sign_in` and `/api/auth/sign_in/verify` answer from any
  network. The two always follow the same setting.
- The console, `/setup`, `/ws/collab` and `GET /api/security/posture` are
  still refused from outside the list. An admin who signs in from elsewhere is
  signed in, and the console still answers "Not available from this network".
- Console pages that are open keep their live connection only while their
  address is listed, as before. Sign-in pages that are open are not sent away
  by a save unless it turns **Also restrict sign-in** back on and their address
  is not listed.

**What this gives up.** With sign-in restricted, a stolen password is useless
from outside the list. With it off, a password (and its second factor, if the
account has one) works from anywhere. For an admin, that is a token from
`POST /api/auth/sign_in` with the admin's full role, which JSON:API, GraphQL
and MCP accept from any network: those APIs are not gated by the list. Require
two-factor sign-in for admins before turning it off.

The Security posture page (and `GET /api/security/posture`) still passes the
admin allowlist check, and says "Sign-in is open to every network"; its facts
carry `sign_in_restricted: false`. If the list cannot be read (see "When the
list cannot be read"), sign-in answers `503` too, even with the setting off:
the last-known "off" that keeps a site without a list working through a
database blip applies only to a list that is off entirely.

Only a site admin can change the setting, the same as the list. It has no
effect while the list is empty. **Turn off** keeps it as it was, so turning
the list back on later starts from your last choice.

### Entries the form refuses

The messages are shown in the console language (English, Spanish, French).

| Message | Meaning |
|---|---|
| `<entry>` is not an IP address or range. | Not an address. Leading zeros in an octet (`010.0.0.1`) are refused. |
| `<entry>` is too broad: use at least /8 for IPv4 or /16 for IPv6. | A range that wide admits a large part of the internet. `0.0.0.0/0` and `::/0` land here. |
| `<entry>` includes loopback (127.0.0.0/8 or ::1), which can't be listed. | Behind a proxy on the same machine that is not declared, every request arrives from `127.0.0.1`, so listing loopback would admit everyone. |

A list holds at most **100** entries; use ranges if you need more.

### The lock-out check

Kiln refuses to save a list that would shut you out. There is no "save
anyway": a list that excludes you takes effect at once, for the console and for
signing back in.

| Message | Meaning |
|---|---|
| This list doesn't include your current address, `<ip>`. Add it, or a range that contains it, so you aren't locked out. | Your address is not in any entry. **Add my address** fixes it. |
| This list must include both of your current addresses, `<ip>` and `<ip>`. Add them, or ranges that contain them, so you aren't locked out. | Your page loaded over one address and its live connection arrived over another (a dual-stack network using IPv4 for one and IPv6 for the other). Both are checked on every visit, so both must be listed. |
| Kiln is seeing a proxy's address, not yours: a forwarding header arrived that nothing is configured to trust. ... | See "Behind a proxy". |
| Your address could not be determined, so this list can't be checked against it. Reload the page and try again. | The page has no record of the address it was loaded from. Reloading fixes it. |

Turning the list off is always accepted.

The page also warns, without refusing, when your address is in private,
carrier-grade NAT (`100.64.0.0/10`), unique-local (`fc00::/7`) or link-local
space: "This looks like a private or shared address, which may be your proxy's
or your provider's: adding it admits everyone behind it." Kiln is then most
likely seeing a proxy or a NAT, not you.

## Behind a proxy

The allowlist judges the address `KilnCMSWeb.Plugs.ClientIp` resolves, the same
one the rate limits and the block list use. Behind a reverse proxy that is the
proxy's address unless the proxy is declared:

- Behind your own proxy (Coolify, Traefik, nginx, a load balancer), set
  `TRUSTED_PROXIES`.
- On Fly.io, Railway or DigitalOcean App Platform, set `CLIENT_IP_HEADER` (the
  provided `fly.toml` and `.do/app.yaml` already do).

See [Environment variables](environment-variables.md) for both. When a
forwarding header arrives and neither is set, the allowlist page shows **Kiln
can't see your real address.** and refuses to save a list. The same happens
when a proxy on your side (a corporate proxy) adds `X-Forwarded-For` to your
requests.

### On Fly.io and DigitalOcean App Platform

A page's live connection (the LiveView socket) cannot see the platform's
client-address header there (`Fly-Client-IP`, `do-connecting-ip`), and neither
can one behind a proxy that sets only the `Forwarded:` header. For those
connections Kiln relies on the address the page's own HTTP request was
admitted from, and accepts it for **5 minutes** after the page loaded. After
that, a reconnect or a move to another console page reloads the page in full,
and the reload is checked again. If you are still on a listed network you see
an occasional full page load and nothing else.

The collaborative-editing socket has no page load to rely on, so on those two
platforms it is refused while a list is on. Collaborative editing is off by
default.

## What a refused visitor sees

- **A page in a browser:** a `403` page titled "Not available from this
  network": "This site only allows sign-in and its admin console from networks
  its administrators have approved. Connect through your organisation's network
  or VPN, or ask a site administrator." It shows "Your address appears as
  `<ip>`." (their own address only, so an admin on the wrong network or behind
  a misconfigured proxy can tell what is going on) and a **Go to the site**
  link.
- **A page that was already open:** it is sent to `/editor` by a full page
  load, which gets the page above.
- **The headless sign-in and the security posture endpoint:** `403` in the
  API's error format, with `cache-control: no-store`:

  ```json
  {"errors": [{"status": "403", "code": "network_not_allowed", "detail": "Not available from this network"}]}
  ```

  Branch on `code`, not on `detail`: the detail is the browser page's
  heading, and may be translated.

## How fast a change takes effect

- **Saving in the console** clears every node's copy of the list at once, and
  open console and sign-in pages whose address the new list does not admit
  leave at once. An open collaborative-editing session closes at its next
  periodic re-check.
- **A change made directly in the database** is seen within **one minute**,
  when each node's copy expires. Open pages are not told; they are checked
  again when they next connect.

## When the list cannot be read

The allowlist **fails closed**. If a node cannot read a site's list (the
database is down or overloaded), the console and sign-in pages answer `503`
"Temporarily unavailable" ("Sign-in is temporarily unavailable. Try again in a
minute.", with `retry-after: 30`), the headless sign-in and the security
posture endpoint answer `503` `temporarily_unavailable` (detail "Temporarily
unavailable", also with `retry-after: 30`), and live connections are refused. A list that
disappears under load would turn the control off exactly when it is needed;
the console and sign-in cannot work without the database anyway. The public
site does not read the list and keeps serving.

The one exception: if the last time this node read the site's list it was
**off**, it keeps treating it as off through a failed read, so a database blip
does not take down the console of every site that never turned the allowlist
on. That memory lasts a day, is per node, and any save replaces it on every
node.

The application log says `admin allowlist lookup failed, serving the fallback
for this request: ...`, at most once a minute per node.

## Recovering from a lock-out

If a list shuts out every admin (the office changed providers, the VPN's exit
address moved), an operator with access to the server can get them back in.
Pick the first route that is available to you.

### With a shell on the running release

Use `rpc`, not `eval`: the change has to reach the running application, clear
every node's copy and tell open pages.

See the list first (nothing is changed):

```sh
bin/kiln_cms rpc 'KilnCMS.Release.admin_allowlist()'
```

```text
The admin allowlist is on, with 2 entr(y/ies):
  198.51.100.0/24
  203.0.113.7/32
Nothing changed. Add add: "<address>" to widen it, or clear: true to turn it off.
```

Then either add the address the admins are at now, or turn the list off:

```sh
bin/kiln_cms rpc 'KilnCMS.Release.admin_allowlist(add: "192.0.2.44")'
bin/kiln_cms rpc 'KilnCMS.Release.admin_allowlist(clear: true)'
```

`org: "<slug>"` acts on a site other than the default one:
`KilnCMS.Release.admin_allowlist(org: "acme", clear: true)`.

- `add:` takes one address or range, in any spelling the console accepts, and
  only works on a list that is **on**. On a list that is off it is refused
  ("The admin allowlist is off on this site; adding would turn it on and lock
  out every admin on another network. Use the console to turn it on."): turning
  a list on from a shell would lock out every admin not on that one network.
- `clear: true` empties the list. On a list that is already off it says so and
  changes nothing.

So the command can only widen or empty a list; it cannot lock anyone out. It
runs as the server's own operator identity, not as a person, and records
**Admin allowlist changed from the server** (`admin_allowlist_overridden`, with
`change` `added` or `cleared` and the entry `count` after) in the site's
[security log](security-events.md). If that event cannot be written, the list
does not change. The change reaches every node at once.

`rpc` exits `0` whatever the call returns. A script that must fail on an error
matches the result:

```sh
bin/kiln_cms rpc '{:ok, _} = KilnCMS.Release.admin_allowlist(clear: true)'
```

### Without a shell: the kill switch

On a platform where you can set environment variables and restart but cannot
run `rpc`:

1. Set `KILN_ADMIN_ALLOWLIST_DISABLED=1` on every node and restart. The boot
   log warns that the server is not enforcing any site's admin allowlist.
2. Sign in from anywhere. The allowlist page shows "This server isn't enforcing
   the admin allowlist (KILN_ADMIN_ALLOWLIST_DISABLED is set). The list is
   saved but not applied."
3. Fix the list and save it. The lock-out check still applies.
4. Remove the variable and restart.

The switch turns the allowlist off for **every site** on the node, and it is
**not** recorded in any security log: it has no site and no person. Your
platform's record of environment changes is the only trail. Prefer `rpc` where
you can.

### Without a release: SQL

From a database console, empty the list:

```sql
UPDATE site_admin_allowlist SET cidrs = '{}'
WHERE org_id = (SELECT id FROM organizations WHERE slug = 'acme');
```

Each node sees it within one minute. You do not need to change `updated_at`.
Nothing is written to the security log, and open pages are not told.

## Try it on a development machine

Everything arrives from `127.0.0.1` on a laptop, and loopback cannot be listed,
so pretend to be behind a proxy. `TRUSTED_PROXIES` is read only by a
production build; in development set the same thing from IEx.

1. Start the server with `iex -S mix phx.server` and run:

   ```elixir
   Application.put_env(:kiln_cms, :trusted_proxies, ["127.0.0.1/32"])
   ```

2. Make your browser send `X-Forwarded-For: 203.0.113.7` on every request (a
   header-editing extension; under Playwright, `extraHTTPHeaders`). Sign in
   as an admin and open `/editor/admin-allowlist`. **Your address** reads
   `203.0.113.7`.
3. Enter `203.0.113.0/24` and select **Save**.
4. Check both sides with `curl`:

   ```sh
   curl -s -o /dev/null -w '%{http_code}\n' -H 'X-Forwarded-For: 203.0.113.7' http://localhost:4000/sign-in
   # 200
   curl -s -o /dev/null -w '%{http_code}\n' -H 'X-Forwarded-For: 198.51.100.1' http://localhost:4000/sign-in
   # 403
   ```

5. Turn the list off when you are done (**Turn off**), or run
   `KilnCMS.Release.admin_allowlist(clear: true)` in the same IEx session.

## What can go wrong

| You see | Meaning |
|---|---|
| "Not available from this network" on a network you expected to work | The address on that page is not on the list. Compare it with the entries. A dual-stack network may be using the other address family: add its IPv6 range or IPv4 address too. |
| Everyone is refused, including admins in the office | Kiln is probably seeing a proxy's address and the list holds the office address, or the reverse. Check `TRUSTED_PROXIES` / `CLIENT_IP_HEADER`, then recover (see above). |
| "Temporarily unavailable" (`503`) on the console and sign-in | The list could not be read. Check the database and the log line above. The public site is unaffected. |
| A console page reloads by itself every few minutes, on Fly.io or App Platform | Expected: the live connection is re-checked by a page load after 5 minutes (see "On Fly.io and DigitalOcean App Platform"). |
| Collaborative editing will not connect while the list is on, on Fly.io or App Platform | Expected: that socket cannot see your address there. |
| A member says they cannot sign in any more | Member sign-in is restricted too. Add their network, or clear **Also restrict sign-in** (see "Let members sign in from anywhere"). |
| A mobile app or a site front end gets `403` `network_not_allowed` from `/api/auth/sign_in` | Headless sign-in is restricted too. Clear **Also restrict sign-in**, or add the app's network. |
| An admin signs in from home and the console says "Not available from this network" | Expected with **Also restrict sign-in** off: sign-in is open, the console is not. |
| A security monitor gets `403` `network_not_allowed` from `/api/security/posture` | The posture endpoint is restricted too, whatever the key. Add the monitor's network to the list. |
| "This needs the running application ... Run it against the live node with `bin/kiln_cms rpc '...'`, not `bin/kiln_cms eval`." | You used `eval`. Use `rpc` against the running release. |
| `rpc` says "No organization with slug ..." | The `org:` slug is wrong. Leave it out for the default site. |

## Things to know

- **Not in the API.** The list is not on JSON:API, GraphQL or MCP: an API key
  can neither read nor change it. Only a site admin, in the console, and the
  operator commands above.
- **Security log.** Saving the list records **Admin allowlist changed**
  (`admin_allowlist_changed`) with whether it is on, the number of entries,
  how many were added and removed, and whether sign-in is restricted
  (`sign_in`: `restricted` or `open`); never the entries themselves. Refusals
  record **Refused outside the admin allowlist** (`admin_access_refused`),
  sampled at five per address per 15 minutes. See
  [security-events.md](security-events.md).
- **Metric.** `kiln_cms.admin_allowlist.refused.count`, tagged `surface` and
  `reason`; see [Observability](observability.md#admin-allowlist-refusals). No
  address is ever a tag or a log field.
- **Platform admins are not exempt.** The check runs before anyone is signed
  in. A platform admin on the default site's host is subject to that site's
  list.
- **Upgrading** adds a table, `site_admin_allowlist`; nothing changes until an
  admin saves a list. **Rolling back** to an earlier release leaves the table
  in place and turns the allowlist off without a word: the older release does
  not know about it. Upgrading to the release with **Also restrict sign-in**
  adds a column that defaults to on, so sign-in stays restricted; rolling back
  from it restricts sign-in again on every site that had turned it off.

See also the [threat model](threat-model.md#admin-allowlist-2248), the
[policy matrix](policy-matrix.md) and
[ADR 0019](decisions/0019-the-admin-allowlist-fails-closed-and-only-the-operator-lifts-it-from-outside.md).

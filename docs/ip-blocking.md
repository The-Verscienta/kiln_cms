# Blocking addresses

A site admin can refuse requests from an IP address or a range of addresses
(#2242). Use it when one source is hammering a site, scraping it, or probing it,
and you want it turned away without touching a firewall.

The list belongs to one site (organization): a block on one site does not apply to
another site on the same installation.

## What it covers, and what it does not

A blocked address gets a bare `403` with an empty body. The response does not say
a block list exists or which rule matched.

| Covered | Not covered |
|---|---|
| Every dynamic route: public pages, the JSON:API, GraphQL and REST APIs, MCP, forms, sign-in, the console | Static assets and `/uploads/*` |
| The LiveView socket (`/live`, websocket and long-poll): a blocked address is not let into any page that connects | Loopback (`127.0.0.0/8`, `::1`): never blocked |
| `/ws/gql`, `/ws/collab` and `/ws/bridge`: the handshake is refused | `/up` and `/ready`: a block must not take a site's health probes down |

Static assets and uploads are served before the request is matched to a site, so
they cannot be blocked per site. If you need those refused too, add the rule at
your CDN, reverse proxy or firewall.

### What a refusal tells your admins

A refusal raises the site's `blocked_ip` [security alert](security-alerts.md#blocked-addresses-raise-one-alert-per-window),
on by default: the site's admins get one alert per 15 minutes naming the rule
that matched ("A blocked address was refused (rule 203.0.113.0/24)"), then a
summary of how many client networks were refused. Refusals are also written to
the [security log](security-events.md) as `ip_block_refused`, sampled to one
per client network per 15 minutes, with the rule and the surface and **without
the address**. To stop the alerts, untick **Blocked addresses** on **Security
alerts** (`/editor/security-alerts`); the log entries continue.

## Block an address or range

You need the admin role. An editor does not see the page.

1. Open **Blocked addresses** under **Sign-in & access** in the console
   sidebar, or go to `/editor/ip-blocks`.
2. Under **Address or range**, type an IPv4 or IPv6 address, with an optional
   `/prefix`: `203.0.113.7`, `203.0.113.0/24`, `2001:db8::/32`. A bare address
   blocks just that address.
3. Optionally fill **Note** (why it was blocked) and **Expires (UTC)**. Leave the
   expiry empty to block until you remove it.
4. Select **Block**. You see "Address blocked." and the rule appears under
   **Current blocks**.

Requests from that address are refused from then on, on every node, within moments
(see "How fast a change takes effect").

To lift a block, select **Remove** beside it and confirm "Stop blocking ...?". You
see "Block removed." A rule cannot be edited: remove it and add another.

### Rules the form refuses

The messages are shown in the console language (English, Spanish, French).

| Message | Meaning |
|---|---|
| Enter an IP address or a range like 203.0.113.0/24. | Not an address. Leading zeros in an octet (`010.0.0.1`) and spaces inside are refused. |
| That range is too broad: use at least /8 for IPv4 or /16 for IPv6. | One keystroke must not block most of the internet. `0.0.0.0/0` and `::/0` land here. |
| A range must not include loopback (127.0.0.0/8 or ::1). | Probes and local tooling arrive from loopback. |
| That range is already blocked. | The same range is already on the list (see below). |
| The expiry must be in the future. | The expiry is not later than now. |
| The expiry is not a valid date and time. | The expiry could not be read. |

Every rule is stored in one spelling: host bits are cleared (`10.1.2.3/8` becomes
`10.0.0.0/8`), IPv6 is compressed, and an IPv4-mapped IPv6 range is stored as the
IPv4 range it means. So `10.0.0.0/8` and `10.1.2.3/8` are the same rule.

### Blocking yourself

If the range includes the address the console sees you at, or the console cannot
tell what your address is, the page stops with **This block may lock you out.**
and the range and your address. **Block it anyway** adds it; **Cancel** does not.
Think twice: the next request from you gets the empty `403`.

### Behind a proxy

When a site runs behind a reverse proxy, the address Kiln sees is the proxy's
unless the proxy is declared. Set `TRUSTED_PROXIES` (or, on Fly.io, Railway and
DigitalOcean, `CLIENT_IP_HEADER`); see [Environment variables](environment-variables.md).
Without it, a rule matches the proxy's address: blocking "the abuser" blocks every
visitor. When Kiln detects forwarded requests with neither set, the page shows
**Visitor addresses may be your proxy's.** and the self-block check cannot be
trusted. Fix that before adding rules.

## Block scanners automatically

Probes arrive as a burst of 404s: `/wp-login.php`, `/.env`, `/.git/config`, a
thousand guessed slugs. With smart 404 blocking on (#2253), Kiln adds a
temporary rule for such an address by itself, so you do not have to find it in
the logs. It is **off by default** and changes nothing until you turn it on.

### Turn it on

You need to set an environment variable on the deployment, so this is an
operator task. The admin console has no switch for it.

1. Set `KILN_SCANNER_BLOCKING=1` in the environment of every node and restart
   (the variables are read at boot; see
   [Environment variables](environment-variables.md#smart-404-blocking-2253)).
   If the site is behind a reverse proxy, set `TRUSTED_PROXIES` first (see
   "Behind a proxy" above): without it Kiln sees the proxy's address and never
   counts the request, so nothing is blocked, which is safe but pointless.
2. Optionally tune the limits. The defaults are 60 misses per 10 minutes
   (`KILN_SCANNER_BLOCKING_THRESHOLD`, `KILN_SCANNER_BLOCKING_WINDOW_MINUTES`),
   5 hits on bait paths in the same window (`KILN_SCANNER_BLOCKING_BAIT_THRESHOLD`)
   and a block of 60 minutes (`KILN_SCANNER_BLOCKING_BLOCK_MINUTES`).
3. Check it works from a machine that is not on a private network and is not
   your proxy: request `/wp-login.php` six times with a plain client such as
   `curl` (a script sends no browser headers, which the guard requires), then
   open `/editor/ip-blocks`. Under **Current blocks** you see your address (an
   IPv6 address as its `/64`) with the note **Automatic: scanner 404s** and an
   expiry an hour away. Further requests from it get the empty `403`.
   Admins can also see **Address blocked automatically** in the
   [security log](security-events.md).
4. Remove your test block: select **Remove** beside it.

Bait paths only trip the guard if the 404 reaches the content controller. A
path your own site serves, or one that a redirect covers, is not a miss.

Example of a tuned configuration for a site that sees heavy scanning:

```sh
KILN_SCANNER_BLOCKING=1
KILN_SCANNER_BLOCKING_THRESHOLD=30
KILN_SCANNER_BLOCKING_BAIT_THRESHOLD=3
KILN_SCANNER_BLOCKING_BLOCK_MINUTES=240
```

The list of bait paths is code config only (no environment variable). Set it in
an overlay's `config/config.exs`; it **replaces** the built-in list, which holds
paths such as `/wp-login.php`, `/xmlrpc.php`, `/.env`, `/.git`, `/phpmyadmin`
and `/cgi-bin`:

```elixir
config :kiln_cms, :scanner_blocking,
  bait_paths: ["/wp-login.php", "/.env", "/internal-probe"]
```

A path matches case-insensitively, exactly or as a directory prefix
(`/.git` matches `/.git/config`). Include only paths your sites never serve.

### What counts, and what never does

Every miss on public content delivery counts toward the miss threshold; a miss
on a bait path also counts toward the stricter bait threshold. A threshold is
crossed when the count for the address goes past it inside the window: with
the defaults, the 61st miss or the 6th bait-path hit within the same window. The window
is **fixed**, aligned to the clock, not sliding: a burst that straddles a
boundary is split across two windows and may need to be larger to trip.

Never counted, so a person or a service is not blocked by mistake:

- Anything other than a `GET` or `HEAD` request, a signed-in visitor, and any
  404 that is not a public page: API, media and static files are not counted,
  and neither is a path a redirect handles.
- A request that looks like it came from a browser, that is, one carrying
  `Sec-Fetch-Mode` or `Sec-Fetch-Dest`, or a `Sec-Fetch-Site` other than `none`
  or `same-origin`. A scanner script does not send them; a person following a
  stale link does. (A scanner may send them to evade the guard.)
- Loopback, private (RFC 1918), unique-local, link-local and CGNAT
  (`100.64.0.0/10`) addresses, and any range in `TRUSTED_PROXIES`.
- A request with a forwarding header (`X-Forwarded-For` and similar) when no
  proxy is trusted: the address is then the proxy's.
- An address already on the block list.
- For the **miss threshold only**, a client whose `User-Agent` names a search
  engine (Googlebot, Google-InspectionTool, Bingbot, DuckDuckBot, Applebot,
  YandexBot, Baiduspider) and no AI crawler, unless reverse DNS has proven the claim false (see
  [Verified search engines](bot-budgets.md#verified-search-engines)). A claim
  still being checked, or whose lookup could not start, keeps the exemption,
  so a real crawler's first misses from a new address never count.
  DuckDuckBot cannot be checked and is always exempt. When DNS gives no answer
  (#2588):
  - **No answer to the reverse (PTR) query**: the claim keeps the exemption
    only while this node's resolver is itself failing. While the resolver
    answers other lookups, the silence is the address's own reverse zone,
    which a scanner can leave silent on purpose, so its misses count. To
    tell the two apart, when the guard meets such a claim and no lookup on
    this node has had an answer in the last minute, the node sends one PTR
    query for `8.8.8.8`, never a visitor's address, at most once a minute;
    if that goes unanswered too, the resolver is failing and the exemption
    stays. Until such a query has found the resolver
    failing, misses count.
  - **No answer to the forward (A or AAAA) query** for a name under the
    engine's own domain: the claim keeps the exemption. That silence is in
    the engine's zone, which the address's owner does not control. With `KILN_CRAWLER_VERIFICATION=false`
  the six names Googlebot, Bingbot, DuckDuckBot, Applebot, YandexBot and
  Baiduspider in the user agent are enough. **Bait paths count for everyone**:
  no crawler has a reason to ask for one.

Link-preview fetchers (`facebookexternalhit`, `Twitterbot`, `LinkedInBot`) and
Yahoo's `Slurp` are **not** exempt, since #2254: anyone can claim to be one,
and there is nothing to check them against. A site whose shared links often
point at pages that 404 can see a preview fetcher's address blocked; remove the
block on `/editor/ip-blocks` and fix or redirect the links.

An IPv6 client is counted and blocked as its `/64`, because a host can rotate
through its whole prefix. IPv4 is blocked as a single address.

At the moment of a trip the block is skipped if the address has a successful
sign-in on this site in the last 24 hours: someone behind a shared address who
can sign in is not a scanner.

### How a block behaves

- It is an ordinary rule with the note **Automatic: scanner 404s** and an
  expiry, so it shows on `/editor/ip-blocks`, takes effect like any other (see
  "How fast a change takes effect") and ends by itself after
  `KILN_SCANNER_BLOCKING_BLOCK_MINUTES`.
- **A false positive heals itself** when the block expires. To lift it sooner,
  select **Remove** beside it, or use the lock-out commands below.
- A trip is claimed once per block window. If the guard decides not to block
  (the cap, a recent sign-in, a database error), it does **not** try again for
  that address until the window rolls over.
- At most **300** automatic rules per site are active at once (`max_auto_rules`
  in `config :kiln_cms, :scanner_blocking`; not an environment variable). At the
  cap a new trip is skipped and a warning without any address is logged: the
  guard never removes a rule, because it is not allowed to.
- Counting is off the request path and **fails open**: if the counter is
  dropped under load or the database fails, the 404 renders and nothing is
  blocked. Counters live in the shared throttle table, so limits hold across
  nodes.
- Turning the setting off stops new blocks. Rules already created stay until
  they expire or you remove them.

### Watching it

The counter `kiln_cms.scanner_guard.blocked.count`, tagged `reason`
(`miss_threshold` or `bait_path`), counts new blocks; see
[Observability](observability.md#blocked-addresses). Each block is also one
`ip_auto_blocked` event in the security log. The address is never a metric tag
or a log field. Creating the block raises no alert; the requests it then
refuses raise `blocked_ip` like any rule's (see
[What a refusal tells your admins](#what-a-refusal-tells-your-admins)).

### What can go wrong

| You see | Meaning |
|---|---|
| Nothing is ever blocked | The variable is not set, or is set to a value Kiln did not recognise (a warning on stderr names it). Or the site is behind a proxy with no `TRUSTED_PROXIES`, or your test client is on a private network. |
| A visitor reports an empty `403` | They tripped the limit (a crawler gone wrong, a link checker, a browser extension). Find the rule on `/editor/ip-blocks` by its note and **Remove** it, or wait for the expiry. Consider raising `KILN_SCANNER_BLOCKING_THRESHOLD`. |
| A search engine's address is blocked (most often Baiduspider or YandexBot) | Its claim was proven false, or its reverse zone was slow to answer while this node's resolver answered others, so its misses counted (#2588). Check the address against [Verified search engines](bot-budgets.md#verified-search-engines); if it is the engine's, **Remove** the rule or wait for the expiry. |
| An address you expected is not blocked | It is exempt (see above), the trip was skipped (cap, recent sign-in) and the window has not rolled over, or the count straddled two windows. |
| A warning `ScannerGuard: block skipped, at the automatic rule cap` | 300 automatic rules are active on the site. Wait for expiry, remove rules, or raise `max_auto_rules`. |
| A warning `ScannerGuard: block skipped, could not store the rule` | The rule could not be saved (a database fault, or the range was refused). The request was served normally. |

## How fast a change takes effect

Each node keeps a site's rules in a small cache for **one minute**. Adding or
removing a rule in the console clears that cache on every node at once. An
expiry takes effect at the second it passes, not at the next refresh. A rule
changed directly in the database is seen when the minute is up.

There is no environment variable for this: the behaviour is fixed. (Automatic
blocking, above, has its own variables.)

## Recovering from a lock-out

If an admin blocked the range they work from (a shared proxy or a whole office
included), the console cannot be reached from it. An operator with shell access
to the running release lifts the block, from any network. Use `rpc`, not `eval`:
the change must reach the running node and clear every node's cache.

List the site's rules first (nothing is changed):

```sh
bin/kiln_cms rpc 'KilnCMS.Release.ip_blocks()'
```

Remove one rule, or every rule:

```sh
bin/kiln_cms rpc 'KilnCMS.Release.ip_blocks(cidr: "203.0.113.0/24", remove: true)'
bin/kiln_cms rpc 'KilnCMS.Release.ip_blocks(remove: true)'
```

Options: `org: "<slug>"` for a site other than the default one, `cidr:` to act on
one rule (typed any way the form accepts), `remove: true` to delete (without it
the call only lists). The result prints what was found or removed, and the
change takes effect on every node at once. It runs as the `:operator` system
actor, which may list and remove rules but not add them.

`rpc` exits `0` whatever the call returns, including an error such as an unknown
site slug or a `cidr:` with no rule. A script that must fail on an error matches
the result: `'{:ok, _} = KilnCMS.Release.ip_blocks(remove: true)'`.

Without a release, from a checkout or a database console, deleting the row also
works, and is seen when the one-minute cache runs out:

```sql
DELETE FROM ip_block_rules WHERE cidr = '203.0.113.0/24';
-- or, to clear every rule: DELETE FROM ip_block_rules;
```

You can also reach the console from another network, or over loopback, which is
never blocked.

## Things to know

- **Expired rules are not swept, but they do not hold the range.** An expired rule
  stops matching and stays on the page, marked **Expired**, until you **Remove** it
  or add the same range again: the new rule replaces the expired one. Adding a
  range that has an *active* rule still says "is already blocked".
- **It fails open.** If the rule list cannot be read (database down), requests are
  let through and a warning without any address is logged. Nothing is cached from
  a failed read, so the next request tries again.
- **No address is logged.** Every refusal counts on the
  `kiln_cms.ip_block.refused.count` counter, tagged by surface (see
  [Observability](observability.md#blocked-addresses)), and a sample of them is
  written to the security log as `ip_block_refused` with the rule and surface
  only. Neither carries the address, nor does the `blocked_ip` alert.
- **Automatic rules share the list.** They carry an expiry, so they follow the
  "expired rules" behaviour above too, and the scanner guard may only add rules;
  an admin can still remove one at any time.
- **Not in the API.** Block rules are not on JSON:API, GraphQL or MCP, so an API
  key can neither read nor edit them. Only an organization admin, in the console.
- **Upgrading** adds a table, `ip_block_rules`; nothing existing changes. Rolling
  back leaves the table in place and unused.

To do the opposite, and admit only listed networks to the console and sign-in,
see [Restricting sign-in to your networks](admin-allowlist.md). A block always
wins: an address that is both blocked and allowlisted is blocked.

To slow a client down rather than refuse it, by what its user agent says it is
(a crawler, a script, no user agent), see [Bot budgets](bot-budgets.md).

See also the [threat model](threat-model.md#blocked-addresses) and the
[policy matrix](policy-matrix.md).

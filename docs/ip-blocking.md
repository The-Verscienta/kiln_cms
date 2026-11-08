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

## Block an address or range

You need the admin role. An editor does not see the page.

1. Open **Blocked addresses** in the console sidebar (it sits with the security
   settings), or go to `/editor/ip-blocks`.
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

## How fast a change takes effect

Each node keeps a site's rules in a small cache for **one minute**. Adding or
removing a rule in the console clears that cache on every node at once. An
expiry takes effect at the second it passes, not at the next refresh. A rule
changed directly in the database is seen when the minute is up.

There is no environment variable: the behaviour is fixed.

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
- **No address is logged.** The only trace of a refusal is the
  `kiln_cms.ip_block.refused.count` counter, tagged by surface; see
  [Observability](observability.md#blocked-addresses).
- **Not in the API.** Block rules are not on JSON:API, GraphQL or MCP, so an API
  key can neither read nor edit them. Only an organization admin, in the console.
- **Upgrading** adds a table, `ip_block_rules`; nothing existing changes. Rolling
  back leaves the table in place and unused.

To slow a client down rather than refuse it, by what its user agent says it is
(a crawler, a script, no user agent), see [Bot budgets](bot-budgets.md).

See also the [threat model](threat-model.md#blocked-addresses) and the
[policy matrix](policy-matrix.md).

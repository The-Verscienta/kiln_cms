# 0026. The IP block list fails open, and covers dynamic routes only

- **Status** — accepted (2026-11-10).
- **References** — [#2242](https://github.com/The-Verscienta/kiln_cms/issues/2242)
  (PRs #2398, #2404, #2428, #2429); the threat model's "Blocked addresses"
  section; [ADR 0019](0019-the-admin-allowlist-fails-closed-and-only-the-operator-lifts-it-from-outside.md)
  for the opposite choice on a different control.
- **Changelog** — the Unreleased section of [CHANGELOG.md](../../CHANGELOG.md).

## The problem

An operator-defined block list refuses requests by address. Two questions
decide whether it protects the site or becomes a way to take it down, and a
later reader will be tempted to answer both the other way:

- **What happens when the list cannot be read** (database down, a lost
  grant, a cache outage)?
- **Which requests does it cover**, given that the app answers some of them
  before it knows which site they are for?

## Decision

- **An unreadable list lets the request through.** `KilnCMS.Security.IpBlocklist`
  reads a site's rules as the `:ip_block` system actor with
  `authorize_with: :error`, so a refused read is an error and not an empty
  list. On any error it returns "not blocked", logs one warning that carries no
  address, and **does not cache the failure**: the next request reads again.
  The same holds for the socket checks, which also let a connect through when
  the address or the site cannot be resolved.
- **Loopback, `/up` and `/ready` are never blocked**, whatever the rules say.
  Rules are also refused on write if they contain loopback or are wider than
  `/8` (IPv4) or `/16` (IPv6), and adding a rule that contains the admin's own
  address needs an explicit confirmation.
- **Only dynamic routes and the sockets are covered.** The plug sits right
  after `SetTenant`, because the rules are per organization and the
  organization is not known earlier. `Plug.Static` (assets and `/uploads`) sits
  above tenant resolution and cannot be scoped to a site, so it is not covered.
  `/live`, `/ws/gql`, `/ws/collab` and the bridge socket bypass the endpoint's
  plugs and each check for themselves.
- **The answer is a bare `403`**, with no body, no rule, no hint that a list
  exists. Nothing logs the address; the only trace is the
  `kiln_cms.ip_block.refused.count` counter, tagged by surface.

## Rejected

- **Fail closed when the list cannot be read.** It is the right default for a
  control that guards a secret (ADR 0019 does it for the admin allowlist). This
  one guards against abuse, and failing closed would turn a database blip into
  a total outage for every visitor, which is worse than the abuse it answers.
  The exposure is bounded: a block list that is briefly unreadable is a block
  list that briefly does not block, and the read is retried on the next request.
- **Cache the failure to spare the database.** An outage would then keep the
  list "empty" for a full TTL after the database came back.
- **Move `Plug.Static` below the block plug.** It would need the organization,
  which means a database read per asset, on the cheapest and highest-volume
  traffic the app serves. Uploads live in a shared directory addressed by UUID,
  so there is no organization to look up in any case. The honest scope is
  written down instead; an operator who needs assets refused too puts the rule
  at the CDN, reverse proxy or firewall, which is also where volumetric abuse
  is best answered.
- **Block ahead of tenant resolution, on a deployment-wide list.** Cheaper, but
  a block on one site would apply to every site on the installation.
- **Expose the list on JSON:API, GraphQL or MCP.** A block list editable with a
  scoped API key is a way to lock a site out of itself. It is edited in the
  console only.

## Consequences

- An outage that stops the list being read also stops it blocking, for as long
  as it lasts. The warning in the log is the signal.
- A blocked address can still fetch static files and uploads; this is stated on
  the admin page, in `docs/ip-blocking.md` and in the threat model.
- Behind a reverse proxy the list only matches real client addresses when
  `TRUSTED_PROXIES` is set; with it unset every client resolves to the proxy's
  address. The admin page warns when it detects that state.
- A lock-out (a rule that matches the operators) is recovered outside the app,
  with `KilnCMS.Release.ip_blocks/1` over `rpc` or by deleting the row, and takes
  effect within the cache TTL of one minute.
- An expired rule stops matching at its expiry and is replaced if the same
  range is added again; it is not swept in the background.

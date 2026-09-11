# Multi-tenancy

One Kiln deployment can serve many sites. Each site is an **organization**
(`KilnCMS.Accounts.Organization`), and an org's content, media, taxonomy,
forms, analytics, newsletter and history are isolated from every other org's.
A single-site install is just a deployment with one org — the **default org** —
and never has to think about any of this.

This page is the isolation model in one place. The configuration table is in
[environment-variables.md](environment-variables.md#optional--multi-tenancy-336);
who can do what *within* an org is in [granular-rbac.md](granular-rbac.md).

## The model: one database, rows tagged by org

Kiln uses Ash **attribute multitenancy**: every per-site table carries an
`org_id` column, and every read and write on it is filtered by the request's
org. It is not schema-per-tenant — one set of tables, one set of indexes, one
migration run — because schema-per-tenant would multiply the pgvector and
trigram search indexes by the number of sites.

The data layer **fails closed**. `config :kiln_cms, :strict_tenancy` (on by
default, compile-time) makes every org-scoped resource *require* a tenant
(`global?: false`), so an action that forgets to pass one is an error rather
than a read across every org. The few reads that are deliberately org-spanning
— resolving a newsletter confirm/unsubscribe token and billing webhooks, which
arrive knowing a token or a payment id rather than a host — are marked
`multitenancy :bypass` action by action, and then scope themselves to the org
of the row they found.

## How a request finds its org

`KilnCMSWeb.Tenant.fetch_org/1` resolves the org from the request's **host**,
in this order:

1. a subdomain of `TENANT_BASE_HOST` (default: `PHX_HOST`) —
   `acme.example.com` → the org whose slug is `acme`;
2. an exact `custom_domain` on an org — `www.acme.com`;
3. otherwise the **default org**.

`KilnCMSWeb.Plugs.SetTenant` runs this in the endpoint, before the router, and
sets the result as the Ash tenant — so the JSON:API and GraphQL surfaces are
scoped with no per-resolver code. LiveView mounts and all three sockets
(`/ws/gql`, `/ws/bridge`, `/ws/collab`) resolve the same way from the URI they
**connected** on, never from anything the client sends in its payload.

Lookups are cached (`KilnCMS.Cache.Hosts`), so resolution is not a query per
request.

## The default-org fallback, and `TENANT_STRICT_HOST`

Step 3 is right for a single-host install — a bare hostname, an IP literal or
`localhost` should reach the only site there is. On a multi-tenant deployment
it is wrong: any request with an unrecognized `Host`, including an
attacker-supplied one, would be served the default org's content, branding and
analytics.

**Set `TENANT_STRICT_HOST=true` on every multi-tenant deployment.** An
unmatched host then gets a `404` (or a `503` with `retry-after` if the lookup
could not run because the database is down) instead of the default org. The
apex (`PHX_HOST`) is never refused; health probes and the payment webhook are
exempt. The full behaviour, including what static files do, is under
[`TENANT_STRICT_HOST`](environment-variables.md#optional--multi-tenancy-336).

Kiln warns if you forget: at boot, when the second org is created, and on
`/editor/system` for as long as the gap stays open.

## What is per-org and what is deployment-wide

**Per org** (carries `org_id`): every content type and its versions, published
artifacts and their reference graph, media, categories and tags, dynamic
content types and custom fields, forms and submissions, webhooks and their
deliveries, analytics, funnels and experiments, newsletter subscribers and
sends, automation rules, document history, custom roles, and the org's
settings (branding, public theme, editorial settings). Cache keys for these
include the org id, and search results are filtered to the request's org.

**Deployment-wide** (no `org_id`): user accounts and their sign-in methods
(passwords, passkeys, SSO identities, tokens), API keys, outbound mail
settings (sender and DKIM key — one per deployment), billing settings, the
mail suppression list, and federation replay protection.

So one person has **one account** across sites and belongs to orgs through
`KilnCMS.Accounts.OrgMembership`, which carries their tier (`:admin` /
`:editor` / `:viewer`) and editorial scope *for that org*. An account that
holds any membership has **no** access to an org it isn't a member of — the
org comes from the host, which the client controls, so falling back to the
account's global role there would let a scoped editor escape by switching
hosts. A platform admin (`User.role == :admin`) is the exception and keeps
admin everywhere. Details: [granular-rbac.md](granular-rbac.md), "Per-org
capability tiers".

API keys belong to a user, not an org. A headless request is scoped to the org
its host resolves to, and the key's user is authorized there like any other
actor.

## Creating an org

Creating and updating orgs is a **platform-admin** action
(`KilnCMS.Accounts.create_organization/2` with an admin actor); there is no
screen for it yet. An org has a `name`, a `slug` (its subdomain) and an
optional `custom_domain`. Members are then managed per org at
`/editor/team`.

Orgs cannot be deleted: paper-trail version rows outlive the content they
describe, and deleting an org would strand them. A single-tenant install that
wants a hard guarantee can set `config :kiln_cms, :multitenancy_enabled, false`,
which refuses any org beyond the default one.

## Serving the console from its own host

By default each org's editor console answers on that org's own host, so a
page's custom scripts are same-origin with the console. `KILN_CONSOLE_HOST`
serves the console from one dedicated host instead; tenant content is never
served there. The console host resolves to the default org, which makes it
the right fit for a single-org deployment. See
[environment-variables.md](environment-variables.md) and
[code-injection.md](code-injection.md#read-this-before-granting-the-role).

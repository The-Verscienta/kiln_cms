# 0090. A browser session is bound to the site it signed in on, and a session presented on another site's host is signed out there

- **Status** — accepted (2026-11-26).
- **References** — [#2246](https://github.com/The-Verscienta/kiln_cms/issues/2246)
  (idle timeout and "sign out everyone"), shipped in
  [#2489](https://github.com/The-Verscienta/kiln_cms/pull/2489);
  [#2491](https://github.com/The-Verscienta/kiln_cms/issues/2491) (the
  follow-ups that asked for this record);
  [ADR 0018](0018-a-site-may-only-lower-a-deployment-ceiling-refused-on-write-clamped-on-read.md)
  (when an operator's value is a ceiling);
  [ADR 0087](0087-a-socket-opened-from-a-sign-in-lives-no-longer-than-that-sign-in.md)
  (sockets close with their session).
- **Changelog** — the Unreleased section of [CHANGELOG.md](../../CHANGELOG.md),
  under Fixed ([long form](../changelog/unreleased.md#idle-component-activity)).

## The problem

Accounts belong to the whole deployment, and one Kiln serves many sites. Until
#2489 a browser session belonged only to its account: a token row named the
user and nothing else. That was enough while every sign-out was per account,
and it stopped being enough as soon as a site admin could end sessions:

- **A site's rules need a site to apply to.** An idle timeout chosen by site A,
  and A's "sign out everyone", must end the sessions used on A and leave the
  same person's sessions on site B alone. A row that names no site can only be
  ended for the whole account, which lets one site's admin sign people out of
  sites they do not administer.
- **A cookie carried to another host is a stolen cookie.** The session and
  remember-me cookies are host-only. A cookie issued on A's host that arrives
  on B's host was copied there by someone. If it worked on B, B's protections
  (its idle timeout, its own sign-out) would be decided by whichever site the
  copy came from, and an admin who signed everyone out on A would have to sign
  out B as well to end the copy.

## The decision

**A browser session belongs to one site: the one it signed in on. Presented on
any other site's host, it is signed out there and nothing is written to it.**

- **The binding is a column.** A session's token row and its remember-me row
  record their site in `tokens.org_id`, written at sign-in. A row from before
  #2489 has none, and is bound to the first site whose host uses it.
- **The other host refuses, it does not revoke.** A row bound to another site
  arriving on this host is answered `{:signed_out, :foreign}` by
  `KilnCMS.Accounts.IdleTimeout.verdict/4`: the request is served signed out,
  and the row is neither revoked, touched nor rebound, so the copy can neither
  be used here nor keep the session awake from here, and the real browser on
  its own site is unaffected. The writes a cookie can reach are filtered on
  the account (`subject`) as well, so a foreign or forged jti changes no one's
  row.
- **Binding cannot launder a row past a sign-out.** A site's "sign out
  everyone" revokes every row bound to it, then records a watermark
  (`SiteSessionPolicy.sessions_revoked_at`) for the rows it could not name:
  unbound ones signed in earlier. The token actions that bind an unbound row
  to a site refuse a row that predates that site's watermark, in the same
  statement (`predates_sign_out_all`), so such a row cannot escape by being
  used first; it is revoked the next time it is seen on the site. The
  watermark is consulted only while something that predates it could still be
  alive: `IdleTimeout.watermark_horizon_seconds/0`, the longest of the session
  token's lifetime, the remember-me token's and a two-factor hold's (30 days
  today), derived from the sign-in configuration so that raising a lifetime
  widens it.
- **The site decides its idle timeout, and it fails open.** The timeout in
  force is the site's own `SiteSessionPolicy`, for the account's tier on that
  site, recomputed at every check. There is no operator ceiling and no
  environment variable: a looser timeout costs that site's own accounts and
  nobody else, which is the case ADR 0018 leaves to the site. An unreadable
  policy row is logged and read as "no timeout, no watermark" for that
  request, rather than signing every account out during a database fault.
- **Only browser sessions are bound.** Bearer JWTs (headless app tokens from
  `POST /api/auth/sign_in`) and API keys name no site, carry no cookie a host
  could scope, and are untouched by a site's idle timeout and "sign out
  everyone". A `/ws/gql` socket opened with a bearer applies no site rule for
  the same reason (ADR 0087).

## Rejected

- **Per-account sign-outs only.** Simple, and the reason this record exists: a
  site's idle timeout or "sign out everyone" would end the same person's
  sessions on every other site.
- **Rebinding a session to whichever site uses it.** It would make the
  binding meaningless: a copied cookie would move with the copy, and a session
  could be walked from a site that signed it out to one that has not.
- **Revoking a foreign row where it is seen.** Anyone holding a copy of a
  cookie could then sign its owner out of their own site by presenting it on
  another host.
- **One session valid on every site, with the site checked per request.**
  Each site's rules would then apply to every other site's sessions, and a
  site's "sign out everyone" could not tell its sessions from the rest.
- **An operator ceiling on the idle timeout.** Nothing the deployment shares
  is spent by a site that keeps sessions longer; the operator's interest is
  covered by the per-account sign-outs, which still reach every site.
- **Signing everything out when the policy cannot be read.** A database blip
  would sign out every account on the site at once.

## What it leaves open

- **The binding stops a cookie replayed elsewhere, not an account that later
  gains access elsewhere.** A session is bound to its site, not to the access
  the account had when it signed in. That is why a site's own single sign-on
  still checks at admission that the account reaches no other site
  (`KilnCMS.Accounts.SiteSso.Admission`); see "A site's own sign-in
  provider" in the [threat model](../threat-model.md).
- **Unbound rows** from before #2489 are bound by first use. Until then a
  site's "sign out everyone" catches them only through its watermark, for the
  horizon above.
- **Bearer tokens and API keys** need a per-account sign-out or a password
  reset to end, as before.
- **Fail-open** on an unreadable policy row, as above.

## When to revisit

When Kiln gains a credential a browser carries between hosts on purpose (a
shared sign-in across a site's several hosts, say), or a site rule that should
reach bearer tokens: either changes what "the site it signed in on" means.

# 0005. The production session cookie is `__Host-`-prefixed, with no dual-read window

- **Status** — accepted, shipped in
  [0.5.0](../changelog/v0.5.0.md) (Security).
- **References** — [#490](https://github.com/The-Verscienta/kiln_cms/issues/490), [#686](https://github.com/The-Verscienta/kiln_cms/issues/686).
- **Changelog** — [0.5.0 → Security](../../CHANGELOG.md#050---2026-08-09).

## Decision

**The session cookie is `__Host-`-prefixed in production.** It carried no
`Domain`, which makes it host-scoped for *reads* — but RFC 6265 puts no such
limit on *writes*. Every org is a sibling host under one registrable domain
(`<slug>.<base_host>`), so script running on any tenant origin could set
`_kiln_cms_key; Domain=.<base_host>`, and the browser would then send two
cookies of that name to a sibling.

Which one is honoured is not a race the victim might win. Plug builds its
cookie map so the **first** pair in the header survives, and RFC 6265 §5.4
sends longer `Path`s first — so `Domain=.<base_host>; Path=/editor` outranks
the victim's own `Path=/` cookie on exactly the authoring routes worth taking.
Planting the cookie in a browser with no session yet works just as well, and
survives sign-out, because the server only ever deletes a cookie it set
itself. The victim then browses another org inside a session the attacker
controls. The origins that can run script are not hypothetical — a stored XSS
on the attacker's own tenant, a dangling subdomain, and #490's per-org code
injection, which is *designed* to run an org admin's script there.

`__Host-` is the only mechanism that makes host-scoping structural rather than
conventional, and it closes the hole at the source rather than at the tie: the
browser refuses to *store* a cookie of that name unless it is `Secure`,
`Path=/`, and carries no `Domain`, so the sibling origin's write never
happens. That is already the shape Kiln configures, so the prefix costs
nothing except that it cannot be used without `Secure` — and dev, test and e2e
run over plain HTTP. It therefore rides the same `:secure_session_cookie` flag
as `Secure` itself, in one expression, so the two cannot drift apart and leave
the browser silently discarding every session.

The cookie's whole shape now lives in `KilnCMSWeb.SessionCookie` rather than
in the endpoint, because the production shape is the one no test build ever
emits: the suite constructs `options(true)` directly, drives it through
`Plug.Session`, and asserts the emitted `Set-Cookie` satisfies every
precondition the browser enforces — plus that `config/prod.exs` still asks for
the flag at all, read the way a release reads it. A non-boolean value raises
by name instead of being coerced, since `"false"` is truthy and would
otherwise pair `Secure` with the unprefixed name. Renaming the cookie signs
everyone out once — see **Upgrading**. (#686)

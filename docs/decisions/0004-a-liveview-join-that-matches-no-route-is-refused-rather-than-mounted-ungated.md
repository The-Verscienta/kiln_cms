# 0004. A LiveView join that matches no route is refused rather than mounted ungated

- **Status** — accepted, shipped in
  [0.5.0](../changelog/v0.5.0.md) (Security).
- **References** — [#688](https://github.com/The-Verscienta/kiln_cms/issues/688).
- **Changelog** — [0.5.0 → Security](../../CHANGELOG.md#050---2026-08-09).

## Decision

**A LiveView join with no URL is refused instead of skipping every router
gate.** LiveView's channel has a catch-all for a join payload carrying
neither `"url"` nor `"redirect"`: it matches no route, and Phoenix attaches a
`live_session`'s `on_mount` hooks only when a route matched. So such a join ran
none of the authoring gates — not `:current_user`, not `:assign_current_org`,
and not `:live_editor_required` / `:live_admin_required`, which are the
router-level RBAC for `/editor/*` and the admin console. The credential needed
to try it is the signed `data-phx-session` blob, scraped from any page the
caller was legitimately served — a token that outlives both the visit and a
later demotion.

Nothing rendered before this either, and the sweep says so: all 26 authoring
routes refused. But 24 of them refused by *raising* — usually `KeyError` on
`:current_user`, the assign the skipped hook was supposed to set — and two
(`/editor/billing`, `/editor/system`) refused cleanly only because they also
gate in their own `mount/3`. That is fail-closed by accident. Every probe cost
an unhandled exception and a crash report, and the property held only for as
long as every LiveView happened to read an assign the router had promised it;
a new LiveView reading none would have mounted and rendered, ungated.

`KilnCMSWeb.LiveRouteGuard` makes the refusal deliberate and uniform. It has to
hang off the view rather than the `live_session`, because the router's hooks
are precisely what does not run — what survives is the `on_mount` list declared
by the LiveView module, so `use KilnCMSWeb, :live_view` declares it and every
one of Kiln's views carries it. A test walks the router and fails if any `live`
route's view does not, which also covers plugin panels: `KilnCMSWeb.PluginRouter`
compiles third-party modules straight into the admin-gated `live_session`, so
"plugins follow the convention" needed to be enforced rather than assumed.

It refuses a connected join that matched no route **and whose session names a
`live_session`** — the second half is what makes the first safe. A *sticky*
`live_render` child is signed with no parent pid and the parent's router, which
is what lets it outlive the parent, so by the framework's own definition it is
a "main" session, and the JS client deliberately sends it no URL. Refusing on
"root with no route" would 404 every sticky child, and since the client turns a
404 into a page reload, the reload would re-render the child and 404 again — a
loop rather than a degradation. `socket.sticky?` cannot be the exemption
either: it is unsigned client input, so keying off it would let a scraped root
token through by adding one field. `live_session_name` is signed, is always
present on a root session and never on a nested one, and reads as the question
actually worth asking — were there `live_session` hooks that should have run,
and didn't?

`plug_status: 404` puts the refusal in the range the channel turns into a
client reload rather than a process crash, so a url-less probe costs no crash
report and an honest client reloads through the router, where every gate runs.
(A *malformed* join — say `"url" => nil` — still crashes: that happens in the
channel before any mount hook, so it is outside what this can reach.) Every
refusal logs at debug, matching the existing refusal in `LiveUserAuth`: a line
per refusal is client-triggerable and therefore an unbounded write, but an
operator investigating a stolen token can drop the level and see which views it
was replayed against. Third-party LiveViews keep the framework behaviour:
AshAdmin's are compile-gated to `:dev_routes`, and AshAuthentication's sign-in
views are unauthenticated — a url-less join to one reaches no authorization it
could not reach signed out, though it does skip `:assign_current_org` and so
wears the default org's branding rather than the host's. (#688)

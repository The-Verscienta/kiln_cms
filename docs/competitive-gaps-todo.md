# Competitive Gaps — Todo

Feature gaps identified when comparing Kiln to Strapi, Payload, Craft CMS, and
Directus. Each item is a place where those platforms currently offer something
Kiln does not. Ordered roughly by impact on adoption. This is a backlog, not a
commitment — some gaps are deliberate design choices (see notes).

> **Reconciled against the tracker on 2026-08-28.** Five of the seven gaps have
> closed since this list was written. Only **#333** (sandboxed runtime code) and
> the control-plane half of **#334** are still open, and both are parked by
> choice rather than by effort. Newer evaluator-facing gaps are tracked as their
> own issues, not here — see [What replaced this list](#what-replaced-this-list).

> Ecosystem/community/hiring reality (Elixir being niche) is intentionally
> omitted — it's a market condition, not a buildable feature.

---

## 1. Write-capable headless APIs — [#330](https://github.com/The-Verscienta/kiln_cms/issues/330) `P0` ✅ SHIPPED

- [x] Expose content **create/update/delete** over REST (JSON:API) **and** GraphQL.
      Create/update/submit-for-review/publish/unpublish + reversible soft-delete
      on every content type and the dynamic entry tier. Body content writes via a
      public `block_tree`/`blockTree` argument (the `blocks` union stays off the
      auto surface); hard `:purge` is never exposed.
- [x] Auth story for programmatic writes: the **`:read_write` API-key scope is no
      longer MCP-only** — the JSON:API and GraphQL pipelines already accept
      `kiln_…` keys, and the *same* resource policies gate every surface (read
      key / anonymous forbidden; editor authors; admin publishes). No new auth
      code — writes reuse the MCP model exactly.
- [x] Firing interaction: re-fire is **action-scoped**, so any write path that
      calls `:publish` re-fires automatically. The `:update` action gained a
      `published`-guarded re-fire so an in-place edit of live content never
      leaves a stale artifact.

**Why:** Strapi, Directus, and Payload all offer full write APIs. This was the
single biggest blocker for "app writes back into the CMS" use cases.
**Decision:** Read-only-by-design (**D7**) was **deliberately reversed** here
(signed off before implementation). Reads are unchanged; writes are
API-key-gated. This unblocks the visual-editing bridge/SDK
([#355](https://github.com/The-Verscienta/kiln_cms/issues/355)), which was
hard-blocked on this write surface.

## 2. Runtime / marketplace extensibility — [#333](https://github.com/The-Verscienta/kiln_cms/issues/333) `P2` — original scope RESOLVED, remainder PARKED

- [x] Investigate installing plugins into a running instance (vs. compile-time
      OTP code + redeploy) — **answered "no, by design"** and written up in
      [plugin-extensibility.md](plugin-extensibility.md) §1. The BEAM has no
      in-process sandbox: hot-loaded code runs in-node with full privileges, so
      trust can only be established *before* the code enters the node. The
      "extend a live instance without a rebuild" cases are served as **data**
      instead — dynamic content types (D17), the `Kiln.FieldType` registry, and
      declarative editorial automation.
- [x] Consider a plugin registry/discovery mechanism — shipped: optional
      `version/0` / `summary/0` / `homepage/0` catalog metadata on `Kiln.Plugin`,
      `Kiln.Plugins.manifests/0` as a plain-data catalog view, and
      `mix kiln.plugins.list` for local discovery, alongside the existing
      `mix kiln.gen.plugin` → dep + config line → `mix kiln.plugins.doctor`
      install flow. "Marketplace" here means a catalog of vetted, git/hex-
      distributed, **compile-time** plugins — installers, not a code-execution
      sandbox.

**What #333 now tracks** is the genuinely different project the above ruled out:
**sandboxed runtime-code extension points**. Threat model and extension-point
surface first, then an isolation mechanism (out-of-process plugins behind a
narrow RPC/port protocol, restricted BEAM nodes with a capability broker, or a
WASM runtime with an explicit host ABI), then resource metering and failure
isolation — each a security-reviewed architecture project, not an increment.

**Why it stays parked:** [p3-plan.md](p3-plan.md) parks it deliberately. Kiln's
differentiators — immutable published artifacts, supervision-tree reliability,
content provenance — all assume the node is trusted. Opening that front needs
proven demand to justify the investment and the review burden.

**Why the gap existed:** Strapi Market, Craft's plugin store, and Directus's
marketplace let users extend a live instance without a rebuild.

## 3. Managed cloud / hosting offering — [#334](https://github.com/The-Verscienta/kiln_cms/issues/334) `P2` — partly shipped

- [ ] Scope a hosted/SaaS control plane (or a one-click deploy template) as an
      alternative to self-hosted Docker/Coolify only. **Still open** — a large
      effort *and* a business decision, not just engineering.
- [x] Staging/preview-environment tooling — shipped as the actionable slice of
      this gap (#382): one-command ephemeral staging via `scripts/staging.sh`
      (dump → restore → migrate → **scrub**) plus a
      `KilnCMS.Release.scrub_staging/0` release helper. Feature guide:
      [staging-environments.md](staging-environments.md); operator checklist:
      [deploy-staging.md](deploy-staging.md).

**Why:** Strapi Cloud, Craft Cloud, Directus Cloud, and Payload hosting all
lower the ops burden. Kiln is self-hosted only today.

## 4. Richer authentication — [#331](https://github.com/The-Verscienta/kiln_cms/issues/331) `P1` ✅ SHIPPED

- [x] SSO — sign in to the console through any **OpenID Connect** provider
      (Entra ID, Google Workspace, Okta, Keycloak, Authentik, …) via
      AshAuthentication's OIDC strategy. One provider per install; multi-IdP is
      a follow-on. See [sso.md](sso.md).
- [x] 2FA **and** passkeys, both shipped:
      **TOTP** with self-service enrolment at `/editor/settings` — enrolment
      writes to a *pending* secret slot, so starting or restarting it can never
      by itself weaken an already-confirmed account — plus single-use recovery
      codes ([two-factor-auth.md](two-factor-auth.md)).
      **Passkeys / WebAuthn** for passwordless sign-in with a platform
      authenticator or security key ([passkeys.md](passkeys.md)).
      Headless callers get the same second step: `POST /api/auth/sign_in`
      answers `200 {two_factor_required, pending_token}` rather than a JWT, and
      `POST /api/auth/sign_in/verify` redeems it.

**Why the gap existed:** email+password + magic link only. The other four all
offer SSO (often enterprise-tier), and 2FA is table stakes for many buyers.

## 5. Granular RBAC — [#332](https://github.com/The-Verscienta/kiln_cms/issues/332) `P1` ✅ SHIPPED

- [x] Per-collection **and** per-field permissions, layered on top of the
      capability tier rather than replacing it. `editable_types` /
      `readable_types` scope an editor to specific content types (empty = no
      restriction, so existing editors were unchanged), and `field_grants` add
      per-field **write** grants. Admins bypass both; viewers and anonymous
      callers never gain authoring access. Sub-block grants are deliberately out
      of scope. See [granular-rbac.md](granular-rbac.md).
- [x] Admin UI for building roles — `KilnCMS.Accounts.Role` is the
      Directus-style custom role: an admin-defined bundle of the three grant
      axes, assigned via `OrgMembership.role_id` and managed at `/editor/team`.
      Resolution is membership-attribute → role-attribute → user-column, so a
      membership can still override its role per axis.

**Note:** the `admin`/`editor`/`viewer` tier deliberately **stays** as the coarse
axis the Ash policies check — custom roles are a restriction bundle on top, not a
replacement, so the built-ins need no seeded rows.

**Why the gap existed:** Directus's fine-grained permission matrix is a headline
feature; Craft and Payload also allow more granular, configurable permissions.
The `audiences` read-axis already covered consumer-facing tiers — this gap was
about *authoring* permissions.

## 6. Visual editing experience — [#335](https://github.com/The-Verscienta/kiln_cms/issues/335) `P2`

- [x] Drag-and-drop block reorder + block palette — already shipped across the
      admin block editor (#29/#171) and the in-context on-page editor (#367).
- [x] **Nested layout composition** — the one genuine gap. A first-party
      `columns` container block ([`KilnCMS.Blocks.Columns`](../lib/kiln_cms/blocks/columns.ex))
      nests child blocks (flat list → shallow tree) with per-column drag-and-drop
      in the admin editor. See [nested layout columns](extending-content.md#6-nested-layout-columns-335).
- [x] In-context composition on the rendered page — drag-reorder on the live
      site (#354/#367) and the visual-editing bridge for external headless front
      ends (#355 → #388/#390/#391). Operator checklist:
      [deploy-write-visual-editing.md](deploy-write-visual-editing.md).

**#335 is closed:** visual page building is assembled end to end. Two ideas from
this list were **not** built and are **not tracked by any issue** — palette
drag-to-place (dragging a block *type* onto a position) and live-preview polish
to match Craft/Payload. Per #335's close-out, anything further here deserves a
fresh, concretely-scoped issue rather than a reopen; the same goes for named
layout presets and section templates.

**Why the gap existed:** marketing/editorial teams often want visual layout and
high-fidelity live preview.
**Note:** AGENTS.md explicitly declines to pull in Beacon — any solution should
be first-party.

## 7. Multi-tenancy / multi-site — [#336](https://github.com/The-Verscienta/kiln_cms/issues/336) `P2` ✅ SHIPPED

- [x] One deployment serves many sites, with **attribute-based Ash
      multitenancy** on ~53 resources (content and its versions, taxonomy,
      media, forms, analytics, …). The request `Host` picks the org — a
      subdomain of `TENANT_BASE_HOST`, or a full custom domain — resolved by
      `KilnCMSWeb.Tenant`. Set **`TENANT_STRICT_HOST=true`** on any real
      multi-tenant deployment: without it an unmatched `Host` (a bare hostname,
      an IP literal, `localhost`, or an attacker-supplied header) is served the
      **default org's** content, branding and analytics. Config table:
      [environment-variables.md](environment-variables.md#optional--multi-tenancy-336).

**Note:** a few deliberate single-org-bridge fallbacks remain where a nil tenant
reads globally (the GraphQL context resolver, point-in-time index reads). They
are intentional and documented on #336, not oversights.

**Why the gap existed:** Craft's multi-site is a marquee feature; Directus and
Strapi handle multiple projects more naturally. Kiln was
one-deployment-per-project (compile-time domains merged via `:content_domains`).

---

## Related items (already strong — not gaps, listed for context)

These were Kiln *advantages* in the comparison and are tracked elsewhere; no
action needed:

- BEAM-native real-time — PubSub and GraphQL subscriptions are on in production.
  **Caveat:** CRDT co-editing is **not**. It sits behind the `:collab_prototype`
  flag, which is on in dev and test and **off in prod**, and the flag is
  VM-global rather than per-document. Do not cite live co-editing as a shipped
  advantage until #1324 resolves — that issue exists precisely because the docs
  read as though it shipped.
- Deep security posture (Ash policies, SSRF-safe webhooks, audits)
- Built-in semantic/hybrid search (pgvector + Bumblebee + reranking)
- Built-in send-only MTA with DKIM
- First-class MCP/LLM authoring endpoint
- Firing engine (immutable multi-surface artifacts + dependency graph)

---

## What replaced this list

This list compared Kiln to Strapi, Payload, Craft and Directus in mid-2026, and
it did its job — five of its seven gaps are closed. It is **not** the live
backlog. Newer evaluator-facing gaps were filed as individual issues in August
2026 and are tracked there, not here:

| Gap | Issue |
|---|---|
| No JS/TS SDK with generated types | [#1310](https://github.com/The-Verscienta/kiln_cms/issues/1310) |
| Media library: folders/tags, filter chips, bulk operations | [#1316](https://github.com/The-Verscienta/kiln_cms/issues/1316) |
| No first-run setup wizard | [#1317](https://github.com/The-Verscienta/kiln_cms/issues/1317) |
| Public site has no theme system | [#1318](https://github.com/The-Verscienta/kiln_cms/issues/1318) |
| Field-level localization (document-per-locale only today) | [#1327](https://github.com/The-Verscienta/kiln_cms/issues/1327) |
| Co-editing is dev-only but docs read as shipped | [#1324](https://github.com/The-Verscienta/kiln_cms/issues/1324) |

Before adding a row here, check whether it belongs on an issue instead. A
checklist in a doc drifts silently; an issue does not.

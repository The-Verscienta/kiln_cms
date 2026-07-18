# Competitive Gaps — Todo

Feature gaps identified when comparing Kiln to Strapi, Payload, Craft CMS, and
Directus. Each item is a place where those platforms currently offer something
Kiln does not. Ordered roughly by impact on adoption. This is a backlog, not a
commitment — some gaps are deliberate design choices (see notes).

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

## 2. Runtime / marketplace extensibility — [#333](https://github.com/The-Verscienta/kiln_cms/issues/333) `P2`

- [ ] Investigate installing plugins into a running instance (vs. compile-time
      OTP code + redeploy).
- [ ] Consider a plugin registry/discovery mechanism.

**Why:** Strapi Market, Craft's plugin store, and Directus's marketplace let
users extend a live instance without a rebuild.
**Note:** Hard on the BEAM — hot-loading arbitrary OTP code is a big security
and stability surface. May stay compile-time by design; document the decision.

## 3. Managed cloud / hosting offering — [#334](https://github.com/The-Verscienta/kiln_cms/issues/334) `P2`

- [ ] Scope a hosted/SaaS control plane (or a one-click deploy template) as an
      alternative to self-hosted Docker/Coolify only.
- [ ] Staging/preview-environment tooling.

**Why:** Strapi Cloud, Craft Cloud, Directus Cloud, and Payload hosting all
lower the ops burden. Kiln is self-hosted only today.

## 4. Richer authentication — [#331](https://github.com/The-Verscienta/kiln_cms/issues/331) `P1`

- [ ] Add SSO / OAuth / SAML provider strategies (AshAuthentication supports
      OAuth2 add-ons).
- [ ] Add 2FA / TOTP and/or passkeys.

**Why:** Email+password + magic link only today. The other four all offer SSO
(often enterprise-tier), and 2FA is table stakes for many buyers.

## 5. Granular RBAC — [#332](https://github.com/The-Verscienta/kiln_cms/issues/332) `P1`

- [ ] Move beyond the fixed `admin`/`editor`/`viewer` roles toward
      configurable, per-collection (and ideally per-field) permissions.
- [ ] Consider an admin UI for building roles/policies (Ash policies are
      code-only today).

**Why:** Directus's fine-grained permission matrix is a headline feature;
Craft and Payload also allow more granular, configurable permissions.
**Note:** The `audiences` read-axis already covers consumer-facing tiers — this
is about *authoring* permissions.

## 6. Visual editing experience — [#335](https://github.com/The-Verscienta/kiln_cms/issues/335) `P2`

- [x] Drag-and-drop block reorder + block palette — already shipped across the
      admin block editor (#29/#171) and the in-context on-page editor (#367).
- [x] **Nested layout composition** — the one genuine gap. A first-party
      `columns` container block ([`KilnCMS.Blocks.Columns`](../lib/kiln_cms/blocks/columns.ex))
      nests child blocks (flat list → shallow tree) with per-column drag-and-drop
      in the admin editor. See [nested layout columns](extending-content.md#6-nested-layout-columns-335).
- [ ] Palette **drag-to-place** (drag a block *type* onto a position) — a small
      UX add on top; deferred.
- [ ] Improve live preview to match Craft's / Payload's polish.

**Why:** Marketing/editorial teams often want visual layout and high-fidelity
live preview. Kiln's block editor is functional but not a WYSIWYG canvas.
**Note:** AGENTS.md explicitly declines to pull in Beacon — any solution should
be first-party.

## 7. Multi-tenancy / multi-site — [#336](https://github.com/The-Verscienta/kiln_cms/issues/336) `P2`

- [ ] Evaluate per-tenant or multi-site data isolation (one deployment serving
      multiple sites/tenants).

**Why:** Craft's multi-site is a marquee feature; Directus and Strapi handle
multiple projects more naturally. Kiln is one-deployment-per-project today
(compile-time domains merged via `:content_domains`).

---

## Related items (already strong — not gaps, listed for context)

These were Kiln *advantages* in the comparison and are tracked elsewhere; no
action needed:

- BEAM-native real-time (PubSub, subscriptions, CRDT collab)
- Deep security posture (Ash policies, SSRF-safe webhooks, audits)
- Built-in semantic/hybrid search (pgvector + Bumblebee + reranking)
- Built-in send-only MTA with DKIM
- First-class MCP/LLM authoring endpoint
- Firing engine (immutable multi-surface artifacts + dependency graph)

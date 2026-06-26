#!/usr/bin/env bash
# Creates GitHub issues from KilnCMS_Project_Plan.md remaining work.
#
# Idempotent: re-running skips issues whose title already exists (any state),
# so it is safe to run again after adding new items or after a partial failure.
set -euo pipefail

REPO="The-Verscienta/kiln_cms"
PLAN="KilnCMS_Project_Plan.md"

# GitHub Project board that roadmap issues are tracked on (see KilnCMS_Project_Plan.md).
PROJECT_OWNER="The-Verscienta"
PROJECT_TITLE="KilnCMS Roadmap"
MASTER_ISSUE=67  # tracking epic: "Roadmap: KilnCMS remaining work"

# URLs of issues actually created on this run (skips don't count). Used for the
# closing note about linking them under the master checklist issue.
CREATED_URLS=()

command -v gh >/dev/null 2>&1 || { echo "error: gh CLI not found on PATH" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "error: gh is not authenticated (run 'gh auth login')" >&2; exit 1; }

# `gh project` commands need the 'project' (or 'write:project') OAuth scope, which
# the plain login does not grant. Read the granted scopes off an API response so we
# fail early with an actionable message instead of mid-run under `set -e`.
gh_scopes=$(gh api -i user 2>/dev/null | tr -d '\r' \
  | awk -F': ' 'tolower($1) == "x-oauth-scopes" { print $2 }')
case ",${gh_scopes// /}," in
  *,project,*|*,write:project,*) ;;
  *)
    echo "error: gh token lacks the 'project' scope required for the roadmap board." >&2
    echo "       run: gh auth refresh -s project" >&2
    exit 1
    ;;
esac

# Resolve the project number by title (robust to the board being renumbered or the
# script being pointed at a different owner). Bail out clearly if it is missing.
PROJECT_NUMBER=$(gh project list --owner "$PROJECT_OWNER" --format json \
  --jq "first(.projects[] | select(.title == \"$PROJECT_TITLE\") | .number)")
if [[ -z "${PROJECT_NUMBER:-}" ]]; then
  echo "error: could not find project '$PROJECT_TITLE' for owner '$PROJECT_OWNER'." >&2
  echo "       check 'gh project list --owner $PROJECT_OWNER'." >&2
  exit 1
fi

# Add an issue to the roadmap board. gh dedupes by content, so re-adding an issue
# already on the board is a no-op (verified) — but guard it anyway so a transient
# failure does not abort the whole run under `set -euo pipefail`.
add_to_project() {
  local url="$1"
  if gh project item-add "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --url "$url" >/dev/null 2>&1; then
    echo "  added to project #$PROJECT_NUMBER: $url"
  else
    echo "  warn: failed to add to project #$PROJECT_NUMBER (add manually): $url" >&2
  fi
}

# Ensure the custom roadmap labels exist before creating issues. --force is an
# upsert, so this is safe to re-run and self-documents the labels the issues use.
ensure_label() {
  gh label create "$1" --repo "$REPO" --color "$2" --description "KilnCMS roadmap" --force >/dev/null
}
for n in 0 1 2 3 4 5 6 7 8 9; do ensure_label "phase-$n" "0E8A16"; done
ensure_label "stretch" "0E8A16"
ensure_label "roadmap" "0E8A16"
ensure_label "P0" "B60205"
ensure_label "P1" "D93F0B"
ensure_label "P2" "FBCA04"

create() {
  local title="$1"
  local phase="$2"
  local priority="$3"
  local body="$4"

  # Skip if an issue with this exact title already exists (open or closed).
  local existing
  existing=$(gh issue list --repo "$REPO" --state all --search "in:title \"$title\"" \
    --json title --jq "map(select(.title == \"$title\")) | length")
  if [[ "$existing" -gt 0 ]]; then
    echo "skip (exists): $title"
    return 0
  fi

  # Capture the URL on the create path only (skips returned early above), then add
  # the freshly created issue to the roadmap board.
  local url
  url=$(gh issue create \
    --repo "$REPO" \
    --title "$title" \
    --label "$phase,$priority,roadmap,enhancement" \
    --body "$body")
  echo "$url"
  CREATED_URLS+=("$url")
  add_to_project "$url"
}

create "[Phase 0] Custom Tailwind design system (replace DaisyUI scaffolding)" "phase-0" "P0" \
"From \`$PLAN\` Phase 0.

Set up Tailwind with a custom HEEx component library for admin/editor UI — a clean, professional design system. Remove temporary DaisyUI overrides in AshAuthentication scaffolding.

**Acceptance**
- Shared design tokens / component patterns for editor and admin
- No DaisyUI dependency in production UI paths"

create "[Phase 0] Frontend asset strategy (TipTap CDN vs bundle audit)" "phase-0" "P1" \
"From \`$PLAN\` Phase 0.

Audit and document the strategy for editor frontend deps (TipTap, SortableJS, etc.): bundled via esbuild vs CDN. Image/Mogrify and ex_aws are largely wired — confirm remaining gaps.

**Acceptance**
- Documented asset pipeline decisions in repo docs
- Any missing deps added to \`assets/\` with lockfile updates"

create "[Phase 1] AshAdmin actor wiring (dev-only)" "phase-1" "P1" \
"From \`$PLAN\` Phase 1.

Wire the current user as AshAdmin actor in dev so policy-driven admin actions reflect real RBAC during inspection.

**Acceptance**
- AshAdmin respects actor context in development
- Documented in CONTRIBUTING or dev setup notes"

create "[Phase 1] AshAdmin custom content-focused overrides" "phase-1" "P2" \
"From \`$PLAN\` Phase 1.

AshAdmin is wired for CRUD inspection; add tailored overrides for content resources (friendlier field groupings, hide internal attrs).

**Acceptance**
- Page/Post/MediaItem admin views optimized for developers"

create "[Phase 2] Media browser modal/picker in editor" "phase-2" "P1" \
"From \`$PLAN\` Phase 2.

Full media library browser modal usable from the content editor (not only per-block image picker). Browse, search, and insert library assets.

**Acceptance**
- Modal picker reachable from editor chrome and image blocks
- Covered by LiveView tests"

create "[Phase 2] Variant worker: Storage.fetch + PubSub library refresh" "phase-2" "P1" \
"From \`$PLAN\` Phase 2 follow-up.

Multi-node variant generation should fetch originals via \`Storage.fetch/1\` instead of local temp hand-off. Media library should live-refresh when variant processing completes (PubSub).

**Acceptance**
- \`VariantWorker\` works without local temp files on all nodes
- \`MediaLive\` updates when processing finishes"

create "[Phase 3] PubSub-decoupled preview (full D1 architecture)" "phase-3" "P1" \
"From \`$PLAN\` Phase 3.

Side-by-side preview exists; complete the D1 architecture: pop-out preview window and/or signed iframe targeting public-site fidelity. Extend Presence for collaboration indicators.

**Acceptance**
- \`PreviewLive\` / signed preview URL usable in separate window
- Editor↔preview sync via native PubSub
- Tests for broadcast + render path"

create "[Phase 3] Block inserter slash menu" "phase-3" "P1" \
"From \`$PLAN\` Phase 3.

Richer block library / inserter UI beyond per-type buttons — Notion-style slash command menu for inserting blocks.

**Acceptance**
- Slash menu inserts all registered block types
- Keyboard accessible"

create "[Phase 3] TipTap extensions: toolbar, shortcuts, slash commands" "phase-3" "P1" \
"From \`$PLAN\` Phase 3.

Expand TipTap beyond the basic toolbar: formatting shortcuts, slash commands inside rich_text blocks, additional StarterKit extensions as needed.

**Acceptance**
- Documented keyboard shortcuts
- Slash commands for common block transforms"

create "[Phase 4] Coalesce autosave PaperTrail versions" "phase-4" "P2" \
"From \`$PLAN\` Phase 4 follow-up.

Draft autosave currently writes a PaperTrail version per debounced save. Coalesce or tag autosave versions to reduce history noise.

**Acceptance**
- Autosave does not flood version history
- Manual saves still versioned distinctly"

create "[Phase 5] AshJsonApi filtering and pagination tuning" "phase-5" "P1" \
"From \`$PLAN\` Phase 5.

JSON:API is exposed at \`/api/json\`; tune filtering, sorting, and pagination defaults for headless consumers.

**Acceptance**
- Documented query params for Page/Post/Media
- Tests for common filter combinations"

create "[Phase 5] AshGraphQL query/mutation surface tuning" "phase-5" "P1" \
"From \`$PLAN\` Phase 5.

GraphQL schema exists at \`/gql\`; refine exposed queries/mutations per resource (D7 — deliberate exposure).

**Acceptance**
- Curated public GraphQL surface documented
- Playground examples for publish content reads"

create "[Phase 5] Webhook updated/unpublished events + per-event UI" "phase-5" "P1" \
"From \`$PLAN\` Phase 5.

Extend outbound webhooks beyond publish: \`*.updated\`, \`*.unpublished\` events. Admin UI to subscribe per event type.

**Acceptance**
- Delivery worker dispatches new events
- WebhookEndpoint UI lists selectable events
- Tests mirror \`webhooks_test.exs\` patterns"

create "[Phase 5] Example frontend consumers (Astro or Phoenix)" "phase-5" "P1" \
"From \`$PLAN\` Phase 5.

Ship reference consumers demonstrating JSON:API or GraphQL consumption (Astro static site or simple Phoenix pages).

**Acceptance**
- Example app in \`/examples\` or documented external repo link
- README walkthrough for headless setup"

create "[Phase 5] API documentation (OpenAPI/Swagger)" "phase-5" "P1" \
"From \`$PLAN\` Phase 5.

Production-ready API docs via ash_json_api OpenAPI or hand-maintained Swagger — authentication, pagination, webhooks.

**Acceptance**
- Published OpenAPI spec reachable in dev/prod
- Covers auth + core content endpoints"

create "[Phase 6] Search highlighting and tsvector optimization" "phase-6" "P2" \
"From \`$PLAN\` Phase 6 follow-up.

Postgres full-text search works with GIN index. Optional: result highlighting; materialized/generated \`tsvector\` column if profiling warrants it.

**Acceptance**
- Highlight snippets in admin search UI (if pursued)
- Migration path documented if tsvector column added"

create "[Phase 6] Meilisearch integration (optional)" "phase-6" "P2" \
"From \`$PLAN\` Phase 6.

Optional typo-tolerant search via Meilisearch + Oban indexing jobs. Docker Compose profile already stubbed.

**Acceptance**
- Feature-flagged Meilisearch backend
- Index rebuild on publish/unpublish"

create "[Phase 6] Cache enriched block media + per-key invalidation" "phase-6" "P1" \
"From \`$PLAN\` Phase 6.

Cachex caches published records; extend to enriched block media on delivery path. Replace full \`bust_published\` clears with per-key invalidation where possible.

**Acceptance**
- Delivery cache hits include resolved media URLs
- Publish/edit busts only affected keys"

create "[Phase 6] Performance profiling and editor Telemetry" "phase-6" "P1" \
"From \`$PLAN\` Phase 6.

Add Telemetry metrics for editor actions; profile hot paths via LiveDashboard extended metrics.

**Acceptance**
- \`:telemetry\` events for save/publish/autosave
- LiveDashboard panel or documented Grafana path"

create "[Phase 6] CDN integration strategy for media" "phase-6" "P1" \
"From \`$PLAN\` Phase 6.

Document and implement CDN-friendly media URLs for S3/MinIO production storage (cache headers, public_base_url, variant URLs).

**Acceptance**
- Deployment guide for CDN in front of object storage
- Config switches for CDN base URL"

create "[Phase 7] Admin/editor UI gettext + public language switcher" "phase-7" "P1" \
"From \`$PLAN\` Phase 7.

Content delivery i18n is done. Remaining: wrap admin/editor templates in Gettext, extract \`.po\` files, public site language switcher, per-locale editor UX for authoring translations.

**Acceptance**
- Gettext coverage for editor chrome
- Locale switcher on public site
- Editor can create/link locale variants"

create "[Phase 7] SEO structured data: author, breadcrumbs, blog index" "phase-7" "P2" \
"From \`$PLAN\` Phase 7 follow-up.

Extend \`StructuredData\`: public author display name, \`BreadcrumbList\`, \`CollectionPage\` for \`/blog\`.

**Acceptance**
- JSON-LD includes author when configured
- Blog index emits CollectionPage"

create "[Phase 7] Analytics time-series and telemetry events" "phase-7" "P2" \
"From \`$PLAN\` Phase 7 follow-up.

ContentView counter is totals-only. Add time-series storage or charts in \`AnalyticsLive\`; emit telemetry for external sinks.

**Acceptance**
- Dashboard shows trends (7d/30d)
- \`:telemetry\` event on view increment"

create "[Phase 7] Workflow notification prefs and return-to-draft emails" "phase-7" "P2" \
"From \`$PLAN\` Phase 7 follow-up.

Email notifications exist for submit/publish. Add returned-to-draft / changes-requested events and per-user notification preferences.

**Acceptance**
- Author notified on \`return_to_draft\`
- User-level opt-in/out settings (minimal v1)"

create "[Phase 7] Accessibility audit (admin UI)" "phase-7" "P1" \
"From \`$PLAN\` Phase 7.

Audit editor and admin UI for WCAG 2.1 AA: focus order, labels, contrast, keyboard paths.

**Acceptance**
- Documented audit findings + prioritized fixes
- Critical issues resolved in editor flows"

create "[Phase 7] Theming and white-label potential" "phase-7" "P2" \
"From \`$PLAN\` Phase 7.

Support configurable branding (logo, colors, site name) for agency white-label deployments.

**Acceptance**
- Runtime or compile-time theme config
- Public + editor surfaces respect brand tokens"

create "[Phase 8] Expand Ash resource/policy/action test coverage" "phase-8" "P0" \
"From \`$PLAN\` Phase 8.

~285 tests exist; continue comprehensive ExUnit coverage for all resources, policies, and domain code interfaces.

**Acceptance**
- Policy matrix documented per resource
- Gaps in \`can_*?\` helpers covered"

create "[Phase 8] E2E tests for editor UX (Wallaby or Playwright)" "phase-8" "P0" \
"From \`$PLAN\` Phase 8.

LiveView tests cover server events; add browser E2E for TipTap, Sortable, and critical editor journeys.

**Acceptance**
- CI job runs headless browser suite
- Covers create → edit blocks → publish loop"

create "[Phase 8] Security hardening: dependency audit + policy gaps" "phase-8" "P0" \
"From \`$PLAN\` Phase 8.

Sobelow, CSP, and rate-limit tests exist. Add dependency audit automation and close remaining policy coverage gaps.

**Acceptance**
- \`mix deps.audit\` or equivalent in CI
- Documented threat model for public APIs"

create "[Phase 8] CI migration-drift check" "phase-8" "P0" \
"From \`$PLAN\` Phase 8.

GitHub Actions runs tests and static analysis; add explicit Ash migration drift detection on PRs.

**Acceptance**
- CI fails when resource snapshots diverge from DB
- Documented in CONTRIBUTING"

create "[Phase 8] ExDoc documentation and guides" "phase-8" "P1" \
"From \`$PLAN\` Phase 8.

Full ExDoc plus human guides: modeling, editor usage, API consumption, deployment.

**Acceptance**
- \`/docs\` or ExDoc hosted guides
- Onboarding path for new contributors"

create "[Phase 9] Coolify service configuration" "phase-9" "P0" \
"From \`$PLAN\` Phase 9.

Production Dockerfile exists; configure Coolify service (env vars, volumes, healthchecks, auto-deploy from Git).

**Acceptance**
- Coolify deploy recipe checked into repo or runbook
- Staging environment documented"

create "[Phase 9] Database migrations in release" "phase-9" "P0" \
"From \`$PLAN\` Phase 9.

Ensure \`mix release\` runs Ash migrations on boot or via release task.

**Acceptance**
- Documented migration command for Coolify/Fly
- Tested in Docker production image"

create "[Phase 9] Monitoring and alerting" "phase-9" "P0" \
"From \`$PLAN\` Phase 9.

Prometheus + Grafana or extended LiveDashboard with alerts for BEAM/DB health.

**Acceptance**
- Health + readiness probes documented
- Alert rules for Oban queue depth / DB connectivity"

create "[Phase 9] Backup strategy (Postgres + media)" "phase-9" "P0" \
"From \`$PLAN\` Phase 9.

Automated backups for Postgres and object storage / uploads volume.

**Acceptance**
- Backup schedule documented
- Restore drill runbook"

create "[Phase 9] Domain and SSL via Coolify" "phase-9" "P0" \
"From \`$PLAN\` Phase 9.

Configure production domain, TLS certificates, and \`public_base_url\` for SEO/webhooks.

**Acceptance**
- HTTPS enforced
- \`public_base_url\` matches live domain"

create "[Phase 9] Beta user testing" "phase-9" "P1" \
"From \`$PLAN\` Phase 9.

Internal or friendly agency/clinic beta program for editor feedback before v1.

**Acceptance**
- Beta feedback template
- Issues triaged from beta sessions"

create "[Stretch] AI content generation assistant" "stretch" "P2" \
"From \`$PLAN\` Stretch goals.

Block-level LLM prompts via \`req\` for generation, summarization, SEO suggestions.

**Acceptance**
- Pluggable LLM provider config
- Editor UI for per-block assist"

create "[Stretch] Real-time collaborative editing (CRDT research)" "stretch" "P2" \
"From \`$PLAN\` Stretch goals.

Research Yjs/OT layered on LiveView for true multi-user editing (post-v1; D5).

**Acceptance**
- Spike doc with feasibility + tradeoffs"

create "[Stretch] Advanced content analytics" "stretch" "P2" \
"From \`$PLAN\` Stretch goals.

Beyond privacy-first view counters: funnels, referrers (still privacy-respecting), export.

**Acceptance**
- Design doc for extended analytics domain"

create "[Stretch] Plugin / module system" "stretch" "P2" \
"From \`$PLAN\` Stretch goals.

Behaviours + Ash extensions for custom block types, resources, LiveView hooks, API extensions. Future marketplace/Git discovery.

**Acceptance**
- Registry for blocks and plugins
- Example third-party block package"

create "[Stretch] Verscienta Health content modules" "stretch" "P2" \
"From \`$PLAN\` Stretch goals.

TCM-specific content types and patient resource modules for Verscienta Health.

**Acceptance**
- \`mix kiln.gen.content\` types for health use cases
- Policy model documented"

create "[Stretch] Mobile admin (LiveView Native)" "stretch" "P2" \
"From \`$PLAN\` Stretch goals.

Explore LiveView Native for mobile content moderation / approvals.

**Acceptance**
- Spike or prototype for read/approve flows"

create "[Stretch] Static site generation export" "stretch" "P2" \
"From \`$PLAN\` Stretch goals.

Export published content to static HTML for high-traffic blogs/CDN-only delivery.

**Acceptance**
- Mix task or Oban job emits static artifacts
- Documented deploy to object storage"

echo "Created roadmap issues."

# Editing the master checklist body in place can't be done idempotently without
# risking clobbering manual edits, so leave linking as a clearly-noted manual step.
if [[ ${#CREATED_URLS[@]} -gt 0 ]]; then
  echo
  echo "${#CREATED_URLS[@]} issue(s) created and added to project #$PROJECT_NUMBER."
  echo "Manual step: reference them under master checklist issue #$MASTER_ISSUE:"
  echo "  https://github.com/$REPO/issues/$MASTER_ISSUE"
  for u in "${CREATED_URLS[@]}"; do echo "  - $u"; done
else
  echo "No new issues created; nothing to link under issue #$MASTER_ISSUE."
fi

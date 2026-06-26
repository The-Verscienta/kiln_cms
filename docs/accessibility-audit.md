# Accessibility audit — admin/editor UI

Phase 7 issue #47. A WCAG 2.1 AA review of the editor and admin surfaces
(`/editor/*`), focused on the flows authors use daily: the content list, the
block editor, media, search, taxonomy, and settings. This document records the
findings, their severity, and status; the critical editor-flow issues are fixed
in the same change.

## Method

Static review of the LiveView templates against WCAG 2.1 AA, checking the four
high-frequency failure classes for a LiveView app: (1) form controls without
programmatic labels, (2) icon-only controls without an accessible name,
(3) dynamic regions that don't announce, and (4) keyboard/focus traps. The
underlying component library (`core_components.ex`) already labels inputs and
gives the actions menu an `sr-only` name, so most generated forms are fine — the
gaps are in hand-written LiveView markup.

## Findings

| # | Severity | Surface | Issue | Status |
|---|----------|---------|-------|--------|
| 1 | High | Search palette (`/editor/search`) | Search `<input>` had only a placeholder — no programmatic label (WCAG 1.3.1, 4.1.2) | **Fixed** — `role="search"`, `<label class="sr-only">` + `aria-label` |
| 2 | High | Content list (`/editor`) | Status `<select>` and title `<input>` unlabeled | **Fixed** — `aria-label` on both; `role="search"` on the search form |
| 3 | High | Content list | Per-row select checkbox had no accessible name (just "checkbox" to a screen reader) | **Fixed** — `aria-label` naming the row's title |
| 4 | Medium | Search palette / analytics | Result counts and the trend chart didn't announce updates | **Fixed** — `role="status" aria-live="polite"` on the empty-results message; `role="img"` + `aria-label` on the analytics 30-day chart |
| 5 | Medium | Block editor (`/editor/.../:id`) | Drag-to-reorder blocks is pointer-only; needs a keyboard-operable move (move up/down buttons) | **Open** — tracked below |
| 6 | Low | Global | No "skip to main content" link; focus-visible rings rely on browser defaults | **Open** |
| 7 | Low | Color contrast | `text-base-content/50` helper text on `base-100` can fall below 4.5:1 in the light theme | **Open** — re-check tokens during theming (#48) |

## Fixed in this change

Items 1–4 — the critical and announce-related issues in the core authoring
flows — are resolved:

- `search_palette_live.ex`: labelled search input + `role="search"`, and an
  `aria-live` results status.
- `editor_live.ex`: labelled status filter, labelled search (with
  `role="search"`), and per-row select checkboxes named by their content title.
- `analytics_live.ex`: the 30-day trend renders as `role="img"` with a
  descriptive `aria-label` (added with the analytics trend in #45).

## Open follow-ups (prioritized)

1. **Keyboard block reordering** (item 5, Medium) — add move-up/move-down
   controls to each block so reordering doesn't require a pointer. Highest-value
   remaining editor fix.
2. **Skip link + focus-visible** (item 6, Low) — a `Skip to content` link in the
   app layout and an explicit `focus-visible` ring utility on interactive
   elements.
3. **Contrast pass** (item 7, Low) — fold into the theming work (#48): verify
   muted-text tokens meet AA on both themes, and expose accessible defaults.

## Re-test checklist

- Tab through `/editor`: every control reachable and named; filter/search
  operable from the keyboard.
- Screen-reader pass (VoiceOver/NVDA) on the content list: row checkboxes
  announce the content title; bulk-action buttons announce their verb.
- `/editor/search`: the input announces its label; "no results" is announced.
- Run an automated checker (axe DevTools / Lighthouse) on `/editor`,
  `/editor/search`, and a block-editor page; triage any new criticals here.

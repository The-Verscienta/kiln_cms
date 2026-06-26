# Beta user testing: editor UX feedback before v1

This is the Phase 9 "Beta user testing" work (issue #59). The goal of the beta
program is to put the **editor UI** in front of real authors and capture
structured feedback *before* we cut v1 — while changing the editing flows is
still cheap.

We are not testing the headless APIs here (those have their own contract tests
and [`docs/api.md`](api.md)). The beta is about the human-facing editor that
lives under `/editor`: the content list, the block editor, the media browser,
workflow approvals, taxonomy, webhooks, analytics, and settings.

## Program overview

- **Goal:** validate editor UX — discoverability, friction, and missing
  features — across the core authoring flows, and convert what we learn into a
  prioritized, deduplicated issue backlog.
- **Who:** internal team members first, then a small number of *friendly*
  agency / clinic editors (the people who'll actually run KilnCMS day to day).
  Pick non-technical content authors over engineers — they surface the UX gaps.
- **What they touch:** the editor at <http://localhost:4000/editor> (editor or
  admin role required), **not** AshAdmin at `/admin` and **not** the raw APIs.
- **Scope of a beta:** one release candidate at a time. Freeze the editor
  surface for the duration of a beta round so every tester hits the same build.

### Editor surface under test

| Area | Where | What testers exercise |
|---|---|---|
| Content list | `/editor` | browse pages/posts, status + title filter, inline publish/unpublish, bulk actions, trash |
| Block editor | `/editor/:type/:id` | edit the embedded block tree (rich text, heading, image, quote, embed, divider, columns), autosave, save |
| Media browser | `/editor/media` | upload media, browse the library, insert into content |
| Workflow approvals | content list + editor | draft → in_review → published → archived (submit / publish / return / unpublish) |
| Taxonomy | `/editor/taxonomy` | create and assign terms/categories |
| Webhooks | `/editor/webhooks` | register outbound webhooks, inspect deliveries |
| Analytics | `/editor/analytics` | read content/usage analytics |
| Settings | `/editor/settings` | tenant / editor settings |
| Search palette | global | jump-to-content / command palette |

---

## Beta feedback template

Give each tester a copy of the form below (one per session). It is plain
GitHub-flavored markdown — testers can paste it into a comment, a Google Doc, or
straight into a GitHub issue. Keep findings atomic: one row per problem so they
triage cleanly.

```markdown
# KilnCMS beta feedback

## 1. Tester profile
- Name / handle:
- Role (agency editor / clinic editor / internal / other):
- Day-to-day CMS experience (none / some / power user):
- Other CMSes you've used (WordPress, Sanity, Contentful, …):
- Device + browser:
- Build / commit tested:
- Session date:

## 2. Tasks attempted
Mark each: ✅ done unaided · ⚠️ done with hints · ❌ couldn't complete

| Task | Result | Notes |
|---|---|---|
| Create a new page or post | | |
| Edit content in the block editor (add/reorder blocks) | | |
| Publish content (and later unpublish) | | |
| Submit content for review and approve it | | |
| Upload media and insert it into content | | |
| Create a taxonomy term and assign it to content | | |
| Invite / add another user (or set their role) | | |
| Register a webhook | | |
| Read analytics for a piece of content | | |

## 3. Findings (severity-rated)
Severity: **S1** blocker (can't complete the task) · **S2** major (works but
painful / data loss risk) · **S3** minor (annoyance) · **S4** cosmetic / nit.

| # | Area | Severity | What happened | What you expected |
|---|---|---|---|---|
| 1 | | | | |
| 2 | | | | |
| 3 | | | | |

## 4. Usability friction
Where did you hesitate, backtrack, or feel unsure?
- 
- 

## 5. Missing features
What did you reach for that wasn't there?
- 
- 

## 6. Overall rating
- How likely are you to recommend KilnCMS to a peer editor? **0–10:** ____
  (0 = never, 10 = absolutely — NPS-style)
- One thing that worked well:
- One thing that must change before you'd use it for real:
```

---

## Guided task scenarios

Hand testers these scripted walk-throughs. They mirror a real authoring day.
**Don't over-explain** — the point is to see where people get stuck, so keep
instructions goal-level ("publish the post"), not click-by-click, unless the
tester is fully blocked.

### Scenario A — Author and publish a post
1. From `/editor`, create a new **post**.
2. Give it a title and slug, then open the **block editor**.
3. Add a heading block, a rich-text block, and one image block.
4. Reorder the blocks so the image sits between the heading and the text.
5. Let it **autosave**, then hit **Save** explicitly.
6. **Publish** the post from the content list (or the editor).
7. Confirm it now reads `published` in the list, then **unpublish** it.

### Scenario B — Media
1. Open the **media browser** (`/editor/media`).
2. **Upload** an image.
3. Go back into a post and insert that image into an image block.

### Scenario C — Review workflow
1. Create a draft and **submit it for review** (draft → in_review).
2. As an approver, **publish** it (in_review → published)…
3. …or **return** it to draft and note why.

### Scenario D — Taxonomy
1. Open **taxonomy** (`/editor/taxonomy`).
2. Create a term / category.
3. Assign it to an existing page or post.

### Scenario E — Team & integrations
1. Add another **user** (or change a user's role to `editor`).
2. Register a **webhook** for a content event (`/editor/webhooks`).
3. Open **analytics** (`/editor/analytics`) for a published item.

### Scenario F — Find your way around
1. Use the **search palette** to jump to a specific piece of content.
2. Filter the content list by status and by title.
3. Send something to **trash** and confirm you can recover it.

---

## Triage process

Beta feedback is noisy by design. The triage loop turns raw notes into a clean,
prioritized backlog.

### 1. Capture → issue
- Every distinct finding becomes one GitHub issue (or is merged into an existing
  one — see dedup). Don't file omnibus "10 problems" issues.
- Label every beta-sourced issue with **`beta`** plus a severity label:
  **`severity:S1`**, **`severity:S2`**, **`severity:S3`**, or **`severity:S4`**
  matching the template's scale.
- Add an **area** label so we can see clusters: `area:block-editor`,
  `area:media`, `area:workflow`, `area:taxonomy`, `area:webhooks`,
  `area:analytics`, `area:settings`, `area:content-list`.
- Use issue **type** labels you already have: `bug` vs `enhancement`
  (missing-feature requests are `enhancement`).
- Link back to the source: paste the relevant template rows and the tester
  handle + session date into the issue body.

### 2. Dedup
- Before filing, search open issues for the same symptom/area. If it exists,
  add a **+1 / additional reproduction** comment instead of a new issue, and
  bump severity if this tester hit it harder.
- Two testers, same friction = strong signal. Track recurrence in the issue
  (e.g. a checklist of which testers reported it) — recurrence feeds priority.

### 3. Prioritize
Sort the `beta` backlog by this rubric (top wins):

| Priority | Trigger |
|---|---|
| **P0 — now** | Any **S1** blocker on a core flow (create/edit/publish/upload), or data-loss risk |
| **P1 — this milestone** | **S2** on a core flow, **or** any finding reported by ≥2 testers |
| **P2 — before v1** | **S2** on a secondary flow, or a missing feature multiple testers reached for |
| **P3 — backlog** | **S3** annoyances and single-tester nits |
| **Won't fix (yet)** | **S4** cosmetics and out-of-scope requests — label `wontfix`/`later`, but record them |

Weight **frequency** alongside severity: a recurring S3 can outrank a one-off S2
if it blocks everyone's flow.

### 4. Feedback → issue → fix loop
1. **Session** runs; tester fills the template.
2. **Triage** within ~24h: file/dedup, label, prioritize per the rubric.
3. **Fix** P0/P1 against the same beta branch; reference the issue in the PR.
4. **Confirm** with the original tester (or re-run that scenario) that the fix
   lands — close the issue only after the flow actually works.
5. **Roll up** each round into a short summary on issue #59: top themes, NPS
   distribution, what changed. Repeat until the NPS and S1/S2 count clear the
   v1 bar.

---

## Cadence

Keep it lightweight so it actually happens.

- **Session length:** 30–45 min, 1 tester + 1 facilitator. Long enough for
  Scenarios A–C every time; rotate D–F in.
- **Testers per round:** 4–6. That's enough to surface the majority of UX
  issues without drowning triage; usability problems cluster fast.
- **Format:** the facilitator watches (screen-share is fine) and **stays quiet**
  — only steps in once a tester is genuinely stuck, and notes the moment they
  needed help (that hint = a finding).
- **Recording notes:** fill the template *live*. Optionally screen-record the
  session (with consent) so an S1 can be turned into a reproducible issue later.
  Capture the build/commit so fixes can be tied to what was tested.
- **Round length:** ~1 week per round — sessions Mon–Wed, triage + fixes
  Thu–Fri, re-test the worst issues in the next round.

When a round shows no new S1/S2 on the core flows and NPS is trending positive,
the editor is ready for the v1 cut.

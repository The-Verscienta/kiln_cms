# Beta user testing: editor UX feedback before v1

This is the Phase 9 "Beta user testing" work ([#59]). The goal of the beta
program is to put the **editor UI** in front of real authors and capture
structured feedback *before* we cut v1 — while changing the editing flows is
still cheap.

We are not testing the headless APIs here (those have their own contract tests
and [`docs/api.md`](api.md)). The beta is about the human-facing editor that
lives under `/editor`: the content list, the block editor, the media library,
review workflow, taxonomy, releases, and the admin configuration surfaces.

[#59]: https://github.com/The-Verscienta/kiln_cms/issues/59
[form]: https://github.com/The-Verscienta/kiln_cms/issues/new?template=beta_feedback.yml

## Program overview

- **Goal:** validate editor UX — discoverability, friction, and missing
  features — across the core authoring flows, and convert what we learn into a
  prioritized, deduplicated issue backlog.
- **Who:** internal team members first, then a small number of *friendly*
  agency / clinic editors (the people who'll actually run KilnCMS day to day).
  Pick non-technical content authors over engineers — they surface the UX gaps.
- **What they touch:** the editor under `/editor` (plus `/media`), **not** the
  raw APIs. AshAdmin at `/admin` is out of scope and on a staging or production
  build doesn't exist — the scope is compiled in only under `:dev_routes`.
- **Scope of a beta:** one release candidate at a time. Freeze the editor
  surface for the duration of a beta round so every tester hits the same build.

## Set the roles up first — there are two gates, not one

**This is the setup step that most often wastes a session**, because the two
gates fail in different ways and only one of them is visible in the nav.

### Gate 1 — the router decides which *pages* open

The editor surface is split across two `ash_authentication_live_session`s in
`lib/kiln_cms_web/router.ex`:

- `:editor_routes` (`live_editor_required`) — needs the `editor` or `admin` tier.
- `:admin_routes` (`live_admin_required`) — needs `admin`.

Nineteen pages sit behind `:admin_routes`: Trash, Team, Webhooks, Forms,
Funnels, Automation, Governance, Content types, Fields, Branding, Code
injection, Redirects, Slugs, Backups, Mail, Newsletter, Billing, API keys and
System. For a tester on the `editor` tier the sidebar's **Configure** group
collapses to a single **Settings** link — the nav is built from
`KilnCMS.Accounts.Scoping.effective_tier/2` in `KilnCMSWeb.Layouts` — so those
pages read as *missing*. Typing the URL directly is clearer: it bounces to `/`
with "You need admin access to view that page."

### Gate 2 — Ash policy decides which *actions* run

This one has no nav signal at all, and it catches the single most core flow.
Per [`docs/policy-matrix.md`](policy-matrix.md), on `Page`/`Post`/`Entry`:

| Action | admin | editor |
|---|:-:|:-:|
| `create`, `update`, `submit_for_review` | ✅ | ✅ |
| `unpublish`, `archive`, `restore_version` | ✅ | ✅ |
| **`publish`, `publish_scheduled`** | ✅ | ❌ |
| **`return_to_draft`** | ✅ | ❌ |
| `destroy` (soft-delete), `trashed`, `restore` | ✅ | ❌ |

**An editor cannot publish.** Publishing is an admin approval step by design —
editors submit for review. So an authoring round cannot be one person alone at a
keyboard: the draft → in_review → published loop *needs two roles*, which is
exactly the workflow under test.

### Round shapes

| Round type | Tester is | Second seat | Scenarios |
|---|---|---|---|
| **Authoring** (the default — most beta value) | `editor` | facilitator signed in as `admin`, to approve on request | A–D, F |
| **Operator** (setup + integrations) | `admin` | — | A–G |

If a tester on `editor` reports "I couldn't find webhooks" or "the publish
button did nothing", check the gates before filing. If a tester on `admin` hits
it, file it.

### Editor surface under test

Paths verified against `lib/kiln_cms_web/router.ex`. Note `/media`, which is
**not** under `/editor` despite sitting in the editor nav.

| Area | Where | Tier | What testers exercise |
|---|---|---|---|
| Overview | `/editor/overview` | editor | the landing dashboard — what's mine, what's due |
| Content list | `/editor` | editor | browse content, status + title filter, bulk actions, inline unpublish (publish is admin) |
| Block editor | `/editor/content/:type/:id` | editor | edit the block tree (rich text, heading, image, quote, embed, gallery, accordion, columns), links, autosave, save |
| Media library | `/media` | editor | upload media, browse, insert into content, alt text |
| Taxonomy | `/editor/taxonomy` | editor | create terms/tag groups, assign to content |
| Calendar | `/editor/calendar` | editor | see scheduled work and releases on a calendar |
| Releases | `/editor/releases` | editor (shipping is admin) | bundle content into a release; schedule/publish is admin-gated on the page |
| Editorial tasks | `/editor/tasks` | editor | assign and work editorial to-dos |
| Analytics | `/editor/analytics` | editor | read content/usage analytics |
| Broken links | `/editor/links` | editor (opt-in switch is admin) | review dead outbound citations |
| Search palette | `/editor/search` | editor | jump-to-content |
| Settings | `/editor/settings` | editor | personal / site settings |
| Trash | `/editor/trash` | **admin** | recover deleted content |
| Team | `/editor/team` | **admin** | add users, set roles |
| Webhooks | `/editor/webhooks` | **admin** | register outbound webhooks, inspect deliveries |
| Forms | `/editor/forms` | **admin** | build a form, read submissions |
| Content types / Fields | `/editor/types`, `/editor/fields` | **admin** | define a type and custom fields at runtime |
| Automation | `/editor/automation` | **admin** | no-code "when X, do Y" rules |
| Governance | `/editor/governance` | **admin** | audit trail, consent, point-in-time history |
| Branding / Code injection | `/editor/branding`, `/editor/code-injection` | **admin** | white-label the site, inject head/footer HTML |
| Redirects / Slugs | `/editor/redirects`, `/editor/slugs` | **admin** | manage redirects, bulk-regenerate slugs |
| Mail / Newsletter | `/editor/mail`, `/editor/newsletter` | **admin** | delivery settings, campaigns |
| Backups | `/editor/backups` | **admin** | status, back up now, retention |
| API keys | `/editor/api-keys` | **admin** | issue and revoke headless keys — **no sidebar entry**, reachable by URL only |
| Billing / System | `/editor/billing`, `/editor/system` | **admin** | membership providers; which core this instance runs |

Routes behind optional infrastructure — the presentation console
(`/editor/presentation/...`, needs `PRESENTATION_PREVIEW_URL`) and Translations
(shown only when more than one locale is configured) — are out of scope unless
that round is specifically testing them. Confirm they're configured *before* a
session, or drop them from the script.

---

## Beta feedback template

Two ways in, and they carry different weight:

1. **Per-finding issues** — use the [Beta feedback issue form][form]
   (**"Beta feedback"** on the *New issue* chooser). This is the one that
   matters: it lands the finding directly in the backlog with a severity, an
   area, and the build, already labelled `beta`. **One finding per issue.**
2. **Per-session notes** — the form below. The facilitator fills this in live
   during the session, then files an issue per row of §3.

The session form is plain GitHub-flavored markdown — paste it into a doc, or
into a comment on the round's roll-up issue.

```markdown
# KilnCMS beta session notes

## 1. Tester profile
- Name / handle:
- Role (agency editor / clinic editor / internal / other):
- Tier provisioned (editor / admin):
- Day-to-day CMS experience (none / some / power user):
- Other CMSes you've used (WordPress, Sanity, Contentful, …):
- Device + browser:
- Build / commit tested:
- Session date:

## 2. Tasks attempted
Mark each: ✅ done unaided · ⚠️ done with hints · ❌ couldn't complete
"editor+" = the tester drives it but an admin has to approve; note whether the
handoff itself was clear. Leave admin-only rows blank on an authoring round.

| Task | Tier | Result | Notes |
|---|---|---|---|
| Create a new page or post | editor | | |
| Edit content in the block editor (add/reorder blocks, add a link) | editor | | |
| Submit content for review | editor | | |
| Get that content published, and later unpublish it | editor+ | | |
| Upload media and insert it into content | editor | | |
| Create a taxonomy term and assign it to content | editor | | |
| Find a specific item via the search palette | editor | | |
| Bundle content into a release | editor | | |
| Add another user (or set their role) | admin | | |
| Register a webhook | admin | | |
| Delete something and recover it from trash | admin | | |

## 3. Findings (severity-rated)
Severity: **S1** blocker (can't complete the task) · **S2** major (works but
painful / data-loss risk) · **S3** minor (annoyance) · **S4** cosmetic / nit.
File one issue per row.

| # | Area | Severity | What happened | What you expected | Issue |
|---|---|---|---|---|---|
| 1 | | | | | |
| 2 | | | | | |
| 3 | | | | | |

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
instructions goal-level ("get the post published"), not click-by-click, unless
the tester is fully blocked.

Scenarios A–D and F run on the `editor` tier; C needs the admin second seat.
E and G need `admin`.

### Scenario A — Author and submit a post (editor)
1. From `/editor`, create a new **post**.
2. Give it a title and slug, then open the **block editor**.
3. Add a heading block, a rich-text block, and one image block.
4. Reorder the blocks so the image sits between the heading and the text.
5. Add a link inside the rich-text block.
6. Let it **autosave**, then hit **Save** explicitly.
7. **Submit it for review.**
8. Ask for it to be published, then — once it is — **unpublish** it.
   *Steps 7–8 are the handoff; watch whether the tester can tell that publishing
   isn't theirs to do, and whether they can find the state afterwards.*

### Scenario B — Media (editor)
1. Open the **media library** (`/media`).
2. **Upload** an image and give it alt text.
3. Go back into a post and insert that image into an image block.

### Scenario C — Review workflow (editor + admin)
The two-seat scenario. Run it with the tester as author and the facilitator as
approver, in two windows.

1. **Tester:** create a draft and **submit it for review** (draft → in_review).
2. **Facilitator (admin):** **publish** it (in_review → published)…
3. …or **return** it to draft with a reason, and have the tester find out that
   it came back and why.

The interesting failure here is not the state change, it's the *notification*:
does each side learn the ball is in their court without being told out of band?

### Scenario D — Taxonomy and finding things (editor)
1. Open **taxonomy** (`/editor/taxonomy`).
2. Create a term / category and assign it to an existing page or post.
3. Use the **search palette** (`/editor/search`) to jump to a specific item.
4. Filter the content list by status and by title.

### Scenario E — Team & integrations (admin)
1. Add another **user**, or change a user's role to `editor` (`/editor/team`).
2. Register a **webhook** for a content event (`/editor/webhooks`) and inspect a
   delivery.
3. Delete a draft, then recover it from **trash** (`/editor/trash`).

### Scenario F — Plan a release (editor)
1. Open **releases** (`/editor/releases`) and create one.
2. Add two pieces of content to it from the content editor's Settings tab.
3. Look at the **calendar** (`/editor/calendar`) and find the release.
   *Shipping the release is admin-gated — stop here on an authoring round.*

### Scenario G — Configure a site (admin)
The setup a new customer actually does on day one. Rotate two or three of these
in per round rather than running all of them.

1. Define a **content type** with a custom **field** (`/editor/types`,
   `/editor/fields`) and create one record of it.
2. Set **branding** — name, logo, colour (`/editor/branding`).
3. Build a **form** and read a submission (`/editor/forms`).
4. Add an **automation** rule (`/editor/automation`).
5. Issue an **API key** (`/editor/api-keys`) — note that there is no nav link,
   so the tester has to be given the URL. That itself is worth a finding.
6. Check **backups** are running (`/editor/backups`) and read the audit trail in
   **governance** (`/editor/governance`).

---

## Triage process

Beta feedback is noisy by design. The triage loop turns raw notes into a clean,
prioritized backlog.

### 1. Capture → issue
- Every distinct finding becomes one GitHub issue (or is merged into an existing
  one — see dedup). Don't file omnibus "10 problems" issues. The
  **Beta feedback** issue form does this correctly by construction.
- The form applies the **`beta`** label. Severity and area are captured as
  *fields in the issue body*, not labels — this repo deliberately has no
  `severity:*` or `area:*` label taxonomy, and inventing one per round is how
  filters rot. Search `label:beta S1` rather than reaching for a label.
- Add a **type** label during triage: `bug` vs `enhancement`
  (missing-feature requests are `enhancement`). `usability`, `accessibility`,
  `performance` and `privacy` already exist and are worth applying — they're how
  the cross-cutting themes get found later.
- Link back to the source: the form captures tester handle, tier, build and
  session date. Keep them.

### 2. Dedup
- Before filing, search open issues for the same symptom/area. If it exists,
  add a **+1 / additional reproduction** comment instead of a new issue, and
  bump priority if this tester hit it harder.
- Two testers, same friction = strong signal. Track recurrence in the issue
  (e.g. a checklist of which testers reported it) — recurrence feeds priority.
- **Re-check both gates first.** A large share of round-one "missing feature"
  and "button does nothing" reports are the router tier and the publish policy
  above, not a gap. That said, *"I couldn't tell why"* is always a real finding
  even when the block itself is correct — file it as usability.

### 3. Prioritize
Sort the `beta` backlog with this rubric (top wins). The priority labels are the
ones this repo actually has — **`P0`, `P1`, `P2`, and nothing below**:

| Label | Trigger |
|---|---|
| **`P0` — now** | Any **S1** blocker on a core flow (create / edit / submit / upload, and publish for an admin), or data-loss risk |
| **`P1` — this milestone** | **S2** on a core flow, **or** any finding reported by ≥2 testers |
| **`P2` — before v1** | **S2** on a secondary flow, or a missing feature multiple testers reached for |
| *(no priority label)* — backlog | **S3** annoyances and single-tester nits. There is no `P3` label; leaving it unlabelled *is* the backlog state |
| **`wontfix`** | **S4** cosmetics and out-of-scope requests — still record them |

Weight **frequency** alongside severity: a recurring S3 can outrank a one-off S2
if it blocks everyone's flow.

### 4. Feedback → issue → fix loop
1. **Session** runs; the facilitator fills the session notes live.
2. **Triage** within ~24h: file/dedup, label, prioritize per the rubric.
3. **Fix** P0/P1 against the same beta branch; reference the issue in the PR.
4. **Confirm** with the original tester (or re-run that scenario) that the fix
   lands — close the issue only after the flow actually works.
5. **Roll up** each round into a short summary on [#59]: top themes, NPS
   distribution, what changed. Repeat until the NPS and S1/S2 count clear the
   v1 bar.

[#59] stays open until that bar is cleared — it tracks the *program*, not this
document.

---

## Cadence

Keep it lightweight so it actually happens.

- **Session length:** 30–45 min, 1 tester + 1 facilitator. Long enough for
  Scenarios A–C every time; rotate D–G in.
- **Testers per round:** 4–6. That's enough to surface the majority of UX
  issues without drowning triage; usability problems cluster fast.
- **Format:** the facilitator watches (screen-share is fine) and **stays quiet**
  — only steps in once a tester is genuinely stuck, and notes the moment they
  needed help (that hint = a finding). The one exception is the approval handoff
  in Scenarios A and C, where the facilitator has a scripted part to play.
- **Recording notes:** fill the session form *live*. Optionally screen-record
  the session (with consent) so an S1 can be turned into a reproducible issue
  later. Capture the build/commit so fixes can be tied to what was tested.
- **Round length:** ~1 week per round — sessions Mon–Wed, triage + fixes
  Thu–Fri, re-test the worst issues in the next round.

### Before every round

Most of this is one command — `mix kiln.beta.round` does the provisioning,
seeding and readiness reporting below, and is idempotent so you can re-run it
mid-round to add a tester:

```bash
mix kiln.beta.round --yes --shape authoring --testers 4 --round 1
```

It refuses without `--yes`, and refuses a database whose name doesn't look like
a beta/staging one — it mints accounts whose passwords it prints, so run it
from a terminal you'd read a credential in rather than through a deploy
platform's one-off runner. Use `--tester you@example.com` (repeatable) when
testers need real addresses so password reset works, and `--reset-passwords` to
re-issue a lost credential. See `KilnCMS.Beta`.

**An address that already has an account here is adopted, not duplicated** —
its role moves to the seat's tier and the handout says so. That's the right
behaviour for an internal tester who already signs in, but it means an operator
round can hand somebody `:admin`; put the role back when the round ends.

- [x] Pick the round shape (authoring vs operator) and provision testers at the
      right tier — `--shape`. An authoring round gets `editor` testers; an
      operator round is `admin` throughout.
- [x] For an authoring round, have an `admin` seat ready to approve — Scenarios
      A and C stall without one. The task always creates the facilitator seat
      for an authoring round, for exactly this reason.
- [x] Freeze the editor surface; record the commit
      (`git rev-parse --short HEAD`) and hand it to testers. The readiness
      report prints it, and flags a **dirty** working tree — a round frozen
      against uncommitted changes isn't frozen.
- [x] Seed each tester with content they can safely break — an empty CMS tests
      nothing but the empty states. Each tester gets a published post (so the
      edit/unpublish steps have a live record they couldn't have published
      themselves) and a draft page with history (so `restore_version`, one of
      the few workflow actions an editor *may* run, has a target). Skip with
      `--no-seed`.
- [x] Confirm optional infra the script touches is actually up (media storage;
      `PRESENTATION_PREVIEW_URL` only if the round uses the console) — both in
      the readiness report, as warnings rather than failures.
- [ ] Check the `beta` label exists:
      `gh label create beta --color 0E8A16 --description "Sourced from a beta testing session"`
      (GitHub silently drops labels an issue form references but the repo
      doesn't define). The task prints the command; it can't run it, because
      that's a network call to GitHub and the round has no credential for it.

When a round shows no new S1/S2 on the core flows and NPS is trending positive,
the editor is ready for the v1 cut.

Usability Test Plan: Kiln CMS (kilncms.dev)ObjectivesEvaluate how easily first-time visitors can:
Understand what Kiln CMS is and who it is for
Grasp its core value (model once, publish everywhere; self-hosted, Postgres-centric, headless + editor)
Navigate the public site, docs, and API surfaces
Identify next steps (install, try APIs, explore editor concepts)
Form an accurate mental model of the whole system (editor workflow + headless delivery + ops model)
Secondary goals: surface friction in the marketing/docs experience and collect qualitative feedback on clarity, trust, and perceived complexity.Target ParticipantsRecruit 5–8 people total (enough for patterns without overkill):




























PersonaCountBackgroundWhyContent/editorial2–3Writers, marketers, or CMS editors (WordPress, Ghost, Sanity, Contentful experience)Tests “easy to grasp” for non-developersDeveloper2–3Full-stack or frontend engineers familiar with headless CMS (Strapi, Payload, Sanity, GraphQL/JSON:API)Tests API clarity and “whole system” understandingEvaluator / tech lead1–2Someone who evaluates tools for a team (mix of editorial + technical)Tests decision-making clarityScreen for: no prior deep KilnCMS knowledge. Mix of light/dark mode preference and desktop-primary (mobile optional for navigation checks).Test Environment & Setup
Primary: Public site https://kilncms.dev + linked docs and API surfaces.
Optional deeper dive (if you have access): Local install or staging instance for /editor, media library, and workflow. Note that demo.kilncms.dev is documented but currently unavailable.
Tools: Screen recording + audio (Zoom, Lookback, or Maze), think-aloud protocol, post-task SUS-style questions.
Duration: 45–60 minutes moderated session (or unmoderated with task prompts).
Core Tasks (Think-Aloud)Tasks are scenario-based and ordered from high-level understanding → concrete exploration.Task 1 – First impression & value prop (3–5 min)

“You just landed on kilncms.dev. In your own words, what is this product? Who is it for? What makes it different from a typical CMS?”

Success: Accurately captures “self-hosted headless CMS on Elixir/Phoenix/Ash with LiveView block editor + GraphQL/JSON:API” and “control without ops tax.”Task 2 – Find key capabilities (5 min)

“You need to explain the product to a colleague. Locate and describe: (a) the block editor, (b) editorial workflow, (c) headless delivery, (d) media handling, (e) self-hosting requirements.”

Success: Finds all five with minimal hunting; notes any missing visual proof or screenshots.Task 3 – Developer path (8–10 min)

“You want to consume published content from a frontend. Find how to do that, try a simple example if possible (curl or mental walkthrough), and identify the main API surfaces.”

Success: Reaches /developers or headless consumer guide; distinguishes JSON:API, GraphQL, artifacts, search, and auth model (published-only anonymous).Task 4 – Editorial mental model (5–7 min)

“Imagine you are an editor. How would you create a page, review it, and publish it? What roles exist? How do drafts and previews work?”

Success: Correctly infers draft → review → publish, role separation, signed preview tokens, and LiveView editor from the homepage + docs.Task 5 – Next steps & friction (5 min)

“You want to try or install this. What is the path? What concerns do you have?”

Success: Identifies GitHub repo, self-host requirements (Postgres only), or docs entry points; surfaces any perceived barriers (Elixir unfamiliarity, no public editor demo, etc.).Optional Task 6 – Docs navigation (if time)

“Find the guide for migrating from WordPress / comparing to Strapi / using the visual editing bridge.”

Success: Locates relevant docs under /docs without excessive backtracking.MetricsQuantitative
Task success rate (binary or 0–2 scale: fail / partial / success)
Time on task
Number of wrong turns or “I’m lost” moments
System Usability Scale (SUS) score at the end (target ≥ 70 for “acceptable”)
Qualitative
Think-aloud comments (confusion, delight, trust, complexity)
Post-task: “What was easiest? Hardest? Missing?”
Mental model accuracy (ask them to sketch or describe the architecture at the end)
Quotes about clarity of “model once, publish everywhere,” ops model, and editor vs headless split
Protocol Notes
Start with a short warm-up: “Tell me about the last CMS you used.”
Encourage continuous think-aloud: “Say whatever comes to mind, even if it feels obvious.”
Do not help unless the participant is completely stuck for >90 seconds.
After each task, ask one probe: “How confident are you that you did this correctly?”
End with SUS + open questions: “Would you recommend this to a colleague? Why or why not?” and “What would make the whole system feel easier to grasp?”
Analysis & Reporting
Score success and time per task.
Affinity-map friction points and positive moments.
Rank issues by severity (critical = blocks understanding of core value; high = slows evaluation; medium = polish).
Output a short report with:
Overall SUS and success rates
Top 5 friction points with quotes
What worked well
Concrete recommendations (e.g., add annotated screenshots of the editor, clearer “try the APIs live” callouts, a public demo credential path, stronger visual distinction between editor and headless surfaces)

**RESULTS**

finished the public-site test of kilncms.dev, and the biggest problem is that a visitor has no way to try the product. demo.kilncms.dev returns a 503 error, and both main buttons on the homepage say "Sign in to edit", which a new visitor can't use. These scores are my estimates from one walkthrough playing each persona, not data from real participants. I didn't test mobile navigation or the theme toggle.

Estimated SUS scores

Content editor: about 62, below your target of 70
Developer: about 78
Tech lead: about 68
Task scores (0 to 2, in the order editor, developer, tech lead)

First impression: 2, 2, 2. The value prop comes through, but the hero is heavy on jargon for editors.
Finding the five capabilities: 2, 2, 1. System requirements are only reachable through /docs.
Developer path: 2, 2, 2. The public endpoints work live, including /api/json/posts and /gql?query={health}.
Editorial mental model: 1, 2, 1. No single page walks through creating, reviewing and publishing, and none covers roles.
Next steps: 1, 2, 1. There's no install or get-started call to action, and the demo is down.
Docs navigation: 2, 2, 2. The Compare and Migrate section is easy to find.
Top friction points

Critical: The demo returns a 503, yet 
[the demo-mode page](https://kilncms.dev/docs/demo-mode) still points to it, and the main buttons are sign-in only.
High: The top nav only has Blog and Search. There's no Docs, Developers or Get started link, so 
[Getting started](https://kilncms.dev/docs/getting-started) is hard to find.
High: The homepage promises an OpenAPI spec and an API explorer, but /api/openapi returns a 404. The code examples use a <this-site> placeholder and a hello-world slug that doesn't exist.
High: 
[The docs index](https://kilncms.dev/docs) is a flat list of about 75 pages that mixes editor guides with internal pages like "Releasing Kiln". There's no docs search and no entry point for each role.
Medium: There's little visual proof of the workflow, roles or previews, and 
[the blog](https://kilncms.dev/blog) is still placeholder content like the Lorem Ipsum post.
What worked well: The one-line promise is clear and the hero shows the real editor. The "only needs Postgres" message lands. Pages load fast (0.2 to 1.1 seconds), and both error pages are clean. 
[Kiln vs Strapi](https://kilncms.dev/docs/kiln-vs-strapi) and the other comparison pages are honest and fact-checked, and the WordPress migration guide is practical.

Quick wins

Bring the demo back or put a short walkthrough video in its place.
Add Docs, Developers and Get started to the nav, plus a one-line docker run command.
Either turn on a public API explorer or change the homepage wording, and swap <this-site> for the real host.
Split the docs into editor, developer and operator tracks, and add search.
Add a five-minute "editorial workflow" page with annotated screenshots.
The first screenshot is the homepage and the second is the demo's 503 error. When you're ready for the editor and backend, I'll bring up the secure form for the temporary login.

**Editor and Admin Version of Usability Test**
Usability Test Plan: Kiln CMS Editor & AdminObjectivesValidate that non-technical editors and admins can complete core authoring and operational tasks with low friction, high trust, and clear mental models of the workflow. Focus on discoverability, the draft → review → publish handoff, block editor efficiency, and the distinction between editor vs admin capabilities.Key success criteria (aligned with project goals):
A non-technical editor can create a mixed-block page/post and submit it for review in under 5–7 minutes unaided.
Users correctly understand that editors submit for review and admins publish.
Autosave, preview, status badges, and permissions feel reliable and transparent.
Navigation (sidebar, search palette, Configure hub) supports both Essentials and power-user paths.
Participants




























RoleCountProfileNotesEditor4–5Non-technical content authors (agency or in-house). Prefer people who use WordPress, Ghost, Sanity, or Contentful.Primary focus. Avoid heavy engineers.Admin / Operator2–3People who manage teams, settings, or integrations.Can be the same people as editors in a second session, or separate.Facilitator1Knows the product well enough to approve publishes and note blockers.Stays quiet except for scripted handoffs.Sessions: 4–6 testers per round, 30–45 minutes each. One round = one frozen release candidate.Environment
Run against a pinned release image (ghcr.io/the-verscienta/kiln_cms:<tag>) or a clean local/staging instance with assets freshly built.
Provision accounts via mix kiln.beta.round (or manually): one shared or individual editor account + one admin account for the facilitator.
Seed light realistic content (a few pages/posts, some media, one taxonomy term).
Desktop browser (Chrome/Firefox/Safari). Note light/dark mode preference. Mobile/PWA optional for a later round.
Screen share or recording with consent. Facilitator fills the session notes form live.
Core ScenariosUse goal-level instructions only (“get this published,” not click-by-click). Mark each: ✅ unaided, ⚠️ with hints, ❌ failed.Authoring round (editor tier + facilitator as admin)Scenario A — Author and submit (core, always run)
From /editor, create a new post.
Set title and slug, open the block editor.
Add a heading, rich-text block, and image block.
Reorder so the image sits between heading and text.
Add a link in the rich-text block.
Let autosave happen, then explicitly Save.
Submit for review.
(Handoff) Ask facilitator to publish it; then unpublish it.
Watch: Can they tell publishing is not their action? Do status badges and next-step buttons make the state obvious?
Scenario B — Media
Open the media library (/media).
Upload an image and set alt text.
Insert that image into an existing post’s image block.
Scenario C — Review workflow (two seats)
Tester creates a draft and submits for review.
Facilitator (admin) publishes it or returns it to draft with a reason.
Tester discovers the outcome and understands why.
Watch: Notifications, status changes, and clarity of the handoff without out-of-band chat.
Scenario D — Find & organize
Create or assign a taxonomy term.
Use the search palette (⌘K / /editor/search) to jump to a specific item.
Filter the content list by status and title.
Scenario F — Plan a release (editor)
Create a release.
Add two pieces of content to it.
Find the release on the calendar.
(Stop before shipping — admin-gated.)
Operator round (admin tier)Scenario E — Team & recovery
Add or change a user’s role (/editor/team).
Delete a draft and recover it from trash.
(Optional) Register a webhook and inspect a delivery.
Scenario G — Day-one configuration (rotate 2–3 per session)
Define a content type + custom field and create one record.
Set branding (name, logo, color).
Build a simple form and view a submission.
Issue an API key.
Explore the Configure hub and search palette for a settings screen.
MetricsTask level
Success rate (✅ / ⚠️ / ❌)
Time on task (especially Scenario A)
Number of hints required and where they were needed
Errors or wrong paths (especially around publish, permissions, navigation)
Overall
System Usability Scale (SUS) or simple 0–10 “recommend to a peer editor” (NPS-style)
Severity-rated findings:
S1 blocker (cannot complete core task)
S2 major (painful or data-risk)
S3 minor annoyance
S4 cosmetic

Qualitative: hesitation points, trust in autosave/preview, clarity of roles, missing features they reached for
Protocol
Warm-up (2 min): “Tell me about the last CMS you used and what you liked or disliked.”
Explain think-aloud and that the facilitator will stay quiet except for the scripted approval step.
Run scenarios (goal-oriented). Note exact moment of confusion or delight.
After each scenario: “How confident are you that this worked the way you expected?”
End with:
One thing that worked well
One thing that must change before you’d use it for real
Overall recommend score (0–10)

Critical setup notes (from project docs):
Editors cannot publish — this is by design. The handoff itself is under test.
Many admin pages are hidden from the editor sidebar. “I couldn’t find X” may be correct tier behavior; still file it if the reason was unclear.
Use a frozen build so every tester sees identical assets and behavior.
Analysis & Next Steps
Facilitator fills the session notes form live (tester profile, task results, findings table, friction, missing features, rating).
Within 24 hours: file one GitHub issue per distinct finding (use the Beta feedback issue form), deduplicate, rate severity, and prioritize (P0 = any S1 on core flows; P1 = S2 or multi-tester issues).
Re-test fixes with the original tester or in the next round.
Track across rounds: Scenario A times, NPS distribution, and whether the v1 bar is clearing (no open S1s, no open S2s on Scenarios A–G).

**Results**

Major: On Team, you can only add someone whose account already exists. The "invite them via sign-up or SSO first" note is small grey text, and the page has no invite button or sign-up link.
Major (still checking): I couldn't find a Delete or "Move to trash" action on a draft, either in the editor, its Settings tab, or the list row's More actions menu. Bulk-select in the list may be where it lives, but that's still untested. Trash itself works and Restore is clear.
Minor: My own account shows "viewer", "admin · 5 hours left" and "unconfirmed" all at once, which is confusing.
Minor: The custom role form wants free-text type names and raw JSON for field grants. That's fine for a developer but not for an operator.
Minor: Ctrl+K opens a full search page instead of a floating palette.
Cosmetic: The "New" button on the editor home isn't marked up as a button, so screen readers don't treat it as one.

What works well: The Configure hub is well grouped and has a filter box. The inline help text is good, for example "Trash is purged automatically after 30 days". Branding has a live light and dark preview, the webhooks and API key forms are clear, and pages load in 1 to 1.5 seconds.

My estimate is about 74 on SUS and 7 out of 10 on recommend. Creating a content type, changing and restoring the branding, building a form and viewing its submission, issuing and revoking an API key, and search all worked without any hints.

Biggest findings

Major: You can't delete a webhook while it's active, and there's no delete under Edit either. "Delete webhook" only shows up after you click Disable, and that cost me the most time.
Minor: A draft can only be deleted from the bulk bar in the content list, where Delete sits right next to Publish and Archive. The draft's own editor and Settings tab don't have a delete.
Minor: The public form address /forms/<slug> gives a 404. The real page is /forms/<slug>/embed, and the only way to find it is the Preview link in the editor.
Minor: I renamed a form field's machine name to name, but the entry still showed string, so I can't tell whether the edit saved.
Minor: The webhook signing secret is shown in plain text in the list.
Cosmetic: Saving branding or forms doesn't show any "saved" message, so it's hard to know a save worked. When you go from a new content type to its fields, that type isn't pre-selected. The Revoke link on API keys is faint and easy to miss. Ctrl+K opens a full page instead of a pop-up, and it mixes docs results in with settings.
What works well

Creating a content type takes you straight to adding its fields.
Branding has a live light and dark preview.
Webhooks have a Ping button and a delivery log, plus clear warnings on events that include unpublished content.
In search results, settings screens come up first under "Go to".
The Show essentials toggle cuts the sidebar from about 50 links to 9. It also hides Forms, Webhooks, API keys and Trash, which an admin may go looking for.
Cleanup: I deleted the webhook, revoked the key and set the brand color back to #333333. The content type, its record and the test form are still there, and your daily reset will clear them. I'm finishing the last step now, which is deleting the draft and restoring it from trash.


I'll let you know how the delete and restore went. After that, the editor round is next.

Delete and recover worked. When I bulk-deleted the draft, a clear confirmation popped up saying "Move 1 selected item(s) to trash? Admins can restore them from Trash for 30 days." Restoring it from Trash brought it straight back to the content list. One small catch is that Restore gives no "restored" message, so the item just vanishes from Trash. 

**editor round**
I finished the editor round, and there's one blocker. When I reorder blocks, the new order snaps back after the next autosave or Save. Move up, drag, and the "Moved block to position 2 of 3" announcement all look like they worked, but in four tries the order never stuck. So moving the image between the heading and the text fails, and that's a step in Scenario A. My estimate is about 62 on SUS and 6 out of 10 on recommend, and the reorder bug is a big part of that score.

Other findings

Major: In the media alt-text field and the Add block menu, the live re-render drops characters as you type. "Orange square" saved as "Orange squ".
Minor: Every media thumbnail is broken, including the seeded ones, and the draft preview leaves the image out. Images load from media.kilncms.dev, so the problem might be the image host.
Cosmetic: The editor sidebar looks exactly like the admin one, and nothing shows the user's role. You only find out you're an editor when an action is gated.
Cosmetic: An editor can't schedule a release, so a release never shows up on the calendar. That makes step 3 of Scenario F impossible.
Cosmetic: The Inbox is empty and doesn't explain what will appear there after review.
Cosmetic: There are no category seeds to pick from.
Cosmetic: The bulk bar offers Unpublish and Archive to editors. Check whether those should be there.
What worked well

The review handoff is clear. The confirmation says "Sent for review — an admin will publish when ready", the badge reads "In review", and "Awaiting admin approval" replaces the Submit button.
The link popover works, and links persist after a reload.
Alt text carries over from the library into the image block, and the accessibility badge updates.
The signed preview link clearly says anyone can view the draft for 15 minutes.
Filtering the list by status and title works, and pages load in about 0.2 seconds.

Your approval worked. "Editor test post" is published and appears on the 
[public blog](https://kilncms.dev/blog/editor-test-post) with its title, heading, and link, but the image is blank there too.

I couldn't check the editor side because the site now treats [admin@kiln.test](mailto:admin@kiln.test) as a viewer, not an editor. Opening the editor, the Inbox, or the post sends me back to the homepage with a "You need editor access" message. I also didn't see a notifications bell. Did approving the post change that account's role, or did the daily reset? If you set it back to editor, I'll check the post's status and the Inbox.

Two usability notes from this: the "need editor access" toast is easy to miss, and a viewer gets no explanation of where the editor area is.

The editor side of the approval works. In the editor's content list, "Editor test post" now shows a green Published badge. The bell shows 1, and the Inbox has one unread item that reads "Published · 3 minutes · Editor test post" and links to the post. On the post itself, the editor now gets Unpublish and Save draft buttons.

I found three gaps:

Minor: The notification doesn't say who approved the post, so an editor can't tell who handled it.
Cosmetic: The post page has no "approved by" or "published at" note. The only timing anywhere is "Updated 3 minutes ago" in the content list. I didn't open the History tab, so the details might only be there.
Editors can unpublish: An editor sees an Unpublish button on published posts. That's the same issue I flagged in the bulk bar. If editors aren't supposed to unpublish, it needs gating in both places.
The broken image also shows up in the editor's preview, so it's the same image host problem as before. That covers all of Scenario C, so the editor round is finished.
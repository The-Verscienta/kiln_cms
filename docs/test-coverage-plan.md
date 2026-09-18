# Test coverage plan

**Status: living document** — batches 1–9 landed; the floor in
`coveralls.json` is the enforced number, the figures below are the last
measured run.

Where the suite's remaining blind spots are, in the order they are worth
closing, and why each one is on the list. Written against a full measured run on
2026-08-22: **7,344 tests, 0 failures, 83.1% line coverage**, floor 82.5
(`coveralls.json`). Batches 1-9 below have since landed; CI's own Coverage job
measured **85.0%** on `main` on 2026-09-17 (84.6% locally over 8,537 tests),
the floor has moved to **84.5**, and the Playwright suite is at 25 journeys.

Reproduce the numbers with:

    mix coveralls              # total + per-file
    mix kiln.coverage.summary  # one row per source directory

This is not a plan to reach a percentage. The floor exists so coverage cannot
silently fall (see CONTRIBUTING.md), and every item below earns its place by
naming a *behaviour nothing currently proves* — not by the size of its
uncovered block. Nine items are listed as already done so the patterns they
set are reusable; the rest are ordered by what a defect there would cost.

## Ground rule for anything added here

A new test has to fail when the behaviour it names breaks. Before calling an
item done, mutate the line it covers, watch the test go red, revert, and
confirm with `git diff --stat lib/` that nothing of the mutation survived.
Two of the batches below exist *because* the existing tests assert a side
effect was scheduled rather than that it was correct, which is exactly the
failure mode this rule catches.

## Done

### 1. Form mail workers — `test/kiln_cms/forms/mail_workers_test.exs`

`KilnCMS.Forms.NotificationWorker` and `KilnCMS.Forms.AutoresponderWorker`
were 0% covered: `KilnCMS.FormsTest` asserted both jobs were *enqueued* and
stopped there, so nothing ran `perform/1`. What that left unproven was the
part that handles anonymous input — the notification builds its table by
string concatenation and depends entirely on its own `h/1` — plus the
re-fetch gates that make a form deleted or switched off between enqueue and
run send nothing instead of failing a job five times.

15 tests. Both workers now measure 100% (14/14 and 8/8). Deleting the escape
call, dropping the `org_id` scoping, or ignoring the args' `org_id` each turns
the file red.

One thing the file deliberately does *not* claim: the
`args["org_id"] || default_org_id()` fallback is not observable in this build.
Fail-open tenancy lets a nil tenant read globally and find the row by its
unique id anyway; only the strict build (`KILN_STRICT_TEST`, its own smoke
suite) can tell the two apart. The tests pin what *is* observable — that the
arg scopes the read when present, and that a pre-#336 job with no `org_id` is
still delivered.

### 2. Bluesky provider — `test/kiln_cms/social/bluesky_test.exs`

`KilnCMS.Social.Providers.Bluesky` was 10% covered — only `link_facets/2`,
tested in isolation by `KilnCMS.Social.AnnouncerTest`, which drives Mastodon
end to end and never touches this provider's two XRPC calls.

The load-bearing behaviour is the failure classification, and it is not
symmetric with Mastodon's: `createRecord` has no idempotency key, so a repeat
creates a second public post. A 5xx or dropped connection on the *post* must
answer `:unknown`; the same ambiguity on the *session* call is a definite
`:failed`, because a session creates no record. Swapping those two is how one
timeout becomes two posts on an operator's timeline.

16 tests, stubbing both XRPC methods separately through
`Req.Test.stub(KilnCMS.Social, …)` and asserting on the request that was made
*and* the one that was not (`refute_received` — "the post was never attempted"
asserted rather than assumed). 97% (39/40); the one remaining line is a
defensive `web_url/2` clause unreachable through `post/2`.

### 3. `KilnCMSWeb.CodeInjectionLive` — `test/kiln_cms_web/live/code_injection_live_test.exs`

The only test naming `/editor/code-injection` was `KilnCMSWeb.SurfaceTest`,
which classifies routes and mounts nothing, so the console screen that writes
stored XSS into a site had no mount, authorization or save test at all. 18
tests; **0 of 70 lines → 100%** (66 relevant lines once the dead helper below
went with it).

The auth matrix is the half worth reading. An editor who is a *member* of the
site and a signed-in stranger reach `Scoping.effective_tier/2` down different
branches — membership role versus `legacy_tier/2`, which answers `:none` off
the default org — so a test using only the stranger passes with the gate
widened to admit editors. Both are pinned separately; the mutation that admits
`:editor` fails only because of the member case.

Writing the tests turned up dead code rather than a gap: the LiveView's own
`blank_to_nil/1` was the one line left uncovered, and removing it left all 18
tests green — Ash's `:string` cast already trims and refuses the empty string.
It is gone, and the file measures 100%. A helper no test can distinguish from
its own absence is worth deleting rather than covering.

### 4. Calendar drag-reschedule e2e — `e2e/tests/calendar_drag.spec.js`

Five of the six journeys from #1314 landed in #1331; this was the sixth, and
writing it found the feature **broken in production**.

SortableJS resolves its `draggable` selector against the **direct children** of
the list it was created on. `data-reschedulable` was on the chip's `<a>`, a
grandchild of the `<ul>`, so the selector matched nothing, no chip was ever
"chosen", and dragging did nothing at all — silently, because "nothing here is
draggable" is a legitimate state with no error to raise. The identity
attributes moved up to the `<li>` and drag works.

Nothing caught it because the two halves fail differently: the keyboard nudge
walks *up* with `closest`, so it kept working from the `<a>`, and
`calendar_live_test.exs` pushes `reschedule` directly, which exercises the
server and never the hook. The editor's own SortableJS list (block reordering,
covered since #1331) satisfies the direct-child rule, so the working example
sat right next to the broken one.

3 tests: a drag, an arrow-key nudge in both directions, and the absence of a
handle on a lane the server would refuse. All three fail against the old
markup.

Two things this cost, worth knowing before writing the next hook spec:
`page.mouse` sequences do not drive a native HTML5 drag — `locator.dragTo()`
sets up Chromium's drag interception and is the API that works — and the
scheduling field that produces a draggable chip lives in the editor's
**Settings** inspector tab, which is not the tab that opens.

### 5. Billing webhook resolution — `test/kiln_cms/billing/webhooks_test.exs`

`KilnCMS.Billing.Webhooks` was 54%. The controller test drives the receiver end
to end and, in doing so, covered the ladder's top rung — metadata — leaving
the two below it untested. Those exist precisely
because **Stripe sends the same identifier in several shapes**: a subscription
id is the object's own `id` on `customer.subscription.*`, a nested object on an
expanded checkout session, and a bare string on an invoice; a price id lives
under `items`, `lines` or `plan` depending on the event. A fallback that never
runs in a test is the failure mode itself, and the blast radius is somebody's
paid access silently not being granted.

27 tests; **54% → 94%**, and the controller 77% → 82%. Each shape is pinned
separately — dropping any one clause turns the file red — along with the
ladder's *order* (metadata wins over an identifier naming a different
membership), the refusal to guess between two tiers for one customer, and
`org_id/1` preferring the row over the payload's claim.

Two things worth carrying forward:

* **`resolve/1` flattens every failure to `:unresolvable`.** Its `with` only
  matches `{:ignored, _}`, so `:ambiguous_customer` — the deliberate refusal
  to guess — is indistinguishable from "nothing matched" at the call site.
  The log line is where that distinction survives, so the ambiguity tests
  assert there.
* **Malformed ids must ignore, not raise.** A non-UUID `membership_id`, a
  non-UUID `org_id` and a non-string subscription id all make Ash answer
  `{:error, _}`; each has to become an ignore, because a 500 makes the provider
  retry for days and then disable the endpoint.

Two branches are left uncovered on purpose, and the test file says why rather
than faking a test for either. `verify/3`'s **org** mismatch: the read above it
is tenant-filtered by the very `org_id` being compared, so a row found under org
A can never carry org B. Not dead code — the rungs below it are `multitenancy
:bypass` and it goes live the moment that read follows. And
`by_subscription/1`'s `{:error, _}` arm, which only answers a database fault now
that every `subscription_id/1` clause guards on `is_binary`.

That guard went on in review, and it is worth recording what it is *not*:
nothing downstream can tell the difference. Ash rejects a non-string at cast
time — no query, no exception — and `resolve/1` flattens both reasons to
`:unresolvable`, so no test distinguishes the guarded clause from the unguarded
one. It buys a truthful reason code and three clauses that agree. The behaviour
that matters — a junk subscription id not consuming an event the customer rung
could still resolve — holds either way and is tested for its own sake.

The controller's remaining 18% is its three "could not record / could not
enqueue → 500" paths, which need fault injection to reach.

### 6. A/V workers — `av_worker_test.exs`, `av_quarantine_test.exs`

`AVWorker` was 51% and `AVStripWorker` 55%, and the reason was one shared
cause rather than two gaps: **every A/V fixture in the suite is a file ffmpeg
cannot read.** It is a hand-written 24-byte ISO-BMFF header — right for the
"no ffprobe" and "could not remux" branches those files were written for, and
useless for anything past them. So the whole success path had never executed:
probe, duration, dimensions, poster extraction, poster storage, and the strip
worker's promote-the-remuxed-copy path.

The fix is a real fixture — a 64x48 one-second `testsrc` clip from ffmpeg
itself, ~3 KB and milliseconds to make — behind the repo's existing `:ffmpeg`
tag, so it skips where the binary is absent exactly like its neighbours.
**51% → 91%** and **55% → 86%**.

What that buys, beyond the number:

* a gated video is measured but gets **no poster** — a still of a members-only
  video must not land in public storage, and the existing test could only
  simulate that by writing the poster by hand;
* re-running the worker does not erase what the first run measured (it has
  `max_attempts: 3`, and the `put_*` clauses omit rather than nil);
* audio gets a duration and no dimensions;
* the strip worker promotes the **stripped** bytes (asserted by comparing
  against the uploaded bytes, not just by "a blob exists"), re-measures
  `byte_size` from the remux, and refuses a remux that outgrew the size cap.

What is left in both is fault injection — storage failing mid-write, a probe
that succeeds while the poster extraction fails — plus two `Logger.error`
arms for a promotion that cannot happen with a working store.

### 7. `KilnCMS.Media.Ingest` — the fetch seam, then its tests

Batch 6 left this out on purpose: everything still uncovered sat behind one
obstacle. `download/1` called `SafeFetch.get/2` with **no `req_options`**, so
the fetch the WordPress importer points at every attachment URL in an uploaded
export — the most content-chosen request the system makes — was the one fetch in
the tree that could not be pointed at a `Req.Test` stub. Every comparable module
already takes one from config (`Webhooks`, `OEmbed`, `Federation`,
`Links.External`, `Storage.S3`, `Social`, `Push`).

`Ingest.req_options/0` follows that shape, plus a `config/test.exs` entry.
`SafeFetch` merges it *after* its own options, so address pinning and redirect
refusal still apply to a stubbed request. **64% (as measured on 2026-09-03) →
74% (107/143).**

The tests pin what Ingest does with each answer rather than re-testing
`SafeFetch`, whose own suite already covers the byte cap and redirect mechanics:
a stored image named after the URL's last segment, percent-decoded, and a
generated name when the URL has no last segment; a non-2xx reported as
`{:http_status, status}` with nothing stored; a transport failure returned
rather than raised; and a `302` pointing at the cloud metadata address producing
exactly one request. Both mutations — dropping the seam, and passing
`max_redirects` — fail the file.

Two things this turned up:

* **Two importer tests were getting their "unreachable image" from the real
  network.** `import_test.exs` let media through in two places and relied on a
  live connection to the fixture's host failing. Both now stub the 404, and
  the stub being configured means a future test that forgets one fails loudly
  ("cannot find mock/stub") instead of dialling out. The reachable case — an
  imported post's image block re-pointed at the stored item — had no test at
  all and now does.
* **The stored image is not the served bytes.** Every image is re-encoded by
  `ImageProcessor.strip_metadata/2` on the way in (#215), so an assertion that
  the blob equals the response body is wrong. The test asserts a real PNG
  landed under the item's key instead.

What is left is fault injection rather than missing seams: the sync A/V strip
branches (no temp space, a timed-out remux), the storage-failure arms that
delete a half-written blob, the logs for a derivation or strip job that failed
to enqueue, and the one-time warning for a missing private storage root.

### 8. `KilnCMS.Storage.S3` — `test/kiln_cms/storage/s3_test.exs`

No seam was needed: `config/test.exs` already routes ExAws through `Req.Test`.
**56% → 55 of 57 lines.** The two left are the `header/2` fallbacks for a
header list that isn't `{name, value}` pairs, which Req never returns.

Every error answer now has a test that pins its *shape*, not just
`{:error, _}`. A store refused by the bucket returns `{:http_error, 403, _}`.
A store whose temp file is gone returns the stat error before any request is
sent. A fetch that gets a 404 returns the 404 rather than an empty body. A
DELETE that gets a 404 means the bucket is gone, and it returns an error, not
`:ok`. Private fetch and delete pass their errors through. A transport failure
is returned, not raised; the test sets `:ex_aws, :retries` to one attempt so
ExAws's backoff doesn't slow the suite.

Ranged reads had no S3 test at all, only Local's. The media download
controller picks 206, 416 or a plain 200 from the returned shape, so the tests
pin each one. The range header covers both `a-b` and `a-`. The served range
comes from `Content-Range`, not from the request. A 416 returns
`:range_not_satisfiable`. A 200 without `Content-Range`, or with an unknown
total (`bytes 0-2/*`), returns `:no_content_range` instead of guessing. The
private variant reads the private bucket.

Multipart (#494) now runs on a file one byte over the 16 MB threshold. The
tests cover the whole happy path: object metadata rides on the initiate call,
the file goes up as four parts summing to the file size, and completion lists
every part's ETag. A part refused mid-upload fails the store with nothing
completed, and a refused initiate sends no parts. Five mutations each fail the
file: a delete error turned into `:ok`, the 416 arm removed, multipart never
chosen, the `a-` range header changed, and a range guessed when
`Content-Range` is missing.

One thing this turned up: **a truncated multipart was never aborted.**
`ExAws.S3.Upload` returns the part error without sending
`AbortMultipartUpload`, so the parts already uploaded stayed on the bucket.
They were invisible to listing and billed until a lifecycle rule cleared them.
The adapter now runs the initiate step itself, so it holds the upload id, and
sends the abort (`DELETE ?uploadId`) when a part or the complete call is
refused. It still returns the original error. The stub answers the abort, and
three tests pin it: a refused part aborts `up-1` and sends no complete, a
refused complete aborts too, and an abort that fails as well still returns the
part's 403 and logs the upload id. The happy path asserts no abort is sent.
Removing the abort fails all three, and so does aborting the wrong upload id.
Returning the abort's error instead of the part's fails the last one. The one
new line without a test is the arm that turns a part upload's task timeout into
an error; before, that timeout crashed the caller and still left the parts
behind.

### 9. `KilnCMS.Portability.CLI` and the three mix tasks it serves

**Done**, in `test/kiln_cms/portability/cli_test.exs` and
`test/mix/tasks/kiln_portability_tasks_test.exs`. **`CLI` 6% → 94%. The three
tasks it serves, from 0%, now sit at 90–92% each.** The lines left are fallback
clauses for shapes the callers never pass.

The module was smaller than this entry first described. It has no
subcommands or exit codes of its own. It holds four functions the
`kiln.import.wordpress`, `kiln.import.content` and `kiln.export.content` tasks
share: `scope!` (who a run acts as), `print_report`, `author_map!` and
`maybe_drain_media`. The tasks hold the argument parsing, so both are covered.

`scope!` is tested for what it refuses. An `--actor` or `--org` that matches
nothing raises, and never falls back to an admin or the default organization.
No admin and no `--actor` raises too. The "Acting as" line names the user the
run is really attributed to. The report tests use a real import of the WXR
fixture, so the text is pinned against the real report shape:

* A dry run's banner is the first and the last line, and its counts use the
  future tense.
* A real run has no banner.
* A re-run counts what was already there as skipped.
* An unmapped author is listed with the `--author-map` hint, and a mapped one
  without it.
* The failure list is capped at 20 lines, but its summary count is the full
  number.

The task tests check each task's switches and each refusal: an export written
with `--out` imports into another organization, and so does a CSV export. A
dry-run import writes nothing. `--drain-media` is accepted (#931). CSV
without exactly one `--type` is refused, and so is a CSV whose type carries
prose. A CSV with an unknown column, an empty CSV, a file that isn't JSON, JSON
with no `records`, a missing file, and a WXR over the 64 MB limit are each
refused with their own message. The WXR test uses a sparse file, since the
size check is a stat. Seven mutations each fail the files, among them an actor
or organization miss falling back, the closing dry-run banner removed, the
list cap moved, and `--drain-media` undeclared again.

One thing this turned up: **`--state` accepted any word that already existed
as an atom.** It went through `String.to_existing_atom/1`. A typo crashed with
a bare `ArgumentError`, but a word that was an atom elsewhere (`--state admin`)
matched nothing and gave an empty export that exited 0. The task now accepts
exactly `draft | in_review | published | archived` and refuses anything else
by name. The default is still published and draft, so content in review is
left out unless named; `docs/content-portability.md` now says so.

## Next

### 10. Console screens

Measured 2026-09-17: `settings_live` (61.7%, 90 uncovered), `experiments_live`
(60.9%, 45), `social_live` (65.7%, 47), `field_definition_live` (86.6%, 33 —
lifted by #1511/#1512). These are large screens where the mount and the happy
path are covered and the branchy event handlers are not. Do not chase the
percentage: for each screen, list the events its template can push, and cover
the ones with a persistence or authorization consequence. The rest is
rendering that a snapshot would pin without proving anything.

**`newsletter_live` is done — `test/kiln_cms_web/live/newsletter_live_test.exs`,
46.2% → 93.1%.** It was the worst of the five, and six of its eight events had
never run; each one writes or deletes a row, and the rows are people's inboxes.
The tests drive the rendered page (`render_submit`/`render_click` on the real
form ids and buttons), so they also pin that the event a button pushes is the
event the module handles.

What they cover: a segment created, refused when blank, and refused on a taken
slug (uniqueness is the database's, so it lands on submit, not on change); a
segment deleted, and a delete of a missing one reported rather than crashing;
a subscriber added as **pending** and counted as such in the heading; confirm
and remove, each with their refusal; the send form end to end, with the
campaign appearing in the history table; only published posts offered; and no
campaign written when no post is chosen.

Two things this turned up. A **forged id** — the shape the buttons push, with
somebody else's uuid — must be refused rather than obeyed; the test names a
subscriber that must survive it. And a **manual re-send is allowed on purpose**:
the `:already_sent` dedupe belongs to the automation identity ({rule, content,
publish revision}), not to a person pressing Send twice. The opposite is the
natural guess, and being wrong about it is two copies in every inbox, so it is
pinned.

Nine mutations fail the file, among them the delete error arm reporting
success, confirm doing nothing, the heading counting everyone, remove taking
the first subscriber rather than the named one, and the post list ignoring
`state` (that last one survived the first pass — the draft-post test exists
because of it).

What is left there is the send-error message helpers (a gated post, a missing
segment, an unfired publish) and the tier-backed segment branch of
`sendable_audiences/1`, which needs a membership tier to reach.

### 11. Mix tasks — 69.5% as a directory (575 uncovered)

It was 51.6% when this list was written; batch 9 covered the three portability
tasks and took the directory to 69.5% (CI, 2026-09-17). What is left:
`kiln.federation` (0/40) and `kiln.audit.checkpoint` (0/46) have never run;
`kiln.update` is 14%, `kiln.toolchain.check` 17%. The number reads worse than
it is — most tasks are thin shells over modules that *are* tested — so the
useful subset is the tasks that make decisions of their own rather than
delegating: argument validation, the dry-run/apply split, and exit codes. A
task whose body is one delegating call needs no test.

## Not gaps — do not chase these

Three things report low and should be left alone:

* **`KilnCMS.CMS.Content` at 8%.** All 133 uncovered lines are inside
  `defmacro __using__`. Macro bodies run at compile time, before `cover`
  attaches; the code they generate is exercised by every content test in the
  suite. `Kiln.Block.Transformer` at 50% is the same artifact.
* **`KilnCMSWeb.AshAdmin.ActorPlug` at 0%.** Dev-only, compiled out under
  `dev_routes: false`.
* **Excluded tags.** `:pg_tools`, `:ffmpeg`/`:no_ffmpeg`, `:qpdf`,
  `:calibration` and `:strict_tenancy` are excluded deliberately and reported
  in the run summary. An excluded test is visible; a conditional `if
  tools_available?` would turn the same machine into a green run that asserted
  nothing.

## Raising the floor

`minimum_coverage` in `coveralls.json` sits just under the last measured
total. After a batch lands, re-measure and raise it to just under the new
number — the floor's job is to stop regression, so leaving it behind a batch
that moved the total gives back exactly what the batch bought. It moved to
**82.7** with batch 3 and to **84.5** after batch 9, measured against CI's
85.0%; `coveralls.json`'s own comment carries the measurement it was set
against, and that comment is the thing to update next time.

Do not let it drift behind again. Batches 8 and 9 both landed with the floor
still at 82.7, so the slack under CI's number had grown to 2.3 points — enough
for several modules to lose their tests without the gate saying a word.

Raise it against **CI's** measured number, not a local one. Which tests run is
host-dependent (`:pg_tools`, `:ffmpeg`/`:no_ffmpeg`, `:qpdf` are excluded where
the binary is missing), so a floor set from a developer machine that happens to
carry every tool can fail on a runner that does not. Keep the margin the
existing floor uses — roughly half a point under the measured total — so
ordinary run-to-run drift does not turn the gate red.

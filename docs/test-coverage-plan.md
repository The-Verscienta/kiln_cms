# Test coverage plan

Where the suite's remaining blind spots are, in the order they are worth
closing, and why each one is on the list. Written against a full measured run
on 2026-08-22: **7,344 tests, 0 failures, 83.1% line coverage**, floor 82.5
(`coveralls.json`). Batches 1-6 below have since landed; the suite now measures
**83.6% locally over 7,493 tests**, the floor has moved to **82.7**, and the
Playwright suite is at 25 journeys.

Reproduce the numbers with:

    mix coveralls              # total + per-file
    mix kiln.coverage.summary  # one row per source directory

This is not a plan to reach a percentage. The floor exists so coverage cannot
silently fall (see CONTRIBUTING.md), and every item below earns its place by
naming a *behaviour nothing currently proves* — not by the size of its
uncovered block. Six items are listed as already done so the patterns they
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

## Next

### 7. `KilnCMS.Media.Ingest` — 64%, and it needs a seam first

Left out of batch 6 deliberately. Its unsafe-URL guard is already well covered
(`store_url/2` refuses loopback, private ranges, link-local and `file://`), and
almost everything still uncovered is behind one obstacle: `download/1` calls
`SafeFetch.get/2` with **no `req_options`**, so there is no way to point it at
a `Req.Test` stub. Every comparable module in the tree takes one from config —
`Webhooks`, `OEmbed`, `Federation`, `Links.External`, `Storage.S3`, `Unsplash`,
`Updates` — so `Ingest` is the anomaly, and the fetch that most deserves a
test is the one that cannot have one. This is the most content-chosen fetch
in the system: the URLs come out of a WXR file someone uploaded.

Adding `req_options: KilnCMS.Media.Ingest.req_options()` and a `config/test.exs`
entry would follow the established convention and unlock the HTTP-status,
too-large, and filename-derivation branches. That is a small lib change, so it
wants its own PR rather than riding along with tests.

### 8. `KilnCMS.Storage.S3` — 56% (25 uncovered)

`config/test.exs` already points it at `Req.Test`, so the Bluesky stub
pattern transfers directly. Cover the error branches: a 403 from a wrong
credential, a 404 on delete, a truncated multipart. Storage failures surface
to editors as lost uploads, and none of these paths has ever run.

### 9. `KilnCMS.Portability.CLI` — 6% (62 uncovered)

The thinnest-covered non-macro module in the tree. `Portability.Export` (80%)
and `Portability.Import` (79%) carry the logic, so this is argument parsing,
output formatting, and exit codes — cheap to cover with a captured-IO test per
subcommand, and worth it because a wrong exit code here breaks somebody's
migration script silently.

### 10. Console screens at 46–65%

`newsletter_live` (46%, 86 uncovered), `settings_live` (57%, 88),
`experiments_live` (60%, 45), `field_definition_live` (64%, 60),
`social_live` (65%, 47). These are large screens where the mount and the happy
path are covered and the branchy event handlers are not. Do not chase the
percentage: for each screen, list the events its template can push, and cover
the ones with a persistence or authorization consequence. The rest is
rendering that a snapshot would pin without proving anything.

### 11. Mix tasks — 51.6% as a directory (587 uncovered)

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
**82.7** with batch 3; `coveralls.json`'s own comment carries the measurement
it was set against, and that comment is the thing to update next time.

Raise it against **CI's** measured number, not a local one. Which tests run is
host-dependent (`:pg_tools`, `:ffmpeg`/`:no_ffmpeg`, `:qpdf` are excluded where
the binary is missing), so a floor set from a developer machine that happens to
carry every tool can fail on a runner that does not. Keep the margin the
existing floor uses — roughly half a point under the measured total — so
ordinary run-to-run drift does not turn the gate red.

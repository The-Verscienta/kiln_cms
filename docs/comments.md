# Block-level editorial discussions

Editors can leave a comment on any block of a piece of content — feedback
during review, anchored to the exact block it's about — resolve or reopen the
discussion once it's addressed, and turn it into a task somebody owns
([#404](https://github.com/The-Verscienta/kiln_cms/issues/404), the last
unbuilt piece of the collaboration epic
[#350](https://github.com/The-Verscienta/kiln_cms/issues/350)).

Everything here is **editorial-only**: comments and tasks are never delivered
to the public site or the headless API.

## Using it

In the content editor, every block carries a **discussion pin** in its chrome,
below its own content. The pin answers "does this block need me?" before you
open anything:

| Pin | Means |
|---|---|
| **Comment** (plain) | nothing has been said about this block |
| **N comments** (amber) | a thread is open here |
| **N comments · Resolved** (grey) | there was a discussion and it's settled |
| a clipboard count | open tasks are anchored to this block |

A block carrying both an open thread and open tasks reads *unresolved*: a task
is work somebody has already accepted, a thread is a decision nobody has made.
The task count still shows beside it.

Clicking the pin opens the block's panel:

- Its open **tasks** first — who owes what, by when.
- The **thread**: every comment after the first is a reply, because there is
  exactly **one** thread per block, not several competing ones.
- **Resolve thread** / **Reopen thread** on the first comment marks or clears
  the whole thread's resolved state.
- A **composer**. Typing `@` opens an autocomplete of your teammates; see
  *Mentions* below for the one rule worth knowing.
- **Create task** / **Link existing** — see *From a discussion to a task*.

`Esc` closes the panel.

Above the block tree, an **N unresolved discussions** chip narrows the tree to
just those blocks. It hides the rest with CSS rather than removing them, so
every block's fields still save while you work through the list.
`?threads=unresolved` opens straight into that view; `?comment=<block_id>`
opens straight onto one block's thread (the same deep link the preview's pins
and the task emails use).

Editor/admin only, like the rest of the content editor. Comments are never
delivered to the public or headless API — they're editorial-only.

## Who else is here

The pin shows stacked initials for any teammate currently focused on that
block, and the open panel shows "… is typing…" while somebody is writing into
it. Both are **advisory** — nothing locks a block, and edits stay
last-write-wins with PaperTrail behind them. Both are also entirely ephemeral:
block focus is one nullable field in the existing `editing:<kind>:<id>`
Presence meta, so a reconnect re-tracks at document level and the browser
re-sends on the next focus, and typing is a transient PubSub message that
expires after three seconds on its own.

Presence rather than a broadcast, deliberately: a `presence_diff` carries
current state, so an editor who opens the document late learns where everyone
already is instead of staying blind until somebody next moves.

## Mentions

Typing `@` in the composer opens a dropdown of org members. **The handle it
offers is always one that will actually resolve.** Two people called Alice both
match `@ali`, so neither is offered as `@alice` — they are offered as
`@alicesmith` and `@alicejones`, the shortest form of each that is unique here.
If two members' names normalise identically, the dropdown says *(won't notify)*
rather than offering a mention that would quietly reach nobody.

That matters because an ambiguous mention notifies nobody by design (see
*Notifications and @mentions* below). Without the dropdown enforcing it, you
would watch yourself address someone and never learn they weren't told.

## From a discussion to a task

The panel's **Create task** turns a thread into accountable work without
leaving the block. The form arrives seeded:

| Field | Seeded from |
|---|---|
| Assignee | the first `@mention` the root comment resolves |
| Note | the root comment's body |
| Due | a week out |
| On publish | the site default (publishing completes open tasks, unless this task opts out) |

The assignee seed goes through the same resolver that decided who was
*emailed* about the comment, so the person told about it is the person offered
the work. An ambiguous mention seeds nobody, for the same reason it notifies
nobody; a mentioned viewer seeds nobody either, since a viewer cannot hold a
task.

**Link existing** re-anchors a task already filed against the whole document
onto this block. Tasks already anchored to a *different* block are not offered
— moving one would silently empty that block's pin.

Resolving a thread does **not** complete its tasks, and completing a task does
not resolve the thread. Discussion done is not work done; they are two toggles
and each sends its own email.

`/editor/tasks` shows which block each task names, links onto its discussion,
and can be filtered by **Anchored to**: everything, block-anchored only, or
whole-document only. The overview counts blocks with unresolved discussions and
open block-anchored tasks.

## When a block is deleted

Nothing cascades. A block's id is a soft reference on both `Comment` and
`Task` — blocks live in a jsonb array, not a table — so deleting a paragraph
leaves its discussion and its tasks intact rather than destroying a record of
why the change was asked for.

They stay visible, too, which is the part that took work:

- the editor renders a **Discussions on removed blocks** section beneath the
  block tree, so the thread can still be read and closed out;
- `/editor/tasks` labels the row **removed block**;
- the assignment email says the block has since been removed.

An orphaned thread that simply stopped rendering would be the worst outcome:
still stored, still counted everywhere, invisible to the one person who could
close it.

## How it works

- **`KilnCMS.CMS.Comment`** is the resource: `content_type` + `content_id`
  (the same soft-polymorphic, FK-less reference `Consent` and `HistoryAnchor`
  use, so it resolves across compiled content types and dynamic `:entry`
  types alike), a `block_id` (the block's own stable id — not FK-checked,
  since blocks live inside a jsonb array, not a table of their own), `body`,
  and `author_id`.
- **One thread per block.** `thread_id` is nil on the comment that starts a
  block's thread and the root's own id on every reply.
  `KilnCMS.CMS.Changes.RouteToBlockThread` sets it automatically on `:add` —
  the caller only ever says "add a comment to this block", never which
  thread, so a client has nothing to get wrong. Resolving is therefore a
  property of the thread: `:resolve`/`:unresolve` only accept the root
  (enforced by `KilnCMS.CMS.Validations.CommentIsThreadRoot`), and a reply
  carries no resolved state of its own.
- **Policy.** Editor/admin only for every action — no audience/public-read
  carve-out, unlike content links: a comment is never part of a delivered
  document.
- **Editor UI.** `KilnCMSWeb.BlockDiscussionComponents.block_discussion/1` —
  the same toggle-button-into-inline-panel shape as the block-level AI assist
  panel (#60), but rendered *outside* every per-type block branch (assist is
  rich_text-only; a comment can land on any block type). It lives in its own
  component module rather than in `ContentEditorLive`, which is the largest
  module in the codebase.

  All of a document's comments and open tasks are loaded **once** on mount and
  grouped per block in memory — two queries for a document, whatever its block
  count, which `KilnCMS.CMS.TaskBlockPerformanceTest` asserts rather than
  assumes. The composer keeps its own unprefixed `phx-change`, the same
  workaround the assist panel uses: this panel sits inside the main content
  `<.form>`, which can't nest another `<form>`, so the Send button reads a
  synced socket assign rather than anything in its own click event. (Unlike
  assist, no `phx-debounce="blur"` — the mention dropdown has to see the `@`
  the moment it is typed.)
- **Block-anchored tasks.** `KilnCMS.CMS.Task` carries an optional `block_id`
  of the same soft kind. `nil` is a task on the whole document, which is what
  every task was before and still the default. `Task.:for_block` and
  `:open_for_content` are the reads; `tasks_content_lookup_index` carries
  `block_id` as its trailing column, so `:for_content` still matches on the
  leading prefix.
- **Live updates.** `Changes.BroadcastComment` and
  `Changes.BroadcastTaskBlock` announce `{:block_thread_changed, block_id}`
  and `{:block_task_changed, block_id}` on `KilnCMS.Collab.topic/2` — the
  topic every editor of the document already subscribes to. Attached to the
  resources' own actions, so a comment added through the API or a task closed
  by `AutoCompleteTasks` on publish moves the counts too. Re-anchoring a task
  announces *both* blocks, so the count leaves one pin and joins the other in
  the same moment. Loss-tolerant by design: a dropped message costs a stale
  count until the next event, never a lost comment.

## Scope & follow-ons

- **Pins in the shared preview** (#802, done). Every block now carries
  `data-block-id` through `render_block/1` and the thin-block shape, so the
  multiplayer preview (#343/#372) marks each block that has an unresolved
  thread with a pin showing the conversation's size. Clicking one lands in the
  editor with that block's thread already open. Pins move live for everyone
  watching — the broadcast hangs off the `Comment` resource's own actions, not
  the editor's event handlers, so a comment added through the API moves them
  too. The thread UI itself deliberately stays in the editor: the preview is
  meant to read like the published page.

  Still open: whether pins should appear on the **external stakeholder token
  preview** (`/preview/:token/live`, #379). Token holders have no account or
  role, so that needs its own decision; today they see no pins.
- **Notifications and @mentions** (#801, done). Adding a comment emails
  everyone already on that block's thread plus the content's author; resolving
  one emails the thread. Nobody is ever emailed about something they did
  themselves — and that means the *actor*, so resolving someone else's thread
  does tell them.

  Writing `@name` in a body notifies that person instead of (not as well as)
  the thread email — being named is the stronger signal, and two emails for one
  comment is how people mute a feature. There is no handle column: a mention
  matches a user's **name** with case and punctuation removed, so `@alicesmith`,
  `@alice-smith` and `@Alice.Smith` all find Alice Smith, and `@alice` does too
  while it is unambiguous. **An ambiguous handle notifies nobody** — two people
  called Alice, and `@alice` reaches neither, because guessing would send
  someone's review feedback to the wrong person.

  Candidates are the org's members plus any user belonging to no org, so a
  mention cannot carry another tenant's content title into an outsider's inbox.

  One switch covers all of it — **Comments** under notification preferences —
  and the email links straight to the thread (`?comment=<block_id>`), the same
  deep link the preview's pins use. Only a short excerpt of the body travels;
  the conversation stays in the editor.
- **Nested (columns child) blocks** carry their own stable ids and so *can*
  be commented on in principle, but nothing in the editor UI currently treats
  a nested block's id as an independently addressable comment target beyond
  what naturally falls out of using its id like any other.
- **A rare, accepted race:** two concurrent first comments on a brand-new
  block could each see none yet and both become thread roots. Not guarded
  against (no partial unique index) — a low-stakes edge case for a
  low-concurrency editorial feature, documented on
  `KilnCMS.CMS.Changes.RouteToBlockThread` rather than engineered around.

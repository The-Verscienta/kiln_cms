# Block-level editorial comments

Editors can leave a comment on any block of a piece of content — feedback
during review, anchored to the exact block it's about — and resolve or reopen
the discussion once it's addressed
([#404](https://github.com/The-Verscienta/kiln_cms/issues/404), the last
unbuilt piece of the collaboration epic
[#350](https://github.com/The-Verscienta/kiln_cms/issues/350)).

## Using it

In the content editor, every block carries a **Comment** control in its
chrome, below its own content. Clicking it opens an inline panel:

- With no comments yet, it reads "Comment" — click it, write something, hit
  **Send**.
- Once a block has comments, the control shows the count (e.g. "3 comments")
  and, if the thread has been marked resolved, a **Resolved** badge.
- Every comment after the first is added to the same panel as a reply — there
  is exactly **one** thread per block, not several competing ones.
- **Resolve thread** / **Reopen thread** on the first comment marks or clears
  the whole thread's resolved state.

Editor/admin only, like the rest of the content editor. Comments are never
delivered to the public or headless API — they're editorial-only.

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
- **Editor UI.** `KilnCMSWeb.ContentEditorLive`'s `comment_panel/1` — the same
  toggle-button-into-inline-panel shape as the block-level AI assist panel
  (#60), but rendered *outside* every per-type block branch (assist is
  rich_text-only; a comment can land on any block type). All of a document's
  comments are loaded once on mount and refreshed after add/resolve/unresolve
  — a document's comment volume is small enough that this beats a query per
  block per render. The new-comment textarea keeps its own unprefixed
  `phx-change`/`phx-debounce="blur"`, the same workaround the assist panel
  uses: this panel sits inside the main content `<.form>`, which can't nest
  another `<form>`, so the Send button reads a synced socket assign rather
  than anything in its own click event.

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

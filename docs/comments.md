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

- **Not delivered anywhere but the editor.** The shared/multiplayer preview
  (#343/#372) renders blocks with no `data-block-id` on the DOM today, so
  there's nothing to anchor a marker to yet — surfacing comment pins there is
  deliberately left for a follow-up rather than folded into this change.
- **No notifications.** Adding or resolving a comment doesn't email anyone.
  The existing workflow-notification machinery
  (`KilnCMS.CMS.Changes.NotifyWorkflowEmail` /
  `KilnCMS.Notifications.dispatch/3`) is the natural place to hook this in
  later; @mentions would be net-new (no generic mention/notification-target
  system exists elsewhere in the codebase).
- **Nested (columns child) blocks** carry their own stable ids and so *can*
  be commented on in principle, but nothing in the editor UI currently treats
  a nested block's id as an independently addressable comment target beyond
  what naturally falls out of using its id like any other.
- **A rare, accepted race:** two concurrent first comments on a brand-new
  block could each see none yet and both become thread roots. Not guarded
  against (no partial unique index) — a low-stakes edge case for a
  low-concurrency editorial feature, documented on
  `KilnCMS.CMS.Changes.RouteToBlockThread` rather than engineered around.

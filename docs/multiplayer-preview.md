# Multiplayer live preview with presence

Two (or more) people can open the **same** live preview of a draft and see each
other in it — a live presence bar of who's watching, plus each other's **cursors**
moving over the page in real time
([#343](https://github.com/The-Verscienta/kiln_cms/issues/343)). An editor and a
stakeholder can review the same draft together, on the same URL — a collaboration
feature even Sanity gates behind enterprise pricing.

## The asymmetry

The CRDT collaborative-editing groundwork and a `Phoenix.Presence` tracker
already exist; shared preview is near-trivial on top. `Phoenix.Presence` handles
join/leave over the cluster, and native `Phoenix.PubSub` carries cursor moves —
no external realtime service, sub-200ms on a LAN.

## Using it

Open a content item's pop-out preview (the **Preview** action in the editor,
`/editor/preview/:kind/:id`). When more than one person has it open:

- **Presence bar** — a coloured avatar per viewer (initial + name on hover) and a
  "N viewing" count, in the draft ribbon. Updates live as people join and leave.
- **Cursors** — every other viewer's pointer is drawn on the preview with their
  name and colour, following their mouse in real time.

Each viewer gets a stable colour (used for both their avatar and their cursor) so
they're easy to track. Editor/admin only, like the rest of the preview.

## How it works

- **Presence.** On the connected mount, `PreviewLive` tracks the viewer on
  `KilnCMSWeb.Presence` under a per-window key carrying their display name and
  colour (`track_preview_viewer/5`), and subscribes to the topic's diffs. A join
  or leave re-renders the presence bar. (This lands on the same presence topic the
  editor already watches to decide whether to build preview payloads, so
  `previews_open?/2` keeps working.)
- **Cursors.** A small `PreviewCursors` JS hook reports the pointer position as
  **fractions (0..1)** of the preview surface, throttled to ~20/sec. The server
  broadcasts it to the other viewers over PubSub (`broadcast_from`, so a viewer
  never renders their own cursor); each co-viewer renders it at the right spot
  regardless of their window size. A viewer's cursor is dropped when they leave
  (mouse-out or disconnect).
- **Privacy.** Viewers are shown by their chosen **display name**, never their
  email (issue #214) — the same rule as the editing presence indicator.

Modules: `KilnCMSWeb.PreviewLive`, `KilnCMSWeb.Presence` (the
`track_preview_viewer` / `preview_viewers` / `preview_cursor_topic` additions),
and the `PreviewCursors` hook in `assets/js/app.js`.

## Verification

Verified with `Phoenix.LiveViewTest` + Presence assertions (the pop-out's
LiveView socket isn't reliably driveable from the in-app preview browser):
`KilnCMSWeb.PreviewLiveTest` mounts two viewers on the same preview and asserts
they see each other in the presence bar, that one viewer's `render_hook("cursor",
…)` shows up as a positioned cursor on the other's screen (and never on their
own), and that leaving drops both the viewer and their cursor for everyone else.

## Scope & follow-ons

Phase-1 slice:

- **Cursors, not selections.** Live text-selection / caret sharing inside the
  block editor is a bigger, CRDT-adjacent effort; this covers preview cursors.
- **Shared locale switcher** (#378) — the ribbon shows the document's locale;
  when locale siblings exist (same slug, other locales) it becomes a switcher
  that moves **every co-viewer** to the sibling's preview (a `{:preview_switch,
  id}` broadcast on the preview topic → everyone `push_navigate`s together, and
  presence re-forms there). Late joiners follow the shared URL, so the group is
  always on the same variant.
- **Presence on the token preview** (`/preview/:token`, the headless draft
  surface) could reuse the same machinery for external stakeholders without an
  editor account.

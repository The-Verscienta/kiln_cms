# Take content down

<!-- seo-description: How to unpublish or archive a page in Kiln from the
editor, the content list, the calendar or a content release, who may do it,
and what each refusal means. -->

Taking a page off the site needs the same permission as putting it up: an
admin, or an editor on a site where **Team → Publishing** lets editors
publish. **Unpublish** returns a live page to a draft. **Archive** files a
page away, and it needs publish rights even on a draft. Any editor may
**Unarchive**, which brings an archived page back as a draft. Why the rule
covers dates and archive too is in [ADR 0051](decisions/0051-taking-content-down-needs-the-same-approval-as-putting-it-up.md).

The editor, the content list and the calendar offer these controls only to
someone who may use them, and the unpublish date is locked for anyone else.
If you don't see **Unpublish**, or a calendar chip doesn't move, ask an admin.
Deleting is different: it moves a page to the trash, and only an admin can do
it ([Trash and restore](trash.md)).

## Unpublish a page from its editor

1. Open the page from **Content**.
2. Save any changes you made in **Settings** first. Unpublishing does not keep
   unsaved Settings changes.
3. Choose **Unpublish**. On a **Live · draft** page it is under
   **More actions**, the menu next to **Publish changes**.
4. If other records link to the page, Kiln asks you to confirm, because
   readers can no longer follow those links.

The page is now a draft. The editor page has no Archive button: use the
content list.

## Unpublish or archive from the content list

To take down one page, open the **More actions** menu at the end of its row
and choose **Unpublish**. It is offered on published rows. To archive one
page, tick its row and use **Archive** in the bar, as below.

To take down several at once:

1. Tick the rows, or tick **Select all**.
2. Choose **Unpublish** or **Archive** in the bar above the list.
3. Read the prompt, then choose **Unpublish** or **Archive** again to confirm,
   or **Cancel**.

The message afterwards counts the rows updated and the rows skipped. When a
row is skipped, it adds why:
*A row is skipped when it can't take this step: it isn't in a state that allows it, you may not change it on this site, or something on it needs fixing first (open it to see what).*
A draft ticked for Unpublish is skipped because it isn't live. A row you may
not take down on this site is skipped too, and the message doesn't say which
row it was: open a skipped row in the editor to see what stops it.

If someone else moved one of the pages to the trash after the list loaded,
the action currently fails without a message: the list reloads, and the
pages after that one are left as they were. The same happens to a single
row's **Unpublish** (#2781). Tick the remaining pages and try again.

To bring archived pages back, choose **Unarchive** on an archived row, on the
page's editor, or in the bar.

## Take a page down on a date

1. Open the page and go to **Settings**.
2. Set **Scheduled unpublish at**, and save.

When the date passes, the scheduler takes the page back to draft. A page's
expiry action can archive it or only flag it instead
([Content lifecycles](content-lifecycles.md#expiry-one-timestamp-three-outcomes)).

On a live or scheduled page the date is an unpublish, so it is locked for
anyone who may not publish. The field then says
*Unpublishing needs an admin on this site, so an admin sets the unpublish date of a live or scheduled page.*
On a draft nobody has scheduled, any editor may set it. It does nothing until
the page is published.

## Move the date on the calendar

1. Open **Calendar** (`/editor/calendar`).
2. Drag a chip in the **Scheduled unpublish**, **Scheduled archive** or
   **Expired (flagged)** lane to another day, or focus it and use the arrow
   keys. Each moves the page's unpublish date. The time of day stays the
   same.

A chip you may move has a grab cursor, and its tooltip ends with
"arrow keys move it". That is an admin, or an editor on a site where
**Team → Publishing** lets editors publish, and only for content types their
role may edit. For anyone else the chip is a plain link to the page: it
doesn't drag, and the arrow keys don't move it.

The calendar works this out when it loads its dates. If the switch or your
role changes after that, a chip may still offer the drag until the calendar
reloads, and the move is then refused when it is dropped. The refusal
reloads the calendar's dates, so the chip stops offering the drag. The calendar's own
messages are listed under
[Rescheduling from the grid](content-lifecycles.md#rescheduling-from-the-grid).

## Take pages down with a release

1. In the content list, tick the pages and choose **Add to release**. The
   button appears once a release you can still change exists: one that is
   open, scheduled or failed.
2. Pick the release, set **On go-live** to **Unpublish**, and choose
   **Add N item(s)**, where N is how many you ticked. From a page's own
   **Settings**, the **Release** panel does the same for that page: choose
   **Unpublish on go-live**, then **Add to release**.
3. An admin ships the release from its page under **Releases**: set
   **Go live at** and choose **Schedule**, or choose **Publish now**.

Any editor can add an Unpublish item, even on a site where only admins
publish. Only an admin ships a release, whatever **Team → Publishing** says.
Others see *Scheduling and publishing a release need admin access.*
See [Content releases](content-releases.md).

## What a refusal means

If the switch was turned off, or your role changed, after the page loaded,
the button is still there but the click is refused. On the page's editor and
on a row's **Unpublish**, the message says why:

| Message | Why |
|---|---|
| *Only an admin can unpublish content on this site.* | You are an editor, and only admins publish on this site. |
| *You can't edit this content type.* | Your role does not cover this content type ([Granular RBAC](granular-rbac.md)). |
| *You don't have permission to do that.* | Any other refusal. |
| *Someone else changed this item's status first — reload to see where it stands.* | Someone moved the page first. |

The bar keeps offering what it offered when the list loaded. It counts each
refused row as skipped and gives the general reason above, not one of these
messages.

## Where next

- [The editorial workflow](editorial-workflow.md): who may do what.
- [Content lifecycles](content-lifecycles.md): expiry, review dates and the
  calendar.
- [Policy matrix](policy-matrix.md): every permission, resource by resource.

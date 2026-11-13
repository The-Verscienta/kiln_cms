# 0052. A trashed content row refuses every update by default, through a row filter

- **Status** — accepted (2026-11-13), recording the rule #2528 shipped
  (merged 2026-11-09). It is written after the fact, so it argues against the
  code as it is now, which includes the two backfill exemptions #2533 added.
- **References** — [#2332](https://github.com/The-Verscienta/kiln_cms/issues/2332)
  and [#2528](https://github.com/The-Verscienta/kiln_cms/pull/2528), which
  built it; [#2534](https://github.com/The-Verscienta/kiln_cms/issues/2534),
  which asked for this record; #2533 for the backfill exemptions; #2621 for
  `:set_next_occurrence`; [#2530](https://github.com/The-Verscienta/kiln_cms/issues/2530)
  for the overlay opt-out, still open.
- **Changelog** — [1.9.0](../changelog/v1.9.0.md#trashed-row-update-actions-refuse)
  (Changed), with the [Fixed entry](../changelog/v1.9.0.md#trashed-row-updates-refused)
  for the bug.

## The problem

Trashing a page, post or entry is a soft delete. AshArchival stamps
`archived_at`, and its read preparation hides the row from every ordinary
read. It does nothing for update actions. Anything that loaded the record
before the trash still holds the struct, and an update built from that struct
wrote straight into the trashed row: a colleague's autosave, Save, Mark
reviewed, a version restore, a held oEmbed refresh. **Publish changes** on a
trashed live page fired its artifacts again and sent an `updated` webhook
after the `deleted` one, so a page in the trash was back on the site.

## Decision

Every update action on a content resource refuses a trashed row unless it is
named as an exemption. `KilnCMS.CMS.Changes.RefuseTrashed` is registered once,
`on: [:update]`, in the `changes` block that `use KilnCMS.CMS.Content`
generates. It applies to Page, Post, Entry and every dynamic or overlay type,
and to any update action added later. It adds a filter on the row,
`is_nil(archived_at)`, to the `UPDATE` (`Ash.Changeset.filter/2`), the same
compare-and-swap the workflow transitions use for their states. When the row
is trashed, the write matches nothing and raises
`Ash.Error.Changes.StaleRecord`, and nothing after it runs: no artifacts, no
webhook, no job. The editors read that error as "moved to the trash or
deleted". Over the APIs, a write caught in the race answers like any other
compare-and-swap miss, a `409` with code `invalid_state_transition` on
JSON:API and the same code on GraphQL (`KilnCMSWeb.AshStateMachineErrors`).
A row trashed before the request's own read answers not-found, because that
read finds nothing.

## Rejected

- **A validation.** A validation judges the struct the caller holds, which
  was loaded before the trash. That stale read is the race, so a validation
  would pass the very writes this exists to stop.
- **A policy.** It would judge the same held struct. It would also be skipped
  wherever policies are: `authorize?: false` callers and the AshOban bypass,
  which runs the scheduled transitions. And the refusal would be a `403`,
  which tells a client it lacks permission. The row filter gives the answer
  every other lost race gets: the record changed since it was read.
- **A database trigger.** Postgres sees an `UPDATE`, not the Ash action, so a
  trigger cannot tell `:restore` from `:autosave`. It would also be SQL that
  `mix ash.codegen` does not generate, in a repository whose migrations are
  never hand-written.
- **Opt-in per action.** The next update action someone adds would write into
  the trash until somebody remembered. A default that refuses fails safe, and
  an exemption is a decision someone has to write down.

## How an action earns an exemption

An exemption is for a core action that must write trashed rows on purpose.
It is listed in `@exempt` in `KilnCMS.CMS.Changes.RefuseTrashed`, with the
reason in that module's moduledoc, and the exact list is pinned by
`test/kiln_cms/cms/trashed_row_guard_test.exs`, which also checks that every
other update action carries the filter. Today there are four
(`RefuseTrashed.exempt_actions/0`):

- `:restore`, whose purpose is to take a row out of the trash. It carries the
  opposite filter, so a second restore of a held struct is refused.
- `:clear_reference_target`, which a purge runs on every referrer of the
  purged record, trashed ones included, so that a referrer restored later
  does not name a record that no longer exists.
- `:convert_custom_field` and `:resnapshot_media`, the writes behind
  `mix kiln.fields.convert` and `mix kiln.media.resnapshot`. Both walk the
  trash too (#2533), so a row trashed before a contract step and restored
  after it comes back in the new shape.

An exempt write that can fire must not fire a trashed row, and must judge
that on a row nobody can trash in between. `:convert_custom_field` and
`:resnapshot_media` decide on the row their `UPDATE` returned:
`KilnCMS.CMS.Changes.FireArtifacts` with `skip_trashed: true` fires only a row
that is out of the trash. `:clear_reference_target` gates `FireArtifacts` and
`NotifyWebhooks` on the struct instead (`attribute_equals(:archived_at, nil)`),
which is safe only because `KilnCMS.CMS.ContentLinks.TargetDelete` read that
struct inside the purge's transaction.

Writing a trashed row is not a reason on its own. `:set_next_occurrence` is
not exempt: the value it writes is relative to the clock, so it would be
stale again by the time the row was restored. `:restore` recomputes it
instead (#2621).

## Consequences

- **Overlays have no opt-out.** An update action an overlay adds to its own
  content type is refused on a trashed row like any other, and an overlay
  cannot add to `@exempt`. #2530 asks for an explicit opt-out; until then an
  overlay that needs one has to ask.
- **One gap.** A bulk update run with the stream strategy whose changeset
  changes nothing returns the record without consulting the filter, so a
  no-op bulk write on a trashed row is not reported as refused. It writes
  nothing either.
- **The rule covers content only.** Two other resources are soft-deleted with
  AshArchival, and neither carries the change:
  - `KilnCMS.CMS.TypeDefinition` need not. Only admins write it, its
    `:update` writes presentational settings and busts the type registry
    cache, and the registry stops resolving a trashed type. Nothing is fired
    or announced, and a restore brings back the row as last saved.
  - `KilnCMS.CMS.MediaItem` is undecided ([#2891](https://github.com/The-Verscienta/kiln_cms/issues/2891)). The open question is
    its two editor writes, `:update` and `:update_metadata`. In the media
    library, a drawer opened before someone trashed the item still saves
    with `:update`: it reports *Saved details.*, and a changed alt text fires
    the published documents that use the item again
    (`KilnCMS.CMS.Changes.RefireMediaReferrers`). The system writes are a separate matter: the
    media workers load the item through the ordinary read, so whether a
    trashed item is processed at all is decided there, not by a filter on
    their writes.

See [Trash and restore](../trash.md) for what trashing does, and
[the overlay contract](../overlay-contract.md) for what it means for an
overlay's actions.

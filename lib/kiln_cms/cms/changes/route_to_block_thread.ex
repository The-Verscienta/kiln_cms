defmodule KilnCMS.CMS.Changes.RouteToBlockThread do
  @moduledoc """
  Every comment on the same `content_type`/`content_id`/`block_id` belongs to
  **one** thread (#404 — the issue's own wording is "a comment thread anchored
  to a block id", singular). The first comment on a block becomes the thread
  (`thread_id` stays nil); this routes every comment after it to that same
  root, server-side — the caller only ever says "add a comment to this
  block", never which thread, so there is nothing for it to get wrong.

  A `block_id: nil` comment (#946 — an editorial-intelligence reaction's
  finding about the whole document, not one block) gets the same treatment
  one level up: every comment sharing a `content_type`/`content_id` with no
  block groups into its own one document-level thread, via `:for_document`
  instead of `:for_block`.

  Reads the existing comments (`authorize?: false` — routing is not a read
  the caller needs their own grant for) rather than trusting anything from the
  request. Two concurrent first comments on a brand-new block (or document)
  could each see none yet and both become roots — for a human typing, rare
  and low-stakes enough that a partial unique index felt like overkill. #946
  changed the odds: one trigger event can fan out several intelligence
  reactions into the same Oban batch (queue concurrency 10), and any of them
  landing on `deliver_as: "comment"` race for the *same* document-level root
  at effectively the same instant — no longer rare. Closed with a
  transaction-scoped advisory lock (below) rather than a unique index, since
  the routing decision (which existing thread to join) still needs the read;
  a unique index would only turn the lost race into a write failure, not a
  correct route.

  Note this is a document-level (`block_id: nil`) problem specifically — the
  lock below is only taken for that case, leaving the block-level race at the
  same "rare and low-stakes enough to leave alone" posture it always had
  (#1252 review: taking it for every comment cost every human block comment a
  lock round-trip for a race this file already decided not to guard).

  The private `next_sequence/1` in `KilnCMS.Governance.Chain` closes the same
  shape of race (two concurrent writers computing "next"/"root") with a
  UNIQUE index and a
  rescue-and-skip on the loser's insert instead of a lock (#1252 review
  raised the inconsistency). That pattern doesn't transfer directly here: it
  fits an insert that either is or isn't the first of its kind, decided by
  the database at write time; routing a comment needs to READ which existing
  thread to join *before* deciding whether to write a fresh root, and a
  unique index can only reject a write after the (wrong) decision was already
  made. A lock is the more direct fit for a decision that has to see prior
  state before acting, not merely a lighter-weight alternative left on the
  table.

  ## A resolved document-level thread starts fresh (#946)

  A human resolving a block's thread doesn't stop later replies from landing
  on it — nothing here gates that, and re-opening the same conversation on a
  block someone just discussed is the expected shape. Automation's
  `deliver_as: "comment"` reactions have no such intent: nothing tells the
  next rule run "this is a continuation of what got resolved," so an
  unbounded stream of unrelated findings would otherwise all pile onto
  whichever comment happened to be first, staying invisible under a
  "Resolved" badge that no longer means what it says. So for a `block_id:
  nil` comment specifically, an already-resolved root is not reused — the
  new finding starts its own thread instead of reopening the old one.

  Root selection therefore has to consider every past document-level thread,
  not just the first one ever created: it picks the *most recently started*
  `thread_id: nil` comment, so once a resolved root is skipped and a fresh
  one starts, the NEXT finding lands on that fresh one (open) rather than
  re-discovering the older, already-resolved one and starting yet another
  orphan (#1252 review — picking the *oldest* qualifying root here silently
  broke document-level threading after the first resolve).
  """
  use Ash.Resource.Change

  alias KilnCMS.CMS.Comment
  alias KilnCMS.Repo

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &route/1)
  end

  defp route(changeset) do
    content_type = Ash.Changeset.get_attribute(changeset, :content_type)
    content_id = Ash.Changeset.get_attribute(changeset, :content_id)
    block_id = Ash.Changeset.get_attribute(changeset, :block_id)

    # Only the document-level race needs serializing — see the moduledoc.
    if is_nil(block_id), do: lock_thread(changeset.tenant, content_type, content_id)

    existing_comments(content_type, content_id, block_id, changeset.tenant)
    |> case do
      [] ->
        changeset

      comments ->
        # The most recently *started* thread, not the first one this document
        # ever had — comments arrive sorted oldest-first, so the last
        # `thread_id: nil` entry is the newest root. Picking the first one
        # instead (`Enum.find`) permanently re-selects a stale resolved root
        # after the second document-level thread starts, orphaning every
        # comment after it (see the moduledoc's "starts fresh" section).
        root =
          comments |> Enum.filter(&is_nil(&1.thread_id)) |> List.last() ||
            List.first(comments)

        if is_nil(block_id) and not is_nil(root.resolved_at) do
          changeset
        else
          Ash.Changeset.force_change_attribute(changeset, :thread_id, root.id)
        end
    end
  end

  # `before_action` runs inside the create's own transaction, and
  # `pg_advisory_xact_lock` auto-releases at COMMIT/ROLLBACK — no matching
  # unlock to remember. A second concurrent create for the same document
  # blocks here until the first one's insert (and its `thread_id`) commits and
  # becomes visible to this read, instead of both seeing zero comments and
  # both becoming roots.
  #
  # Two independent hashes passed to Postgres's two-key advisory-lock form,
  # rather than one `:erlang.phash2/1` hash passed to the single-bigint form
  # (#1252 review): `phash2/1`'s default range is only 2^27, which a comment
  # here used to describe as "hashed to one bigint, so unrelated... documents
  # never contend with each other" — overstated, since a 27-bit space starts
  # colliding after roughly 11,600 distinct documents. Each key below is
  # computed from a differently-ordered/salted tuple so they don't recompute
  # the same collision, giving a combined space collision-resistant enough in
  # practice that two unrelated documents serializing against each other is
  # no longer a realistic outcome on any deployment's actual document count.
  defp lock_thread(tenant, content_type, content_id) do
    key1 = :erlang.phash2({tenant, content_type, content_id}, 2_147_483_647)
    key2 = :erlang.phash2({:lock2, content_id, content_type, tenant}, 2_147_483_647)
    Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [key1, key2])
    :ok
  end

  defp existing_comments(content_type, content_id, block_id, tenant) do
    Comment.thread_comments!(content_type, content_id, block_id,
      authorize?: false,
      tenant: tenant
    )
  end
end

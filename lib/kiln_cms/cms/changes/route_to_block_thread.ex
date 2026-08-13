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
  """
  use Ash.Resource.Change

  alias KilnCMS.CMS
  alias KilnCMS.Repo

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &route/1)
  end

  defp route(changeset) do
    content_type = Ash.Changeset.get_attribute(changeset, :content_type)
    content_id = Ash.Changeset.get_attribute(changeset, :content_id)
    block_id = Ash.Changeset.get_attribute(changeset, :block_id)

    lock_thread(changeset.tenant, content_type, content_id, block_id)

    existing_comments(content_type, content_id, block_id, changeset.tenant)
    |> case do
      [] ->
        changeset

      comments ->
        root = Enum.find(comments, &is_nil(&1.thread_id)) || List.first(comments)

        if is_nil(block_id) and not is_nil(root.resolved_at) do
          changeset
        else
          Ash.Changeset.force_change_attribute(changeset, :thread_id, root.id)
        end
    end
  end

  # `before_action` runs inside the create's own transaction, and
  # `pg_advisory_xact_lock` auto-releases at COMMIT/ROLLBACK — no matching
  # unlock to remember. A second concurrent create for the same thread key
  # blocks here until the first one's insert (and its `thread_id`) commits and
  # becomes visible to this read, instead of both seeing zero comments and
  # both becoming roots. Keyed on the full tenant/content/block tuple, hashed
  # to one bigint, so unrelated blocks and documents never contend with each
  # other.
  defp lock_thread(tenant, content_type, content_id, block_id) do
    key = :erlang.phash2({tenant, content_type, content_id, block_id})
    Repo.query!("SELECT pg_advisory_xact_lock($1)", [key])
    :ok
  end

  defp existing_comments(content_type, content_id, nil, tenant) do
    CMS.list_comments_for_document!(content_type, content_id,
      authorize?: false,
      tenant: tenant
    )
  end

  defp existing_comments(content_type, content_id, block_id, tenant) do
    CMS.list_comments_for_block!(content_type, content_id, block_id,
      authorize?: false,
      tenant: tenant
    )
  end
end

defmodule KilnCMS.Accounts.AccountRemoval do
  @moduledoc """
  Removing an account, and deciding what happens to what it wrote.

  The two halves of "delete this user" that the console asks about in one step:

    1. **the content** — one of three dispositions, applied across every content
       type on every site the account authored on;
    2. **the account** — `KilnCMS.Accounts.User`'s `:anonymize`, which is what
       account deletion *is* here. See "Why erasure, not DELETE" below.

  ## The three dispositions

    * `:keep` — leave every document exactly as it is. The byline stops naming a
      person (erasure blanks the name and tombstones the email), so published
      work keeps its history and its place in delivery while ceasing to identify
      its author. This is the right answer for a departing colleague, and the
      default.

    * `:archive` — move each document to `:archived` (the workflow transition, so
      a published one is torn out of delivery exactly as unpublishing it would
      be: artifacts purged, published version cleared, the `unpublished` webhook
      fired). Reversible by an editor: `:unarchive` sends it back to draft.

    * `:trash` — soft-delete each document (AshArchival, the same `:destroy` the
       editor's delete button runs). It leaves `/editor/trash`, from which an
       admin can restore it or empty the trash for good. Nothing here ever
       hard-deletes content: `:purge` exists, and deliberately isn't offered —
       "delete the account" must not be a way to silently destroy a site's
       published archive.

  Whichever is chosen, the **version history stays**. Content versions carry the
  acting user as an audit row whose FK nilifies on deletion, and the erasure nulls
  the actor on block-level events (`KilnCMS.History.anonymize_actor/1`); the
  editorial record of what changed survives the person who changed it, which is
  what #219's retention requires.

  ## Why erasure, not DELETE

  There is no hard delete of a user row in Kiln, and this module does not add one.
  Seventeen tables reference `users` as of this writing — content bylines, task
  assignees and creators, comment authors, release creators, media uploaders —
  almost all with no `ON DELETE` clause, so a row delete is a foreign-key error
  rather than a clean removal, and the cascades that would make it succeed are
  precisely the audit trail #219 keeps on purpose.

  So `:anonymize` is the removal: it scrubs the email to a non-routable
  tombstone, blanks the name, destroys the password hash, drops the role to
  `:viewer`, clears audiences, deletes passkeys and IdP links, revokes every
  token, cancels paid memberships locally and drops live sockets. Nothing
  personal remains and nothing can sign in again. What remains is a referenced
  id — and the console says so rather than claiming a delete it didn't do.

  ## Ordering, and what a partial run leaves behind

  Content first, account second. The disposition needs the account's authored
  content to still be attributed, and — more importantly — a failure part-way
  through leaves an account that is *still an account*: recoverable, with its
  content in a mixed state an admin can see and finish. The other order would
  leave a tombstone whose content was never dealt with and whose author is no
  longer nameable.

  Each document is dispatched individually (the workflow transition and the
  soft-delete both carry `after_action` hooks — artifact teardown, cache busting,
  webhooks — so neither is a bulk atomic write), in cursor-paged batches per type
  per org, the same shape `KilnCMSWeb.TrashLive`'s "empty trash" uses. Failures
  are counted, not raised: one document with a stale lock must not abandon the
  other four hundred.
  """

  require Ash.Expr
  require Logger

  alias KilnCMS.Accounts
  alias KilnCMS.CMS.ContentTypes

  @dispositions [:keep, :archive, :trash]

  # Rows per read. Matches the trash sweep's page size — big enough that a
  # prolific author is a handful of queries, small enough to bound memory.
  @page_size 50

  @type disposition :: :keep | :archive | :trash
  @type result :: %{
          disposition: disposition(),
          affected: non_neg_integer(),
          failed: non_neg_integer(),
          unreadable: [String.t()]
        }

  @doc """
  Apply `disposition` to everything `user` authored, then erase the account.

  Returns `{:ok, result}` with the counts, or `{:error, reason}` if the erasure
  itself failed — in which case the content disposition has already been applied
  and the account still exists, which is the recoverable half of the two. A
  document that could not be dispositioned is counted in `:failed` and does not
  stop the erasure: the account is the part a data-subject request is about.

  `actor` must be an admin (the erasure's own policy enforces it).
  """
  @spec remove(struct(), disposition(), keyword()) :: {:ok, result()} | {:error, term()}
  def remove(user, disposition, opts \\ []) when disposition in @dispositions do
    actor = Keyword.fetch!(opts, :actor)

    # Preflight the erasure before touching any content. Some refusals are
    # deterministic — `NotLastAdmin` on the instance's only admin, a policy the
    # actor fails — and applying the disposition first would trash hundreds of
    # documents and then report only the refusal, as if nothing had happened.
    # Building the changeset runs the action's validations and `Ash.can?` runs its
    # policies, without writing anything.
    with :ok <- erasure_allowed(user, actor) do
      %{affected: affected, failed: failed, unreadable: unreadable} =
        dispose_content(user, disposition, actor)

      with {:ok, _erased} <- Accounts.anonymize_user(user, actor: actor) do
        {:ok,
         %{
           disposition: disposition,
           affected: affected,
           failed: failed,
           unreadable: unreadable
         }}
      end
    end
  end

  defp erasure_allowed(user, actor) do
    changeset = Ash.Changeset.for_update(user, :anonymize, %{}, actor: actor)

    cond do
      not changeset.valid? -> {:error, Ash.Error.to_error_class(changeset.errors)}
      not Ash.can?(changeset, actor) -> {:error, Ash.Error.Forbidden.exception([])}
      true -> :ok
    end
  end

  @doc """
  How many documents `user` authored, per content type, across every site —
  what the console shows beside the disposition choice so an admin knows the size
  of what they are about to archive or trash.

  Returns `{type_label, count}` pairs for types with at least one document,
  highest first, summed across sites — an account that wrote on three of them is
  one "Post: 12", because the disposition is not per-site either. The label is
  `ContentTypes`' own `:label`, the same one every picker in the console shows.
  A system read: it spans organizations by design and no single actor's scope
  covers them all.
  """
  @spec authored_counts(struct()) :: %{
          counts: [{String.t(), non_neg_integer()}],
          unreadable: [String.t()]
        }
  def authored_counts(user) do
    results =
      for org_id <- Accounts.list_org_ids(), ct <- ContentTypes.all_for_org(org_id) do
        {ct.label, count_authored(ct, user.id, org_id)}
      end

    counts =
      for({label, {:ok, count}} <- results, do: {label, count})
      |> Enum.reduce(%{}, fn {label, count}, acc ->
        Map.update(acc, label, count, &(&1 + count))
      end)
      |> Enum.reject(fn {_label, count} -> count == 0 end)
      |> Enum.sort_by(fn {label, count} -> {-count, label} end)

    # A type whose count failed is reported as unknown, not as zero: a silent 0
    # on the confirmation screen agrees with a sweep that then skips the type.
    unreadable = for({label, :error} <- results, do: label) |> Enum.uniq() |> Enum.sort()

    %{counts: counts, unreadable: unreadable}
  end

  defp count_authored(ct, user_id, org_id) do
    {:ok,
     ContentTypes.count!(ct.type,
       authorize?: false,
       tenant: org_id,
       query: [filter: Ash.Expr.expr(author_id == ^user_id)]
     )}
  rescue
    # A type whose read fails (a dynamic type mid-migration, a tenant with no
    # table yet) must not 500 the confirmation screen — but it must not read as
    # "nothing here" either.
    error ->
      Logger.warning("authored_counts failed for #{inspect(ct.type)}: #{inspect(error)}")
      :error
  end

  # `:keep` is the absence of work, not a loop over every document doing nothing.
  defp dispose_content(_user, :keep, _actor), do: %{affected: 0, failed: 0, unreadable: []}

  defp dispose_content(user, disposition, actor) do
    # Cross-organization by necessity: the account may have authored on several
    # sites, and each write is re-scoped to its own org (#419). One type's failure
    # is recorded and the sweep continues — a partial disposition an admin is told
    # about beats abandoning the rest.
    {affected, failed, unreadable} =
      Enum.reduce(Accounts.list_org_ids(), {0, 0, []}, fn org_id, totals ->
        Enum.reduce(ContentTypes.all_for_org(org_id), totals, fn ct, acc ->
          dispose_type(ct, user, disposition, actor, org_id, acc, nil)
        end)
      end)

    %{affected: affected, failed: failed, unreadable: unreadable |> Enum.uniq() |> Enum.sort()}
  end

  # One type's documents in @page_size batches, walking oldest-first behind a
  # keyset cursor.
  #
  # A cursor rather than re-reading "everything this author still owns": that
  # filter does not shrink under `:archive` (an archived document still has the
  # same author), so a document the disposition refused would be fetched forever.
  # And a cursor rather than an offset: the `:trash` writes DO remove rows from
  # their own filter, which shifts every later page left past documents that were
  # never looked at.
  #
  # The key is `(inserted_at, id)`, not `inserted_at` alone. A bulk import commits
  # in one transaction, so its documents can share a timestamp to the microsecond,
  # and a bare `inserted_at > cursor` would step over every sibling of the last
  # row in a batch — silently leaving content the admin asked to be dealt with.
  defp dispose_type(ct, user, disposition, actor, org_id, {ok, failed, unreadable}, cursor) do
    case authored_batch(ct, user.id, org_id, cursor) do
      # A failed read is NOT the end of the rows. Treating it as `[]` (shorter
      # than a page, so "done") made a truncated sweep report every document
      # handled and none failed, while the rest stayed published. The type is
      # recorded so the result — and the admin's flash — says it was not finished.
      :error ->
        {ok, failed, [ct.label | unreadable]}

      {:ok, batch} ->
        {ok, failed} =
          Enum.reduce(batch, {ok, failed}, &tally(&1, &2, disposition, ct.type, actor, org_id))

        if length(batch) < @page_size do
          {ok, failed, unreadable}
        else
          last = List.last(batch)

          dispose_type(
            ct,
            user,
            disposition,
            actor,
            org_id,
            {ok, failed, unreadable},
            {last.inserted_at, last.id}
          )
        end
    end
  end

  # One document: apply the disposition and count the outcome. A refused write is
  # logged and counted as failed — never raised, so one stale lock does not
  # abandon the rest of the sweep.
  defp tally(record, {ok, failed}, disposition, type, actor, org_id) do
    case apply_disposition(disposition, type, record, actor, org_id) do
      {:error, error} ->
        Logger.warning(
          "Account removal could not #{disposition} #{type} #{record.id}: #{inspect(error)}"
        )

        {ok, failed + 1}

      _ok ->
        {ok + 1, failed}
    end
  end

  # `authorize?: false`: the caller is already an admin by the time this runs
  # (the console gates on it and `:anonymize` re-checks), and the read spans
  # every org — which no actor's own scope covers. The *writes* below keep the
  # actor, so each one is still authorized and still attributed.
  defp authored_batch(ct, user_id, org_id, cursor) do
    {:ok,
     ContentTypes.list!(ct.type,
       authorize?: false,
       tenant: org_id,
       query: [
         filter: authored_filter(user_id, cursor),
         sort: [inserted_at: :asc, id: :asc],
         limit: @page_size
       ]
     )}
  rescue
    error ->
      Logger.warning("Account removal could not read #{inspect(ct.type)}: #{inspect(error)}")
      :error
  end

  defp authored_filter(user_id, nil), do: Ash.Expr.expr(author_id == ^user_id)

  defp authored_filter(user_id, {at, id}) do
    Ash.Expr.expr(
      author_id == ^user_id and
        (inserted_at > ^at or (inserted_at == ^at and id > ^id))
    )
  end

  # Already-archived documents are skipped rather than counted as failures: the
  # `:archive` transition's `change filter(state != :archived)` refuses them, and
  # "this was already where you asked me to put it" is not an error to report.
  defp apply_disposition(:archive, type, %{state: :archived}, _actor, _org), do: {:ok, type}

  defp apply_disposition(:archive, type, record, actor, org_id),
    do: ContentTypes.transition(type, "archive", record, actor: actor, tenant: org_id)

  defp apply_disposition(:trash, type, record, actor, org_id),
    do: ContentTypes.destroy(type, record, actor: actor, tenant: org_id)
end

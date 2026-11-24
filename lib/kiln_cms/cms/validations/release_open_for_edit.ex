defmodule KilnCMS.CMS.Validations.ReleaseOpenForEdit do
  @moduledoc """
  Refuses to add an item to, change one in, or cancel one out of a release that
  is no longer composing (#500).

  Without this, "add to release" would silently succeed against a release that
  already shipped (the item would sit there `:pending` forever, reserving its
  content against every future release), and cancelling an item mid-go-live
  would race the worker walking that exact row.

  ## Checked under a lock, inside the write (#2740)

  The actions run this with `before_action?: true`, so the release is read
  inside the item write's own transaction, `FOR SHARE`. That lock is what makes
  the check hold until the item commits rather than only at the moment it was
  read. It conflicts with the row lock any UPDATE of the release takes, the
  go-live claim (`ContentRelease`'s `:start` or `:start_scheduled`) among them, and not with another
  `FOR SHARE`, so concurrent adds do not wait on each other. An item write and
  the claim serialize:

    * an item that commits first is in the table before the claim commits, and
      the go-live worker is enqueued in the claim's own transaction, so its
      item read sees it;
    * an item whose check runs after the claim reads `:publishing` and is
      refused.

  An unlocked read used to leave a window between the two: an add that read
  `:open` just before the claim committed inserted a `:pending` item the worker
  never saw, stranded on a `:published` release and holding its content's
  reservation against every other release. `KilnCMS.CMS.Releases` still
  re-checks inside the go-live transaction and fails loudly if one gets
  through anyway.

  ## Adds lock `FOR UPDATE` (#3073)

  `:add` declares this with `lock: :update`; `:cancel` and `:set_action` keep
  the default `lock: :share`. `FOR UPDATE` conflicts with itself, so adds to
  one release take turns, and `KilnCMS.CMS.Validations.ReleaseWithinSizeLimit`,
  which runs after this inside the same transaction, counts the release's
  items with every earlier add committed: the size cap is exact. It also
  conflicts with `FOR SHARE` and with every UPDATE of the release, so the
  #2740 guarantee above holds for adds unchanged.

  The cost: adds to one release wait for each other, each holding the row
  from this check to its commit (one count of at most
  `KilnCMS.CMS.Releases.max_items/0` rows and one insert, typically
  milliseconds). While an add is in flight, a cancel or action change on the
  same release waits for it, as do renaming, scheduling, archiving and
  claiming it (those already waited on `FOR SHARE`). Adds to different
  releases never wait on each other.

  ## Lock order

  Every item write locks its release row first, here, before it touches an
  item row; the add's insert then takes `FOR KEY SHARE` on the same row
  through its foreign key, which its own `FOR UPDATE` already covers. Archive
  updates the release first, then its items. The go-live and rollback workers
  lock items first and the release last, but no item write overlaps them: one
  that starts after the claim reads a claimed state and is refused before it
  writes, and the claim waits for one already holding the lock. So there is
  no cycle, as long as two rules hold for any caller that wraps item writes
  in an outer transaction:

    * never lock two release rows in one transaction;
    * never take `FOR SHARE` and then `FOR UPDATE` on the same release: two
      transactions each holding the share lock would wait on each other's
      upgrade, and Postgres would abort one as a deadlock. That is why
      `ReleaseWithinSizeLimit` never locks the release itself.

  Nothing wraps item writes today: the console's single and bulk adds run
  each `:add` in its own transaction.

  `KilnCMS.CMS.ContentRelease.editable_states/0` is the single definition of
  "still composing", called at runtime so this module and the resource don't
  form a compile-time cycle.

  ## Messages are gettext'd (#3074)

  The refusal text is translated in the caller's locale, which a LiveView
  process sets from the viewer. A caller with no locale (the JSON:API, GraphQL,
  a worker) gets the default `en` text, so API errors keep their wording.

  Reads the parent release rather than trusting a passed-in state, because on
  `:add` the release is a foreign key the caller supplied.
  """
  use Ash.Resource.Validation
  use Gettext, backend: KilnCMSWeb.Gettext

  alias Ash.Error.Changes.InvalidChanges
  alias KilnCMS.CMS.ContentRelease
  alias KilnCMS.CMS.Validations.Lookup

  @locks %{share: "FOR SHARE", update: :for_update}

  @impl true
  def init(opts) do
    case Keyword.get(opts, :lock, :share) do
      lock when is_map_key(@locks, lock) -> {:ok, Keyword.put(opts, :lock, lock)}
      other -> {:error, "lock must be :share or :update, got: #{inspect(other)}"}
    end
  end

  # `Keyword.get/3` with the default, not `opts[:lock]` alone: a direct call
  # (a test, a caller outside the DSL) does not run `init/1`.
  @impl true
  def validate(changeset, opts, context) do
    release_id =
      Ash.Changeset.get_attribute(changeset, :release_id) || Map.get(changeset.data, :release_id)

    lock = Map.fetch!(@locks, Keyword.get(opts, :lock, :share))

    case release(release_id, lock, changeset.tenant, context) do
      {:ok, %{state: state}} ->
        if state in ContentRelease.editable_states() do
          :ok
        else
          {:error,
           InvalidChanges.exception(
             fields: [:release_id],
             message: gettext("release is no longer open for changes")
           )}
        end

      # Refused to this caller: the write is refused as Forbidden, which is
      # what the action's own policy would have said about this caller.
      {:error, %Ash.Error.Forbidden{} = forbidden} ->
        {:error, forbidden}

      # Unreadable in this tenant. The `belongs_to` FK is on `content_releases`
      # alone and carries no org column, so a release belonging to ANOTHER org
      # satisfies it — and letting that through writes an item into this org
      # that no release here can see, holding its content's reservation slot
      # forever with no UI able to free it. Refuse instead of deferring to the
      # foreign key.
      _ ->
        {:error,
         InvalidChanges.exception(
           fields: [:release_id],
           message: gettext("release was not found")
         )}
    end
  end

  defp release(nil, _lock, _tenant, _context), do: :error

  # As the caller (#1659): composing a release needs `OrgEditor`, and so does
  # reading one, so the caller can always see the release it is adding to. A
  # refusal is returned as the Forbidden it is: refused, never let through.
  #
  # `FOR SHARE`, or `FOR UPDATE` for an add, held until the item write
  # commits — see the moduledoc.
  defp release(id, lock, tenant, context) do
    KilnCMS.CMS.get_release(
      id,
      Keyword.put(
        Lookup.as_caller(context, tenant),
        :query,
        Ash.Query.lock(ContentRelease, lock)
      )
    )
  end
end

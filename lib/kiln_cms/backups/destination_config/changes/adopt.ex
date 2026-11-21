defmodule KilnCMS.Backups.DestinationConfig.Changes.Adopt do
  @moduledoc """
  The `:adopt_directories` action's new `adoptions`: the `:adopt` ids added,
  the `:release` ids removed (`KilnCMS.Backups.DestinationConfig`, "Adopted
  backup directories").

  Each id is trimmed and lowercased, and must then be a backup-directory id
  (`KilnCMS.Backups.DirId.valid?/1`). An adopted entry is bound to the
  backup directories of the nodes alive now (the `KilnCMS.Backups` domain's `live_dir_ids`:
  every recent heartbeat's, and this node's own): only a node with one of
  those ids prunes the adopted directory's backups. Adopting an id again
  binds it afresh. A directory a live node still reports is refused: its own
  server prunes its backups, and this one must not.

  The list is worked out in a `before_action`, from the row read again under
  `FOR UPDATE` inside the transaction, so two admins' adoptions at once both
  land rather than the second writing over the first (or bringing back an
  entry the first removed). What changed is left in the changeset context
  (`:adoption_changes`) for the audit event.
  """
  use Ash.Resource.Change
  use Gettext, backend: KilnCMSWeb.Gettext

  alias Ash.Error.Changes.InvalidArgument
  alias KilnCMS.Backups
  alias KilnCMS.Backups.{DestinationConfig, DirId}

  @impl true
  def change(changeset, _opts, _context) do
    with {:ok, adopt} <- ids(changeset, :adopt),
         {:ok, release} <- ids(changeset, :release),
         {:ok, bound_to} <- bound_to(adopt) do
      Ash.Changeset.before_action(changeset, &apply_locked(&1, adopt, release, bound_to))
    else
      {:error, error} -> Ash.Changeset.add_error(changeset, error)
    end
  end

  defp ids(changeset, name) do
    given = Ash.Changeset.get_argument(changeset, name) || []
    ids = given |> Enum.map(&normalize/1) |> Enum.uniq()

    if Enum.all?(ids, &DirId.valid?/1),
      do: {:ok, ids},
      else:
        {:error,
         InvalidArgument.exception(
           field: name,
           message: gettext("is not a backup directory id")
         )}
  end

  defp normalize(id) when is_binary(id), do: id |> String.trim() |> String.downcase()
  defp normalize(other), do: other

  # Nothing to adopt needs no live directories.
  defp bound_to([]), do: {:ok, []}

  defp bound_to(adopt) do
    case Backups.live_dir_ids() do
      {:ok, []} ->
        {:error, adopt_error(gettext("no running server reports a backup directory"))}

      {:ok, live} ->
        if Enum.any?(adopt, &(&1 in live)),
          do:
            {:error,
             adopt_error(
               gettext(
                 "that backup directory belongs to a running server, which prunes its own backups"
               )
             )},
          else: {:ok, live}

      {:error, _error} ->
        {:error,
         adopt_error(gettext("couldn't tell which backup directories running servers use"))}
    end
  end

  defp adopt_error(message), do: InvalidArgument.exception(field: :adopt, message: message)

  defp apply_locked(changeset, adopt, release, bound_to) do
    before = locked_adoptions(changeset.data.id)
    at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    kept = Enum.reject(before, &(&1["dir_id"] in adopt or &1["dir_id"] in release))

    added =
      for id <- adopt,
          do: %{"dir_id" => id, "adopted_by" => bound_to, "adopted_at" => at}

    removed = for %{"dir_id" => id} <- before, id in release and id not in adopt, do: id

    adoptions = kept ++ added

    case check(adoptions) do
      :ok ->
        # The locked value stands in for the one the caller read, so the
        # write is compared with the row as it is: a list equal to a stale
        # read (another admin adopted meanwhile, and this releases it) is
        # still written, and one equal to the row is the no-op it is.
        %{changeset | data: %{changeset.data | adoptions: before}}
        |> Ash.Changeset.force_change_attribute(:adoptions, adoptions)
        |> Ash.Changeset.set_context(%{adoption_changes: %{adopted: adopt, removed: removed}})

      {:error, message} ->
        Ash.Changeset.add_error(changeset, adopt_error(message))
    end
  end

  @doc """
  Whether `adoptions` may be stored: each entry's `dir_id` a backup-directory
  id, at most once, its `adopted_by` a non-empty list of them, and no more
  than `DestinationConfig.max_adoptions/0` entries. `{:error, message}` names
  the first rule broken.
  """
  @spec check([map()]) :: :ok | {:error, String.t()}
  def check(adoptions) when is_list(adoptions) do
    max = DestinationConfig.max_adoptions()
    ids = Enum.map(adoptions, &(is_map(&1) && &1["dir_id"]))

    cond do
      length(adoptions) > max ->
        {:error, gettext("a destination can adopt at most %{max} backup directories", max: max)}

      not Enum.all?(adoptions, &well_formed?/1) ->
        {:error, gettext("an adopted backup directory is not well formed")}

      length(Enum.uniq(ids)) != length(ids) ->
        {:error, gettext("a backup directory is adopted twice")}

      true ->
        :ok
    end
  end

  def check(_other), do: {:error, gettext("an adopted backup directory is not well formed")}

  defp well_formed?(%{"dir_id" => id, "adopted_by" => [_ | _] = by, "adopted_at" => at})
       when is_binary(at),
       do: DirId.valid?(id) and Enum.all?(by, &DirId.valid?/1)

  defp well_formed?(_entry), do: false

  # The row's adoptions as they are now, its row locked until the
  # transaction ends.
  defp locked_adoptions(id) do
    %{rows: rows} =
      KilnCMS.Repo.query!(
        "SELECT adoptions FROM backup_destinations WHERE id = $1 FOR UPDATE",
        [Ecto.UUID.dump!(id)]
      )

    case rows do
      [[adoptions]] when is_list(adoptions) -> adoptions
      _gone -> []
    end
  end
end

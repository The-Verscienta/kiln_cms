defmodule KilnCMS.CMS.Changes.CheckExpectedVersion do
  @moduledoc """
  Optimistic concurrency for the headless write surface: refuse a write unless
  the record is still the version the client read.

  The editor has had this since the start — `:update` carries
  `optimistic_lock(:lock_version)` — but it compares against the version the
  *server* just loaded. Over the API that is useless: `PATCH /api/json/pages/:id`
  reads the row and applies the patch in the same request, so a client editing
  from a copy it fetched a minute ago overwrote whatever an editor saved since,
  silently. The version the client read has to come from the client.

  Two ways in, either or both:

    * **`If-Match`** on the JSON:API write routes (`PATCH`, the workflow
      verbs, `DELETE`). `KilnCMSWeb.Plugs.IfMatch` parses it into the Ash
      context as `:kiln_if_match` — a list of `{lock_version, state}` pairs
      from the `ETag`s the client quotes (`KilnCMSWeb.ContentETag`), or
      `:mismatch` for a value that cannot match anything. Any one pair
      matching passes; `*` passes whenever the record exists.
    * **`expected_lock_version`**, an action argument — for GraphQL, where
      there is no request header per mutation, and for any caller that would
      rather put it in the body. It compares `lock_version` alone.

  Neither present: a no-op, so existing clients are untouched.

  The comparison runs in a `before_action` — inside the action's transaction
  — against the row read `FOR UPDATE`, not against `changeset.data`: the data
  was loaded before the transaction began, so a write landing in between would
  pass a check against it and then be overwritten. With the row locked, a
  concurrent writer waits for this transaction, and whatever it wrote before
  the lock is what gets compared.

  A mismatch is `KilnCMS.CMS.Errors.PreconditionFailed` — a 412 over JSON:API.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias KilnCMS.CMS.Errors.PreconditionFailed

  @impl true
  def change(changeset, _opts, _context) do
    case expectations(changeset) do
      [] -> changeset
      expected -> Ash.Changeset.before_action(changeset, &check(&1, expected))
    end
  end

  # Each entry must hold; within the `If-Match` entry, any one tag may match.
  defp expectations(changeset) do
    argument =
      case Ash.Changeset.get_argument(changeset, :expected_lock_version) do
        nil -> []
        version -> [{:lock_version, version}]
      end

    if_match =
      case changeset.context[:kiln_if_match] do
        nil -> []
        tags -> [{:if_match, tags}]
      end

    argument ++ if_match
  end

  defp check(changeset, expected) do
    current = current(changeset)

    if current && Enum.all?(expected, &holds?(&1, current)) do
      changeset
    else
      Ash.Changeset.add_error(
        changeset,
        PreconditionFailed.exception(
          lock_version: current && current.lock_version,
          state: current && current.state
        )
      )
    end
  end

  defp holds?({:lock_version, version}, current), do: version == current.lock_version
  defp holds?({:if_match, :any}, _current), do: true
  defp holds?({:if_match, :mismatch}, _current), do: false

  defp holds?({:if_match, tags}, current) when is_list(tags) do
    state = to_string(current.state)

    Enum.any?(tags, fn {version, tag_state} ->
      version == current.lock_version and tag_state == state
    end)
  end

  # The row as it is now, locked until this transaction ends.
  defp current(%{resource: resource, data: data} = changeset) do
    resource
    |> Ash.Query.filter(id == ^data.id)
    |> Ash.Query.select([:lock_version, :state])
    |> Ash.Query.lock(:for_update)
    # authorize?: false — the caller has already been authorized for this very
    # write on this very record; this re-reads two columns of it, under its own
    # tenant, to compare versions. Nothing read here reaches the caller except
    # through the 412, which reports the version of a record they may write.
    |> Ash.read_one(authorize?: false, tenant: changeset.to_tenant)
    |> case do
      {:ok, row} -> row
      _ -> nil
    end
  end
end

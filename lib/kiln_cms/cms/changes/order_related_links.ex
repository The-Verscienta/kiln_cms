defmodule KilnCMS.CMS.Changes.OrderRelatedLinks do
  @moduledoc """
  Keeps the order of a record's curated related content (#2025) in the
  `position` of its `kind: :related` `ContentLink` rows.

  `related_<type>_ids` is a list, and the editor's picker lets it be
  reordered, but `manage_relationship` relates the ids as a set: every row it
  creates gets the default position 0, and a reorder of rows that already
  exist changes nothing at all. So after the write:

    * `related_<type>_ids` (the complete set) numbers the rows in its order —
      `KilnCMS.CMS.ContentLinks.order_related/2`;
    * `add_related_<type>_ids` places the rows it created after the ones that
      were there — `KilnCMS.CMS.ContentLinks.append_related/3`, with the
      related targets read before the write;
    * `remove_related_<type>_ids` leaves the rest where they are.

  Declared after the `manage_relationship` changes it follows, and runs in an
  `after_action`, by which point those have created and removed the rows. A
  working copy's held list is numbered as it is published, by
  `PromoteWorkingCopy.promote_relationships/2` calling `after_write/3`.

      change {OrderRelatedLinks, complete: :related_post_ids, add: :add_related_post_ids}
  """
  use Ash.Resource.Change

  alias KilnCMS.CMS.ContentLinks

  @impl true
  def init(opts) do
    case Keyword.fetch(opts, :complete) do
      {:ok, complete} when is_atom(complete) -> {:ok, opts}
      _other -> {:error, ":complete must name the complete-set argument"}
    end
  end

  @impl true
  def change(changeset, opts, _context) do
    complete = Ash.Changeset.get_argument(changeset, opts[:complete])
    add = if opts[:add], do: Ash.Changeset.get_argument(changeset, opts[:add])

    cond do
      is_list(complete) -> after_write(changeset, complete)
      is_list(add) and add != [] -> append(changeset, add)
      true -> changeset
    end
  end

  @doc """
  Numbers the related rows in `ids` order once `changeset`'s write — and the
  `manage_relationship` that relates `ids` — is done.
  """
  @spec after_write(Ash.Changeset.t(), [Ash.UUID.t()]) :: Ash.Changeset.t()
  def after_write(changeset, ids) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      :ok = ContentLinks.order_related(record, ids)
      {:ok, record}
    end)
  end

  # Which targets were related before the write, so the ones it adds can go
  # after them. Only a `:create` has nothing before it, and a create has no
  # `add_` argument.
  defp append(changeset, ids) do
    changeset
    |> Ash.Changeset.before_action(fn changeset ->
      before = ContentLinks.related_order(changeset.data)
      Ash.Changeset.put_context(changeset, :related_before, before)
    end)
    |> Ash.Changeset.after_action(fn changeset, record ->
      :ok = ContentLinks.append_related(record, changeset.context[:related_before] || [], ids)
      {:ok, record}
    end)
  end
end

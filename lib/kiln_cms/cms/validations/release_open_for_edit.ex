defmodule KilnCMS.CMS.Validations.ReleaseOpenForEdit do
  @moduledoc """
  Refuses to add an item to — or cancel an item out of — a release that is no
  longer composing (#500).

  Without this, "add to release" would silently succeed against a release that
  already shipped (the item would sit there `:pending` forever, reserving its
  content against every future release), and cancelling an item mid-go-live
  would race the worker walking that exact row — which is also what lets the
  worker read its item list once, before opening its transaction.

  `KilnCMS.CMS.ContentRelease.editable_states/0` is the single definition of
  "still composing", called at runtime so this module and the resource don't
  form a compile-time cycle.

  Reads the parent release rather than trusting a passed-in state, because on
  `:add` the release is a foreign key the caller supplied.
  """
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidChanges
  alias KilnCMS.CMS.ContentRelease

  @impl true
  def validate(changeset, _opts, _context) do
    release_id =
      Ash.Changeset.get_attribute(changeset, :release_id) || Map.get(changeset.data, :release_id)

    case release(release_id, changeset.tenant) do
      {:ok, %{state: state}} ->
        if state in ContentRelease.editable_states() do
          :ok
        else
          {:error,
           InvalidChanges.exception(
             fields: [:release_id],
             message: "release is no longer open for changes"
           )}
        end

      # A missing release is the `belongs_to`'s problem to report (or the row is
      # simply gone) — don't invent a second, confusing error for it.
      _ ->
        :ok
    end
  end

  defp release(nil, _tenant), do: :error
  defp release(id, tenant), do: KilnCMS.CMS.get_release(id, authorize?: false, tenant: tenant)
end

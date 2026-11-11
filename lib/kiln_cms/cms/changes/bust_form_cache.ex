defmodule KilnCMS.CMS.Changes.BustFormCache do
  @moduledoc """
  Clears the delivery caches on every node after any form (or form-field)
  write. A form may be embedded on any number of published pages via the
  `:form` block — the blast radius isn't a single `{type, slug}` — so this is
  the wide-radius invalidation, as for media edits. Forms change rarely; a
  full clear is cheap.

  Cluster-wide, because what a form renders now includes whether it draws a
  human-verification widget (#2249): a node still holding the old payload
  would serve a page without the widget whose submissions are then held, or
  one with a widget its policy no longer allows.

  Scoped to the form's site and to the delivery *payloads*
  (`KilnCMS.Cache.bust_form_payloads/1`) — the only shape that embeds a form.
  A full clear (`ClusterBust.broadcast_clear/0`) would also drop every site's
  published records and the fired-artifact cache, which only carries a
  `data-kiln-form` placeholder.

  After the transaction rather than after the action: a page rebuilt between
  the bust and the commit would read the old form and be cached again.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn
      _changeset, {:error, _error} = result ->
        result

      changeset, result ->
        KilnCMS.Cache.bust_form_payloads(org_id(changeset, result))
        result
    end)
  end

  defp org_id(_changeset, {:ok, %{org_id: org_id}}) when is_binary(org_id), do: org_id
  defp org_id(%{data: %{org_id: org_id}}, _result) when is_binary(org_id), do: org_id
  defp org_id(_changeset, _result), do: nil
end

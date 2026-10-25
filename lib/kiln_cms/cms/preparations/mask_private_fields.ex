defmodule KilnCMS.CMS.Preparations.MaskPrivateFields do
  @moduledoc """
  Leaves the **private** custom fields (#2044, `KilnCMS.CMS.PrivateFields`)
  out of every content record a read returns to someone below editor.

  `custom_fields` is a public attribute, so JSON:API, GraphQL and MCP serve
  it as read. A private field's value is for the site's editors and admins,
  so for anyone else — an anonymous caller, a viewer, an API key without
  editor rights — the key is simply not there.

  Declared beside `MaskUnreadableReferences` on the resource's top-level
  `preparations`, so it runs on every read action, and skipped by the same
  rule, for the same reason: a value that could feed a write is returned
  whole.

    * `authorize?: false` reads (firing, workers, internal plumbing) — the
      fired artifacts drop private fields themselves
      (`KilnCMS.Firing.CustomFields`);
    * a `KilnCMS.SystemActor`;
    * an editor or admin of the org (`Scoping.effective_tier/2`).

  The stored value is never changed. The private names come from the site's
  cached map (`PrivateFields.all/1`), so a read costs no definitions query.
  """
  use Ash.Resource.Preparation

  alias KilnCMS.Accounts.Scoping
  alias KilnCMS.CMS.PrivateFields

  @impl true
  def prepare(query, _opts, context) do
    if mask?(query, context) do
      # The definitions are found by the record's org and (for an entry) its
      # type definition, which a read that names its fields — GraphQL's — may
      # not select: two keys more on such a read.
      query
      |> ensure_keys()
      |> Ash.Query.after_action(fn query, records -> {:ok, mask(records, query.tenant)} end)
    else
      query
    end
  end

  # authorize?: false — a match on the read's own flag, not a bypass: such a
  # read is internal plumbing whose result may be written back.
  defp mask?(_query, %{authorize?: false}), do: false
  defp mask?(_query, %{actor: %KilnCMS.SystemActor{}}), do: false

  defp mask?(query, %{actor: actor}),
    do: Scoping.effective_tier(actor, query) not in [:editor, :admin]

  defp ensure_keys(query) do
    keys =
      Enum.filter(
        [:org_id, :type_definition_id],
        &Ash.Resource.Info.attribute(query.resource, &1)
      )

    Ash.Query.ensure_selected(query, keys)
  end

  defp mask(records, tenant) do
    Enum.map(records, fn record ->
      case Map.get(record, :custom_fields) do
        values when is_map(values) and not is_struct(values) and map_size(values) > 0 ->
          %{record | custom_fields: PrivateFields.drop_for(values, record, tenant)}

        _ ->
          record
      end
    end)
  end
end

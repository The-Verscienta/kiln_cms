defmodule KilnCMS.Accounts.Changes.SetContentListColumns do
  @moduledoc """
  Remember which custom fields the content list shows as columns for one
  content type on one site (`User.content_list_columns`, a map of
  `org_id => %{type => [field name]}`).

  Two guarantees, both about the map being shared by every tab and site:

    * **Merge, never replace.** The new list is merged into the *current* column
      (read under a row lock), so a stale copy of the user (another tab, another
      site) cannot clobber the entries it did not touch. The changeset's own
      copy of the map is never read.
    * **Names are checked on write** against the site's field definitions,
      read as the actor under the site's tenant, through
      `KilnCMS.CMS.ListFields.readable_fields/4`. A name that is unknown,
      repeated, not a string, or past the cap is an error here; a field deleted
      later is dropped silently on read (`ListFields.resolve_columns/2`). An
      actor who may not read the site's definitions gets the same "unknown"
      answer as one naming a field that does not exist, so the write cannot be
      used to probe another site's field names.

  The validation runs in a `before_action` so building the changeset (as
  `Accounts.can_set_content_list_columns?/2` does) reads nothing.
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts.Scoping
  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.HiddenFields
  alias KilnCMS.CMS.ListFields
  alias KilnCMS.Repo

  @impl true
  def change(changeset, _opts, context) do
    org_id = Ash.Changeset.get_argument(changeset, :org_id)
    type = Ash.Changeset.get_argument(changeset, :type)
    names = Ash.Changeset.get_argument(changeset, :names)

    Ash.Changeset.before_action(changeset, fn changeset ->
      case validate(context.actor, org_id, type, names) do
        :ok ->
          merge(changeset, org_id, type, names)

        {:error, field, message} ->
          Ash.Changeset.add_error(changeset, field: field, message: message)
      end
    end)
  end

  @impl true
  def atomic(_changeset, _opts, _context),
    do: {:not_atomic, "the names are validated against the site's field definitions"}

  defp validate(actor, org_id, type, names) do
    with :ok <- check_shape(names),
         {:ok, descriptor} <- descriptor(actor, org_id, type) do
      check_names(actor, org_id, descriptor, names)
    end
  end

  defp check_shape(names) when is_list(names) do
    cond do
      not Enum.all?(names, &(is_binary(&1) and &1 != "")) ->
        {:error, :names, "must all be field names"}

      length(names) > ListFields.max_stored() ->
        {:error, :names, "at most #{ListFields.max_stored()} columns"}

      length(Enum.uniq(names)) != length(names) ->
        {:error, :names, "must not repeat a column"}

      true ->
        :ok
    end
  end

  defp check_shape(_names), do: {:error, :names, "must be a list of field names"}

  # Only a site the actor edits, and a type that site has: anything else is the
  # same answer, so the write says nothing about sites or types it may not see.
  defp descriptor(actor, org_id, type) do
    with true <- Scoping.effective_tier(actor, org_id) in [:editor, :admin],
         %{} = descriptor <- ContentTypes.get(type, org_id),
         true <- to_string(descriptor.type) == type do
      {:ok, descriptor}
    else
      _ -> {:error, :type, "is not a content type of this site"}
    end
  end

  defp check_names(actor, org_id, descriptor, names) do
    known =
      actor
      |> HiddenFields.visible_definitions(
        org_id,
        descriptor,
        definitions(actor, org_id, descriptor)
      )
      |> then(&ListFields.readable_fields(actor, org_id, &1, true))
      |> MapSet.new(& &1.name)

    if Enum.all?(names, &MapSet.member?(known, &1)),
      do: :ok,
      else: {:error, :names, "must name fields of this content type"}
  end

  defp definitions(actor, org_id, %{source: :dynamic, definition: %{id: id}}),
    do: CMS.field_definitions_for_definition!(id, actor: actor, tenant: org_id)

  defp definitions(actor, org_id, %{type: type}),
    do: CMS.field_definitions_for!(type, actor: actor, tenant: org_id)

  # The column is read again here, under a row lock, rather than taken from the
  # changeset: the user struct may be a stale copy (another tab, another site),
  # and the lock serialises two writers so neither loses the other's entry.
  # (`:map` takes no atomic expression, so this is read-then-write.)
  defp merge(changeset, org_id, type, names) do
    %{rows: [[stored]]} =
      Repo.query!("SELECT content_list_columns FROM users WHERE id = $1 FOR UPDATE", [
        Ecto.UUID.dump!(changeset.data.id)
      ])

    stored = if is_map(stored), do: stored, else: %{}
    for_org = if is_map(stored[org_id]), do: stored[org_id], else: %{}
    merged = Map.put(stored, org_id, Map.put(for_org, type, names))

    Ash.Changeset.force_change_attribute(changeset, :content_list_columns, merged)
  end
end

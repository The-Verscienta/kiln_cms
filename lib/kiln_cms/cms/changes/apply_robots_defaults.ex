defmodule KilnCMS.CMS.Changes.ApplyRobotsDefaults do
  @moduledoc """
  On create, starts `noindex` / `nofollow` at the type's default (#2256) for
  each flag the caller did not supply.

  "Did not supply" is read off the input params, not the attribute: Ash fills
  the attribute default before changes run and drops a change equal to it, so
  the changeset cannot tell an explicit `false` from an omitted one. A copy, a
  translation or an import names the flag, so it keeps the source's value; an
  explicit `false` beats a type default of `true`.

  Compiled types carry the defaults as `use KilnCMS.CMS.Content` options;
  dynamic entries read their `TypeDefinition` row (a keyed read, as the slug
  pattern does). Defaults are not retroactive: only creates are touched.
  """
  use Ash.Resource.Change

  alias KilnCMS.CMS.Slugs

  @impl true
  def change(changeset, _opts, _context) do
    case missing(changeset) do
      [] ->
        changeset

      flags ->
        defaults = defaults(changeset)
        Enum.reduce(flags, changeset, &apply_default(&1, &2, defaults))
    end
  end

  # Only a `true` default is forced: `false` is already the attribute default.
  defp apply_default(flag, changeset, defaults) do
    if Map.get(defaults, flag) == true,
      do: Ash.Changeset.force_change_attribute(changeset, flag, true),
      else: changeset
  end

  defp missing(changeset) do
    Enum.reject([:noindex, :nofollow], &supplied?(changeset.params, &1))
  end

  defp supplied?(params, flag),
    do: Map.has_key?(params, flag) or Map.has_key?(params, to_string(flag))

  defp defaults(%{resource: resource} = changeset) do
    if Code.ensure_loaded?(resource) and
         function_exported?(resource, :__kiln_noindex_default__, 0) do
      %{
        noindex: resource.__kiln_noindex_default__(),
        nofollow: resource.__kiln_nofollow_default__()
      }
    else
      dynamic_defaults(changeset)
    end
  end

  # An entry with no type definition has no type default. Any failure to read
  # the definition that IS named raises: reading it as "no default" would
  # quietly create an indexable entry in a type that meant to hide them.
  defp dynamic_defaults(changeset) do
    case Slugs.changeset_attribute(changeset, :type_definition_id) do
      nil ->
        %{}

      id ->
        case KilnCMS.CMS.get_type_definition(id,
               actor: KilnCMS.CMS.Housekeeping.system(:cms_registry),
               authorize_with: :error,
               tenant: changeset.tenant
             ) do
          {:ok, definition} ->
            %{noindex: definition.noindex_default, nofollow: definition.nofollow_default}

          {:error, error} ->
            raise error
        end
    end
  end
end

defmodule KilnCMS.CMS.SelectTerms do
  @moduledoc """
  The terms already in use on a multiple `:select` field that takes terms of
  its own (`allow_custom`) — what the content editor's tag picker suggests
  beside the field's `options`.

  A term an editor adds never joins `options`: that list is admin-authored,
  and an editor's save has no business rewriting a field definition. Without
  this, though, the second editor to want "anti-inflammatory" would type it
  again, and the third would type "antiinflammatory". Suggesting what the
  type's records already hold keeps one spelling in circulation.

  Read once when the editor mounts, not per keystroke, as one grouped query
  over the type's records in the writing site — most used first, capped. The
  rows are read without a policy check: a term is a field value on a record
  of a type the editor is already writing, and nothing but the term itself
  leaves the query.
  """

  alias KilnCMS.CMS.Changes.SyncFieldValues

  @limit 200

  @doc """
  The terms in use per open-vocabulary field of `definitions`, most used
  first: `%{field_name => [term]}`. Fields that are not a multiple select
  with `allow_custom` are left out, and so the map is empty for most types.
  """
  @spec used([KilnCMS.CMS.FieldDefinition.t()]) :: %{String.t() => [String.t()]}
  def used(definitions) do
    for %{field_type: :select, multiple: true, allow_custom: true} = definition <- definitions,
        into: %{},
        do: {definition.name, terms(definition)}
  end

  # The table and the `$n` tail come from `SyncFieldValues.target/1` (a
  # resource's compile-time table name and generated digits); every value is
  # a bound parameter.
  # sobelow_skip ["SQL.Query"]
  defp terms(definition) do
    case SyncFieldValues.target(definition) do
      {:ok, table, filter, params} ->
        """
        SELECT term
          FROM #{table},
               jsonb_array_elements_text(
                 CASE WHEN jsonb_typeof(custom_fields -> $1::text) = 'array'
                      THEN custom_fields -> $1::text
                      ELSE '[]'::jsonb
                 END
               ) AS term
         WHERE custom_fields ? $1::text#{filter.(1)}
         GROUP BY term
         ORDER BY count(*) DESC, term
         LIMIT #{@limit}
        """
        |> KilnCMS.Repo.query([definition.name | params])
        |> case do
          {:ok, %{rows: rows}} -> Enum.map(rows, &hd/1)
          {:error, _error} -> []
        end

      :error ->
        []
    end
  end
end

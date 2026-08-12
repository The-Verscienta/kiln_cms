defmodule KilnCMS.CMS.Preparations.RejectUnsortableCalculations do
  @moduledoc """
  `sort=word_count` (or `path`, `effective_seo_title`, `related_links`,
  `block_ids`, ...) crashes instead of being rejected.

  Filtering a `sortable? false` calculation is already caught cleanly: Ash's
  own query-building layer validates a filter reference against
  `filterable?` before the query reaches the data layer, so
  `filter[word_count]=5` comes back as a normal
  `Ash.Error.Query.InvalidFilterReference`.

  Sorting has no equivalent guard. `Ash.Sort`'s field resolution only checks
  a calculation's `sortable?` flag when the field is reached across a
  relationship (`author.word_count`); for a *local* sort it hits an "ugly
  workaround" (`type_sortable?/2` in `ash/lib/ash/sort/sort.ex`) that always
  returns `true` for `%Ash.Query.Calculation{}`, regardless of the flag.
  `ash_json_api`'s own sort parser (`AshJsonApi.Request.parse_sort/1`)
  inherits the same gap: it checks that a requested sort name resolves to
  *some* public calculation, never that calculation's `sortable?`. The query
  builds successfully and only fails once AshSql tries to hydrate the sort,
  looking for an `expression/2` clause these calculations don't define — an
  unhandled `UndefinedFunctionError`, not a query-layer rejection.

  Declared on the resource's top-level `preparations` (runs on every read
  action, not just `:read` — `:published`/`:trashed`/etc. all derive `sort=`
  too) so it applies after `Ash.Query.sort/2` has resolved each requested
  field into an `%Ash.Query.Calculation{}` but before the query reaches the
  data layer. Turns any `sortable? false` calculation left in `query.sort`
  into the same `Ash.Error.Query.UnsortableField` Ash itself raises for the
  cross-relationship case — `KilnCMSWeb.AshSortErrors` maps that to a clean
  `400 invalid_sort`, matching the code `ash_json_api` already uses for an
  unknown sort field.
  """
  use Ash.Resource.Preparation

  alias Ash.Error.Query.UnsortableField

  @impl true
  def prepare(query, _opts, _context) do
    query.sort
    |> Enum.find_value(&unsortable_calc_name/1)
    |> case do
      nil ->
        query

      name ->
        Ash.Query.add_error(
          query,
          UnsortableField.exception(field: name, resource: query.resource)
        )
    end
  end

  defp unsortable_calc_name({%Ash.Query.Calculation{sortable?: false, calc_name: name}, _order}),
    do: name

  defp unsortable_calc_name(_), do: nil
end

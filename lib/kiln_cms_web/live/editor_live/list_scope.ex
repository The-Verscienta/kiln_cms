defmodule KilnCMSWeb.EditorLive.ListScope do
  @moduledoc """
  What the content list (`KilnCMSWeb.EditorLive`) is a list OF, with no socket
  in it: the content types it reads, the one type whose custom fields it can
  filter, sort and show, and how the URL's filter params are checked against
  both.

  The content export (`KilnCMSWeb.ContentExportController`) calls the same
  functions, so a download holds exactly the rows the screen would list for the
  same URL and cannot reach further. The scope is the types the actor can
  AUTHOR (`NewDraft.authorable_types/2`), which is what the list shows — not
  merely the types they may read.

  Also here, for the screen to offer the export: `export_count/6`, the bounded
  count behind "Export 214 matching", and `export_path/3`, the link.
  """
  use KilnCMSWeb, :verified_routes

  alias KilnCMS.Accounts
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.HiddenFields
  alias KilnCMS.CMS.ListFieldQuery
  alias KilnCMS.CMS.ListFields
  alias KilnCMSWeb.ContentEditor.NewDraft
  alias KilnCMSWeb.EditorLive.FieldCells
  alias KilnCMSWeb.EditorLive.Filters

  # The most rows one export holds unless `config :kiln_cms, :content_export,
  # max_rows: n` says otherwise.
  @export_cap 10_000

  @doc """
  Every content type `actor` may author on `org` — compiled and dynamic —
  which is the list's whole scope.
  """
  @spec types(map() | nil, term()) :: [map()]
  def types(actor, org), do: NewDraft.authorable_types(actor, org)

  @doc "A descriptor's filter/URL value (compiled types carry an atom, dynamic ones a name)."
  @spec type_value(map()) :: String.t()
  def type_value(%{type: type}), do: to_string(type)

  @doc "The types in `types` the `type` filter reads: all of them, or the one it names."
  @spec filtered_types([map()], String.t()) :: [map()]
  def filtered_types(types, "all"), do: types
  def filtered_types(types, type), do: Enum.filter(types, &(type_value(&1) == type))

  @doc """
  The one content type whose fields the list can show as columns: the type the
  filter names, or the only type there is. `nil` for "all" on a site with
  several, where field names collide across types.
  """
  @spec column_type([map()], String.t()) :: map() | nil
  def column_type([only], "all"), do: only
  def column_type(_types, "all"), do: nil

  def column_type(types, type) do
    case filtered_types(types, type) do
      [descriptor] -> descriptor
      _none -> nil
    end
  end

  @doc """
  The custom fields of the type `type` (a type value) that `actor` may list,
  filter and sort by: what `ListFields` offers an editor, private fields
  included. Every field condition is validated against it.
  """
  @spec field_definitions([map()], String.t(), map() | nil, term()) :: [struct()]
  def field_definitions(types, type, actor, org) do
    case Enum.find(types, &(type_value(&1) == type)) do
      nil ->
        []

      descriptor ->
        # A private field a read restriction hides from `actor` is not offered
        # as a column, filter or sort, and so never reaches an export (#2281).
        definitions =
          actor
          |> HiddenFields.visible_definitions(
            org,
            descriptor,
            FieldCells.definitions(descriptor, actor, org)
          )

        ListFields.readable_fields(actor, org, definitions, true)
    end
  end

  @doc """
  What `Filters.parse/2` checks a URL against. `:fields` reads a type's field
  definitions only when a `cf` or field sort asks, so a plain list costs no
  extra read.
  """
  @spec filter_ctx([map()], [String.t()], map() | nil, term()) :: map()
  def filter_ctx(types, locales, actor, org) do
    %{
      types: Enum.map(types, &type_value/1),
      locales: locales,
      fields: &field_definitions(types, &1, actor, org)
    }
  end

  @doc """
  The names `user` remembered as list columns for `descriptor`'s type on `org`
  that still name one of `options`, in stored order.
  """
  @spec column_names(map() | nil, term(), map(), [struct()]) :: [String.t()]
  def column_names(user, org, descriptor, options) do
    known = MapSet.new(options, & &1.name)

    user
    |> ListFields.stored_columns(Accounts.org_id(org), type_value(descriptor))
    |> Enum.filter(&MapSet.member?(known, &1))
  end

  # --- export ---------------------------------------------------------------

  @doc "The most rows one export holds."
  @spec export_cap() :: pos_integer()
  def export_cap do
    :kiln_cms |> Application.get_env(:content_export, []) |> Keyword.get(:max_rows, @export_cap)
  end

  @doc """
  How many rows an export of `types` under `filters` would hold: `{:ok, n}`, or
  `:over_cap` when there are more than `export_cap/0`.

  Bounded, exact below the cap: each type is counted with a limit of one more
  than the cap, never the whole table. `definitions` are the field definitions
  of the type in play (what the filter's conditions are checked against);
  `extra` is more Ash query options, e.g. `[filter: [id: [in: ids]]]`.
  """
  @spec export_count([map()], map(), map() | nil, term(), [struct()], keyword()) ::
          {:ok, non_neg_integer()} | :over_cap
  def export_count(types, filters, actor, org, definitions, extra \\ []) do
    cap = export_cap()
    query = Filters.query_filters(filters, actor.id) ++ extra ++ [limit: cap + 1]
    arguments = ListFieldQuery.arguments(Filters.conditions(filters), nil, definitions)

    Enum.reduce_while(types, {:ok, 0}, fn descriptor, {:ok, total} ->
      count =
        ContentTypes.count!(descriptor,
          actor: actor,
          tenant: org,
          query: query,
          arguments: arguments
        )

      if total + count > cap, do: {:halt, :over_cap}, else: {:cont, {:ok, total + count}}
    end)
  end

  @doc "The most rows `export_path/3` accepts in `ids`."
  @spec max_ids() :: pos_integer()
  def max_ids, do: 100

  @doc """
  The download link for `format` (`:csv` or `:json`) of the list under
  `filters`.

  Options: `ids:` (an export of those rows only, the filters left out so a
  selection that predates a filter change is not narrowed by it; at most
  `max_ids/0`) and `private?:` (also export the private field columns).
  """
  @spec export_path(:csv | :json, map(), keyword()) :: String.t()
  def export_path(format, filters, opts \\ []) when format in [:csv, :json] do
    params = Filters.to_params(filters)

    params =
      case Keyword.get(opts, :ids) do
        ids when is_list(ids) and ids != [] ->
          params |> Map.take(["type"]) |> Map.put("ids", Enum.join(ids, ","))

        _none ->
          params
      end

    params =
      if Keyword.get(opts, :private?, false), do: Map.put(params, "private", "1"), else: params

    case format do
      :csv -> ~p"/editor/content/export.csv?#{params}"
      :json -> ~p"/editor/content/export.json?#{params}"
    end
  end
end

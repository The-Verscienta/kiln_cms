defmodule KilnCMSWeb.Plugs.AshJsonApiParams do
  @moduledoc """
  Refuses a `/api/json` query parameter whose *shape* `ash_json_api` 1.6.6 has
  no clause for, before the request reaches it (#763).

  Plug's query decoder gives the caller the shape as well as the value:
  `?sort=x` is a binary, `?sort[]=x` a list, `?sort[a]=x` a map. Several
  `ash_json_api` parsers assume the JSON:API-correct shape and have no clause
  for the others — an unhandled `FunctionClauseError`/`Protocol.UndefinedError`
  is a 500 plus one error-tracker event, unauthenticated, on every route this
  surface serves:

    * `page[limit]`/`page[offset]` go through `Integer.parse/1`, which has no
      clause for a list or a map (`page[limit][]=1`, `page[limit][a]=1`).
    * `page` itself must be an object (`page[limit]=10`, not `page=10`) —
      `Map.fetch/2` on a non-map `page` raises the same way.
    * `sort` and `include` must be a single scalar string (JSON:API's
      comma-separated list in one query value) — `sort[a]=1`/`include[a]=1`
      reach a `String.Chars`/`String.split/2` call with no map clause.

  `filter[...]` and `fields[...]` are **not** guarded here: both are correctly
  a nested shape in `ash_json_api` already (verified against the real router;
  they answer 400, not 500) — this plug only patches the specific gaps.

  ## One authority for the codes

  The `code` each rejection answers with — `invalid_pagination`,
  `invalid_sort`, `invalid_includes` — is copied from
  `AshJsonApi.Error.InvalidPagination`/`InvalidSort`/`InvalidIncludes`'s own
  `to_json_api_error/1`, so a client sees the identical code and envelope
  shape (`KilnCMSWeb.ApiError`) whether this plug caught the request before
  `ash_json_api` ever saw it, or a shape it already handles reached its own
  validator. There is no third code to learn.

  ## Not a general fix

  This is a narrow guard for parameters observed to raise, not a schema
  validator for the whole JSON:API query surface — a new `ash_json_api`
  parser gap needs its own guard here, the same way #751's
  `KilnCMSWeb.Params` needed a row per parameter rather than a blanket
  solution. Drop this plug once the upstream fix lands (tracked on #763);
  nothing here is otherwise load-bearing.
  """
  import Plug.Conn

  @doc false
  def init(opts), do: opts

  @doc false
  def call(conn, _opts) do
    conn = fetch_query_params(conn)

    case invalid(conn.query_params) do
      nil ->
        conn

      {code, detail} ->
        conn
        |> KilnCMSWeb.ApiError.send(400, code, detail)
        |> halt()
    end
  end

  defp invalid(params) do
    invalid_page(Map.get(params, "page")) || invalid_scalar_list(params)
  end

  defp invalid_page(nil), do: nil

  defp invalid_page(page) when is_map(page) do
    Enum.find_value(~w(limit offset), fn key ->
      case Map.get(page, key) do
        value when is_binary(value) or is_nil(value) ->
          nil

        _list_or_map ->
          {"invalid_pagination", "page[#{key}] must be a plain value, e.g. page[#{key}]=10."}
      end
    end)
  end

  defp invalid_page(_not_a_map),
    do: {"invalid_pagination", "page must be an object, e.g. page[limit]=10."}

  # `sort`/`include` are each a single comma-separated scalar in JSON:API —
  # `[{name, code}]` rather than a case per param, so a third one is a row.
  @scalar_only [{"sort", "invalid_sort"}, {"include", "invalid_includes"}]

  defp invalid_scalar_list(params) do
    Enum.find_value(@scalar_only, fn {name, code} ->
      case Map.get(params, name) do
        value when is_binary(value) or is_nil(value) ->
          nil

        _list_or_map ->
          {code, "#{name} must be a plain value, not a list or object."}
      end
    end)
  end
end

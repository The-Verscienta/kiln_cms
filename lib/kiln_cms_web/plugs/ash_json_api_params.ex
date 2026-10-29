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

  The `page[...]` *values* are checked too, not only their shape (audit,
  2026-10-29). A value `ash_json_api` 1.7.1 cannot cast (`page[limit]=abc`,
  `page[limit]=`, `page[offset]=1.5`, `page[count]=maybe`) reaches its own
  rejection, which builds `InvalidPagination` with a `source_parameter` field
  the struct does not have: a `KeyError`, so a 500 in place of the 400 it was
  writing. `page[limit]=0` casts, then fails inside Ash and reaches the client
  as an opaque `something_went_wrong`.

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

      {code, detail, parameter} ->
        conn
        |> KilnCMSWeb.ApiError.send(400, code, detail, source_parameter: parameter)
        |> halt()
    end
  end

  defp invalid(params) do
    invalid_page(Map.get(params, "page")) || invalid_scalar_list(params)
  end

  defp invalid_page(nil), do: nil

  # Every key `ash_json_api` reads from `page`, with what its value must be
  # and an example. `after`/`before` are opaque cursors: any string will do.
  @page_keys [
    {"limit", "a positive integer", "10"},
    {"offset", "a non-negative integer", "0"},
    {"count", "true or false", "true"},
    {"after", "a cursor string", "<cursor>"},
    {"before", "a cursor string", "<cursor>"}
  ]

  defp invalid_page(page) when is_map(page) do
    Enum.find_value(@page_keys, fn {key, must_be, example} ->
      invalid_page_key("page[#{key}]", key, Map.get(page, key), must_be, example)
    end)
  end

  defp invalid_page(_not_a_map),
    do: {"invalid_pagination", "page must be an object, e.g. page[limit]=10.", "page"}

  defp invalid_page_key(_parameter, _key, nil, _must_be, _example), do: nil

  defp invalid_page_key(parameter, key, value, must_be, example) when is_binary(value) do
    if valid_page_value?(key, value),
      do: nil,
      else:
        {"invalid_pagination", "#{parameter} must be #{must_be}, e.g. #{parameter}=#{example}.",
         parameter}
  end

  defp invalid_page_key(parameter, _key, _list_or_map, _must_be, example),
    do:
      {"invalid_pagination", "#{parameter} must be a plain value, e.g. #{parameter}=#{example}.",
       parameter}

  defp valid_page_value?("limit", value), do: match?({n, ""} when n > 0, Integer.parse(value))
  defp valid_page_value?("offset", value), do: match?({n, ""} when n >= 0, Integer.parse(value))
  defp valid_page_value?("count", value), do: value in ~w(true false)
  defp valid_page_value?(_cursor, _value), do: true

  # `sort`/`include` are each a single comma-separated scalar in JSON:API —
  # `[{name, code}]` rather than a case per param, so a third one is a row.
  @scalar_only [{"sort", "invalid_sort"}, {"include", "invalid_includes"}]

  defp invalid_scalar_list(params) do
    Enum.find_value(@scalar_only, fn {name, code} ->
      case Map.get(params, name) do
        value when is_binary(value) or is_nil(value) ->
          nil

        _list_or_map ->
          {code, "#{name} must be a plain value, not a list or object.", name}
      end
    end)
  end
end

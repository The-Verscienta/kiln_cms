defmodule KilnCMSWeb.ContentExport do
  @moduledoc """
  The rows of a content-list download (`KilnCMSWeb.ContentExportController`).

  A `plan` says what to read: the types, the list's filters (already checked
  by `Filters.parse/2`), the field columns and the actor. `stream/1` reads it
  as keyset pages of at most 100 rows, one type after the next, and yields
  `{descriptor, records, labels}` per page; `csv_rows/4` and `json_rows/4`
  turn a page into text.

  Every read goes through the actor's own policies (`actor:` and `tenant:`),
  the select is explicit (only the columns an export writes), and reference
  labels are looked up once per page by `FieldCells`, which never prints a
  target the actor cannot read.

  Two limits are enforced INSIDE the stream, because the count that precedes
  it is not atomic with it: `ListScope.export_cap/0` rows, and a time limit
  (`config :kiln_cms, :content_export, time_limit_ms: 60_000`). Over either,
  the stream raises `AbortedError` rather than ending: a download that stopped
  quietly would look like a complete one.
  """
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMSWeb.CSV
  alias KilnCMSWeb.EditorLive.FieldCells
  alias KilnCMSWeb.EditorLive.Filters
  alias KilnCMSWeb.EditorLive.ListScope

  # The primary read's `max_page_size`.
  @page_size 100
  @time_limit_ms 60_000

  # Always written, in this order. `published_at` is read (not written): the
  # "last published" sort's keyset needs it.
  @fixed ~w(id type title slug status locale updated_at)
  @select [:id, :title, :slug, :state, :locale, :updated_at, :published_at]

  defmodule AbortedError do
    @moduledoc "An export stopped part-way: it is unusable and must not look finished."
    defexception [:reason]

    @impl true
    def message(%{reason: reason}), do: "content export aborted: #{reason}"
  end

  @type plan :: %{
          actor: map(),
          org: term(),
          types: [map()],
          filters: map(),
          extra: keyword(),
          columns: [struct()],
          options: [struct()]
        }

  @doc "The fixed column names every export starts with."
  @spec fixed_columns() :: [String.t()]
  def fixed_columns, do: @fixed

  @doc "The time limit of one export, in milliseconds."
  @spec time_limit_ms() :: non_neg_integer()
  def time_limit_ms do
    :kiln_cms
    |> Application.get_env(:content_export, [])
    |> Keyword.get(:time_limit_ms, @time_limit_ms)
  end

  @doc """
  The header of a CSV export: the fixed columns, then each field column by its
  field `name`. A field named like a fixed column is headed `fields.<name>` so
  two columns never share a header.
  """
  @spec header(plan()) :: [String.t()]
  def header(%{columns: columns}) do
    @fixed ++
      Enum.map(columns, fn %{name: name} ->
        if name in @fixed, do: "fields." <> name, else: name
      end)
  end

  @doc "The pages of `plan` as `{descriptor, records, labels}`, read lazily."
  @spec stream(plan()) :: Enumerable.t()
  def stream(plan) do
    deadline = System.monotonic_time(:millisecond) + time_limit_ms()
    start = %{queue: plan.types, current: nil, cursor: nil, labels: FieldCells.empty(), seen: 0}

    Stream.resource(fn -> start end, &next(&1, plan, deadline), fn _ -> :ok end)
  end

  defp next(%{current: nil, queue: []} = state, _plan, _deadline), do: {:halt, state}

  defp next(%{current: nil, queue: [descriptor | rest]} = state, plan, deadline),
    do: next(%{state | current: descriptor, queue: rest, cursor: nil}, plan, deadline)

  defp next(state, plan, deadline) do
    if System.monotonic_time(:millisecond) > deadline,
      do: raise(AbortedError, reason: "time limit")

    descriptor = state.current
    page = read_page(descriptor, state.cursor, plan)
    records = page.results
    seen = state.seen + length(records)

    if seen > ListScope.export_cap(), do: raise(AbortedError, reason: "row limit")

    # Reference labels are looked up afresh for each page; only the roster of
    # people is carried over, so it is read once.
    labels =
      FieldCells.labels(
        %{state.labels | refs: %{}},
        Enum.map(records, &{descriptor.type, &1}),
        plan.columns,
        plan.actor,
        plan.org
      )

    cursor = if page.more? and records != [], do: List.last(records).__metadata__.keyset

    state = %{state | cursor: cursor, labels: labels, seen: seen}
    state = if cursor, do: state, else: %{state | current: nil}

    {[{descriptor, records, labels}], state}
  end

  # `plan` is a map of already-validated Ash options, never SQL text; the read
  # goes through the content-type code interface.
  # sobelow_skip ["SQL.Query"]
  defp read_page(descriptor, cursor, plan) do
    page_opts = if cursor, do: [limit: @page_size, after: cursor], else: [limit: @page_size]

    ContentTypes.list!(descriptor,
      actor: plan.actor,
      tenant: plan.org,
      query: query(plan),
      page: page_opts,
      arguments: Filters.field_arguments(plan.filters, plan.options)
    )
  end

  defp query(plan) do
    select = if plan.columns == [], do: @select, else: @select ++ [:custom_fields]

    Filters.query_filters(plan.filters, plan.actor.id) ++
      plan.extra ++ [select: select, sort: Filters.sort(plan.filters)]
  end

  @doc "A page as CSV text: one CRLF-terminated line per record."
  @spec csv_rows(plan(), map(), [map()], FieldCells.labels()) :: iodata()
  def csv_rows(plan, descriptor, records, labels) do
    for record <- records do
      cells =
        for definition <- plan.columns do
          labels |> FieldCells.value(definition, custom(record)) |> FieldCells.csv_value()
        end

      CSV.line(fixed(descriptor, record) ++ cells)
    end
  end

  @doc "A page as JSON objects (encoded), fixed columns at the top and `fields` typed."
  @spec json_rows(plan(), map(), [map()], FieldCells.labels()) :: [String.t()]
  def json_rows(plan, descriptor, records, labels) do
    for record <- records do
      fields =
        Map.new(plan.columns, fn definition ->
          value = FieldCells.value(labels, definition, custom(record))
          {definition.name, FieldCells.json_value(value, definition)}
        end)

      @fixed
      |> Enum.zip(fixed(descriptor, record))
      |> Map.new()
      |> Map.put("fields", fields)
      |> Jason.encode!()
    end
  end

  defp fixed(descriptor, record) do
    [
      record.id,
      ListScope.type_value(descriptor),
      record.title,
      record.slug,
      record.state && to_string(record.state),
      record.locale,
      record.updated_at && DateTime.to_iso8601(record.updated_at)
    ]
  end

  defp custom(record), do: FieldCells.custom_fields(record) || %{}
end

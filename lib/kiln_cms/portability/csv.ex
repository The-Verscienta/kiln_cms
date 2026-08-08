defmodule KilnCMS.Portability.CSV do
  @moduledoc """
  CSV export/import for **flat** content types (#949) — the format an editor can
  actually round-trip through a spreadsheet.

  The JSON envelope (`KilnCMS.Portability.Export`) is lossless and unreadable;
  CSV is readable and lossy. Which is fine, as long as it refuses the cases
  where the loss would be silent — so this is deliberately narrow:

    * **One type per file.** A CSV has one header row, so a file mixing posts
      and recipes cannot describe both. `--type` is required.
    * **No prose.** A type whose records carry blocks is **refused**, not
      flattened. A rich-text body has no honest column: rendering it to text
      loses the structure, and the editor who then re-imports the file has
      silently deleted their own formatting. `--format json` is the answer for
      those, and the error says so.

  What that leaves is exactly what CSV is good at: a directory listing, a
  product row, a staff entry — an admin-defined type whose fields are scalars,
  edited a hundred rows at a time in a spreadsheet.

  ## Shape

  `title`, `slug`, `locale`, `state`, then one column per `FieldDefinition` in
  its declared `position` order:

      title,slug,locale,state,servings,vegan,difficulty
      Soup,soup,en,published,4,true,easy

  Import goes through `KilnCMS.Portability.Import.run_envelope/2` — the same
  write path, conflict policy, dry run and report as every other import. This
  module only translates between rows and envelope records; it writes nothing.
  """

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMSWeb.CSV, as: Codec

  # Present on every content type, ahead of the type's own fields.
  @fixed ~w(title slug locale state)

  @doc """
  Render `records` (envelope maps, as `Export.run/2` produces) as CSV text for
  `type`.

  Returns `{:error, {:has_blocks, slugs}}` when any record carries a block tree
  — see the moduledoc for why that is refused rather than flattened.
  """
  @spec encode([map()], String.t() | atom(), keyword()) ::
          {:ok, String.t()} | {:error, {:has_blocks, [String.t()]}}
  def encode(records, type, opts \\ []) do
    case Enum.filter(records, &has_blocks?/1) do
      [] ->
        columns = @fixed ++ field_names(type, opts)

        rows =
          Enum.map_join(records, fn record ->
            Codec.line(Enum.map(columns, &cell(record, &1)))
          end)

        {:ok, Codec.line(columns) <> rows}

      blocked ->
        {:error, {:has_blocks, Enum.map(blocked, & &1["slug"])}}
    end
  end

  @doc """
  Parse CSV text into envelope records for `type`, ready for
  `KilnCMS.Portability.Import.run_envelope/2`.

  Unknown columns are reported rather than dropped: a header typo (`Slug`,
  `servings ` with a trailing space) would otherwise import every row with that
  field silently empty, which is the failure a spreadsheet round trip is most
  likely to produce and the hardest to notice afterwards.
  """
  @spec decode(String.t(), String.t() | atom(), keyword()) ::
          {:ok, [map()]} | {:error, {:unknown_columns, [String.t()]} | :empty}
  def decode(text, type, opts \\ []) do
    case Codec.parse(text) do
      [] ->
        {:error, :empty}

      [header | rows] ->
        known = @fixed ++ field_names(type, opts)

        case Enum.reject(header, &(&1 in known)) do
          [] -> {:ok, Enum.map(rows, &record(&1, header, type, known))}
          unknown -> {:error, {:unknown_columns, unknown}}
        end
    end
  end

  @doc """
  The `FieldDefinition` names for `type`, in declared order.

  Public because both halves of the CLI need to describe the expected header
  before doing any work — a `--dry-run` that cannot name the columns is not
  much of a preview.
  """
  @spec field_names(String.t() | atom(), keyword()) :: [String.t()]
  def field_names(type, opts \\ []) do
    case ContentTypes.get(type, org_id(opts)) do
      %{source: :dynamic, definition: definition} ->
        definition_fields(definition, opts)

      # A compiled type has no `FieldDefinition`s of its own — its custom fields
      # are keyed by `content_type` instead — and it is not what this format is
      # for. The fixed columns still round-trip.
      _other ->
        []
    end
  rescue
    _error -> []
  end

  defp definition_fields(definition, opts) do
    CMS.list_field_definitions!(
      Keyword.take(opts, [:actor, :tenant]) ++
        [
          query: [
            filter: [type_definition_id: definition.id],
            sort: [position: :asc, name: :asc]
          ]
        ]
    )
    |> Enum.map(& &1.name)
  end

  # ── Rows ───────────────────────────────────────────────────────────────────

  defp record(row, header, type, known) do
    values = header |> Enum.zip(row) |> Map.new()

    custom =
      known
      |> Enum.reject(&(&1 in @fixed))
      |> Enum.map(&{&1, Map.get(values, &1)})
      |> Enum.reject(fn {_name, value} -> value in [nil, ""] end)
      |> Map.new()

    %{
      "type" => to_string(type),
      "title" => Map.get(values, "title"),
      "slug" => presence(Map.get(values, "slug")),
      "locale" => presence(Map.get(values, "locale")),
      "state" => presence(Map.get(values, "state")) || "draft",
      "custom_fields" => custom
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp cell(record, column) when column in @fixed, do: Map.get(record, column)
  defp cell(record, column), do: record |> Map.get("custom_fields", %{}) |> Map.get(column)

  defp has_blocks?(record), do: record |> Map.get("blocks", []) |> List.wrap() |> Enum.any?()

  defp org_id(opts), do: KilnCMS.Accounts.org_id(Keyword.get(opts, :tenant))

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value), do: value
end

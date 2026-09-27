defmodule KilnCMS.CMS.BlockBackfill do
  @moduledoc """
  Rewrites every stored block tree still held in a legacy shape to the typed
  `KilnCMS.CMS.BlockUnion` shape at rest (#1537).

  Run by `mix kiln.blocks.backfill` and, in a release (which has no Mix), by
  `KilnCMS.Release.backfill_blocks/1`.

  ## Why there is anything to backfill

  `blocks` has been `{:array, KilnCMS.CMS.BlockUnion}` since the storage flip,
  but the flip shipped with no data migration: `BlockUnion`'s cast is
  legacy-tolerant, so a row nobody has saved since still holds the old
  `KilnCMS.CMS.Block` maps and is converted on **every read**. This pass does
  that conversion once, on disk, so the tolerant read path can be retired at
  1.0 without anything left depending on it.

  ## What counts as legacy

  Per stored element of every `{:array, BlockUnion}` column (`blocks` and
  `working_blocks` on every content resource — pages, posts, dynamic entries
  and every overlay type):

    * `:legacy_block` — a pre-flip `KilnCMS.CMS.Block` map (`"type"`,
      `"content"`, `"data"`), converted through the same mapping every read
      uses (`KilnCMS.CMS.TypedBlocks`).
    * `:parked_custom` — a legacy block whose `type` has no typed block. It is
      kept whole as a `custom` block carrying `legacy_type`, which is what every
      read already made of it; reported so the operator knows it is there.
    * `:typed_map` — a bare `_type`-tagged map outside the union's stored
      `{"type", "value"}` envelope.
    * `:stale_version` — a block whose `_version` is behind its module's head.
      The declared `migrate` chain runs (`KilnCMS.Blocks.Upcaster`), exactly as
      it does lazily on read.
    * `:legacy_child` — any of the above inside a `columns` block's children,
      which the union never casts.
    * `:legacy_html_converted` — a `rich_text` block whose prose only lived in
      the transitional `legacy_html`, converted to Portable Text `body` when the
      conversion is faithful (`KilnCMS.Blocks.PortableText.from_html_faithful/1`).

  A row is written only when its re-encoded tree differs from what is stored,
  so a second run over a finished database writes nothing.

  ## What it refuses to do

  It never drops content to make a row fit. A row is **reported, not written**
  when any element:

    * would lose data on conversion (`:lossy` — a legacy `data` key, `content`
      or `children` the typed block has nowhere to keep, found by running the
      legacy mapping in `KilnCMS.CMS.TypedBlocks` both ways), or a typed map
      carries fields its block does not declare;
    * names a block type this build does not have (`:unknown_type` — typically a
      plugin that has since been removed);
    * is behind a gap in its block's `migrate` chain (`:missing_migration`,
      #1642) — `KilnCMS.Blocks.Upcaster.try_upcast/2` refuses it rather than
      stamp never-migrated data current, and the backfill does not write it
      either;
    * fails the union's stored cast (`:invalid`), or is not a block at all
      (`:unrecognized`).

  A `rich_text` block whose `legacy_html` would **not** survive conversion to
  Portable Text (`:legacy_html_kept` — marks inside a code block, a list inside
  a quote, text that would come out different) keeps its
  `legacy_html` and is reported. The rest of its row is still rewritten.

  ## How it writes

  Straight to the table through Ecto, not through an Ash action, for the
  reason `KilnCMS.Keys.Reencrypt` gives: this changes how a value is stored,
  not what it is, so no change, notifier, paper trail, cache bust or
  `updated_at` should see it — and it crosses every tenant. It also has to:
  Ash elides a write whose new value compares equal to the loaded one, and a
  legacy row *loads* as the typed tree it would be rewritten to, so an
  update action would silently write nothing.

  Every write is a compare-and-swap on the whole column value (`WHERE id = $1
  AND blocks = $2`). A row an editor saved between the read and the write is
  left alone and counted as `:conflicts` — that save already wrote the typed
  shape, and a re-run picks up anything else.

  Paging is an `id > cursor` keyset in batches, so the pass is resumable and
  safe to interrupt: an interrupted run's rewritten rows read as canonical to
  the next one.

  ## What it leaves alone

  Version history. Each `*_versions` row's `changes` snapshot is folded into
  the per-document governance hash chain (`KilnCMS.Governance.Chain`), so
  rewriting one would break verification of every anchor after it. History is
  read through `KilnCMS.CMS.TypedBlocks.to_typed/1`, which keeps reading the
  legacy shape, and a restore writes through the ordinary cast.

  The editor's crash-recovery `draft_snapshot`, likewise: it holds form
  params, not stored blocks, and any save clears it.
  """

  import Ecto.Query, only: [from: 2]

  alias KilnCMS.Blocks
  alias KilnCMS.Blocks.PortableText
  alias KilnCMS.Blocks.Upcaster
  alias KilnCMS.CMS.BlockUnion
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.TypedBlocks

  @batch 200
  @block_type {:array, BlockUnion}

  @typedoc "One element-level observation, addressed like `blocks[2].columns[0].blocks[1]`."
  @type note :: %{path: String.t(), kind: atom(), detail: String.t() | nil}

  @typedoc "What `convert/2` makes of one stored column value."
  @type conversion ::
          {:canonical, [note()]}
          | {:rewrite, [map()], [note()]}
          | {:error, [note()], [note()]}

  @typedoc "A row that needs an operator: its address and what was found."
  @type finding :: %{
          id: String.t(),
          org_id: String.t() | nil,
          notes: [note()]
        }

  @typedoc "What one run did to one column of one table."
  @type column_report :: %{
          resource: module(),
          table: String.t(),
          column: String.t(),
          scanned: non_neg_integer(),
          canonical: non_neg_integer(),
          rewritten: non_neg_integer(),
          conflicts: non_neg_integer(),
          kinds: %{atom() => non_neg_integer()},
          unconvertible: [finding()],
          attention: [finding()]
        }

  # Note kinds that stop a row being written.
  @refusals [:lossy, :unknown_type, :missing_migration, :invalid, :unrecognized]
  # Note kinds that leave a row writable but need an operator.
  @attention [:legacy_html_kept, :parked_custom]

  # ── the walk ────────────────────────────────────────────────────────────────

  @doc """
  Every table holding a block tree: each AshPostgres resource of a configured
  domain (`:ash_domains` and `:content_domains`, so overlay types count) with
  at least one `{:array, KilnCMS.CMS.BlockUnion}` attribute, and those
  attributes' columns.

  Discovered from the attribute type rather than listed, so a content type an
  overlay adds — or a future block-tree column — is covered without an edit
  here.
  """
  @spec targets() :: [map()]
  def targets do
    domains =
      Enum.uniq(
        Application.get_env(:kiln_cms, :ash_domains, []) ++ ContentTypes.content_domains()
      )

    domains
    |> Enum.flat_map(&Ash.Domain.Info.resources/1)
    |> Enum.uniq()
    |> Enum.filter(&(Ash.DataLayer.data_layer(&1) == AshPostgres.DataLayer))
    |> Enum.flat_map(&target/1)
    |> Enum.sort_by(& &1.table)
  end

  defp target(resource) do
    case for(%{type: @block_type} = attr <- Ash.Resource.Info.attributes(resource), do: attr) do
      [] ->
        []

      attributes ->
        [
          %{
            resource: resource,
            table: AshPostgres.DataLayer.Info.table(resource),
            prefix: AshPostgres.DataLayer.Info.schema(resource),
            pk: primary_key!(resource),
            org: org_column(resource),
            columns: Enum.map(attributes, & &1.source)
          }
        ]
    end
  end

  defp primary_key!(resource) do
    case Ash.Resource.Info.primary_key(resource) do
      [key] ->
        Ash.Resource.Info.attribute(resource, key).source

      keys ->
        raise ArgumentError,
              "#{inspect(resource)} has a composite primary key #{inspect(keys)}; " <>
                "the block backfill expects a single key column"
    end
  end

  defp org_column(resource) do
    case Ash.Resource.Info.attribute(resource, :org_id) do
      %{source: source} -> source
      nil -> nil
    end
  end

  @doc """
  Walk every target (see `targets/0`).

  Options:

    * `:dry_run` — classify and report, write nothing.
    * `:batch` — rows per page (default #{@batch}).
    * `:tables` — only these table names.
    * `:repo` — defaults to `KilnCMS.Repo`.
  """
  @spec run(keyword()) :: [column_report()]
  def run(opts \\ []) do
    only = Keyword.get(opts, :tables)

    targets()
    |> Enum.filter(&(is_nil(only) or &1.table in only))
    |> Enum.flat_map(&walk(&1, opts))
  end

  @doc """
  `run/1`, printing a summary line per column and every row that needs an
  operator through `puts`. `{:error, message}` when any row could not be
  converted or kept something that has to be looked at, so a script (and
  `mix kiln.blocks.backfill`) exits non-zero; `:ok` otherwise.
  """
  @spec run_and_report(keyword(), (String.t() -> any())) :: :ok | {:error, String.t()}
  def run_and_report(opts, puts) when is_function(puts, 1) do
    reports = run(opts)
    dry_run? = Keyword.get(opts, :dry_run, false)
    Enum.each(format(reports, dry_run?), puts)

    unconvertible = Enum.sum_by(reports, &length(&1.unconvertible))
    attention = Enum.sum_by(reports, &length(&1.attention))

    if unconvertible + attention == 0 do
      :ok
    else
      {:error,
       "#{unconvertible} row(s) could not be converted and #{attention} row(s) need a look; " <>
         "see the list above. Nothing listed as unconvertible was written."}
    end
  end

  @doc false
  @spec format([column_report()], boolean()) :: [String.t()]
  def format(reports, dry_run?) do
    verb = if dry_run?, do: "would be rewritten", else: "rewritten"

    Enum.flat_map(reports, fn r ->
      summary =
        "#{r.table}.#{r.column}: #{r.scanned} scanned, #{r.canonical} already typed, " <>
          "#{r.rewritten} #{verb}, #{r.conflicts} changed underneath (re-run), " <>
          "#{length(r.unconvertible)} unconvertible" <> kinds(r.kinds)

      [summary] ++
        Enum.map(r.unconvertible, &finding_line("unconvertible", r, &1)) ++
        Enum.map(r.attention, &finding_line("needs a look", r, &1))
    end)
  end

  defp kinds(kinds) when map_size(kinds) == 0, do: ""

  defp kinds(kinds) do
    " (" <> Enum.map_join(Enum.sort(kinds), ", ", fn {kind, n} -> "#{kind}: #{n}" end) <> ")"
  end

  defp finding_line(label, report, finding) do
    notes =
      finding.notes
      |> Enum.filter(&(&1.kind in @refusals or &1.kind in @attention))
      |> Enum.map_join("; ", fn note ->
        "#{note.path} #{note.kind}" <> if(note.detail, do: " (#{note.detail})", else: "")
      end)

    org = if finding.org_id, do: " org=#{finding.org_id}", else: ""
    "  #{label}: #{report.table}.#{report.column} id=#{finding.id}#{org} — #{notes}"
  end

  defp walk(target, opts) do
    repo = Keyword.get(opts, :repo, KilnCMS.Repo)
    batch = Keyword.get(opts, :batch, @batch)
    dry_run? = Keyword.get(opts, :dry_run, false)

    empty = Map.new(target.columns, &{&1, empty_report(target, &1)})

    nil
    |> Stream.unfold(fn
      :done ->
        nil

      cursor ->
        case page(repo, target, cursor, batch) do
          [] -> nil
          rows when length(rows) < batch -> {rows, :done}
          rows -> {rows, List.last(rows).id}
        end
    end)
    |> Enum.reduce(empty, fn rows, acc ->
      Enum.reduce(rows, acc, &visit_row(repo, target, dry_run?, &1, &2))
    end)
    |> Map.values()
    |> Enum.map(fn report ->
      %{
        report
        | unconvertible: Enum.reverse(report.unconvertible),
          attention: Enum.reverse(report.attention)
      }
    end)
    |> Enum.sort_by(& &1.column)
  end

  defp empty_report(target, column) do
    %{
      resource: target.resource,
      table: target.table,
      column: to_string(column),
      scanned: 0,
      canonical: 0,
      rewritten: 0,
      conflicts: 0,
      kinds: %{},
      unconvertible: [],
      attention: []
    }
  end

  defp page(repo, target, cursor, batch) do
    pk = target.pk
    fields = Enum.reject([target.org | target.columns], &is_nil/1)

    query =
      from(r in target.table,
        order_by: [asc: field(r, ^pk)],
        limit: ^batch,
        select: %{id: type(field(r, ^pk), Ecto.UUID), row: map(r, ^fields)}
      )

    query =
      case cursor do
        nil -> query
        cursor -> from(r in query, where: field(r, ^pk) > type(^cursor, Ecto.UUID))
      end

    query
    |> repo.all(prefix: target.prefix)
    |> Enum.map(fn %{id: id, row: row} ->
      %{id: id, org_id: org_id(row, target.org), values: Map.take(row, target.columns)}
    end)
  end

  defp org_id(_row, nil), do: nil
  defp org_id(row, column), do: row |> Map.get(column) |> uuid_string()

  defp uuid_string(<<_::128>> = raw), do: Ecto.UUID.load!(raw)
  defp uuid_string(other), do: other

  defp visit_row(repo, target, dry_run?, row, acc) do
    Enum.reduce(target.columns, acc, fn column, acc ->
      Map.update!(
        acc,
        column,
        &visit_column(&1, repo, target, dry_run?, row, column, Map.fetch!(row.values, column))
      )
    end)
  end

  defp visit_column(report, _repo, _target, _dry_run?, _row, _column, nil),
    do: %{report | scanned: report.scanned + 1, canonical: report.canonical + 1}

  defp visit_column(report, repo, target, dry_run?, row, column, stored) do
    report = %{report | scanned: report.scanned + 1}

    case safe_convert(stored, to_string(column)) do
      {:canonical, notes} ->
        report |> tally(notes) |> attention(row, notes) |> Map.update!(:canonical, &(&1 + 1))

      {:rewrite, rewritten, notes} ->
        report = report |> tally(notes) |> attention(row, notes)

        cond do
          dry_run? ->
            Map.update!(report, :rewritten, &(&1 + 1))

          write(repo, target, row.id, column, stored, rewritten) ->
            Map.update!(report, :rewritten, &(&1 + 1))

          true ->
            Map.update!(report, :conflicts, &(&1 + 1))
        end

      {:error, refusals, notes} ->
        finding = %{id: row.id, org_id: row.org_id, notes: refusals ++ notes}
        report |> tally(refusals ++ notes) |> Map.update!(:unconvertible, &[finding | &1])
    end
  end

  # One row the conversion code cannot cope with — a shape nobody foresaw —
  # is that row's problem, not the pass's: it is reported like any other
  # refusal, and the walk carries on to the rows after it.
  defp safe_convert(stored, column) do
    convert(stored, column)
  rescue
    exception ->
      {:error, [note(column, :invalid, "raised " <> Exception.message(exception))], []}
  end

  defp tally(report, notes) do
    kinds = Enum.reduce(notes, report.kinds, &Map.update(&2, &1.kind, 1, fn n -> n + 1 end))
    %{report | kinds: kinds}
  end

  defp attention(report, row, notes) do
    case Enum.filter(notes, &(&1.kind in @attention)) do
      [] ->
        report

      flagged ->
        Map.update!(report, :attention, &[%{id: row.id, org_id: row.org_id, notes: flagged} | &1])
    end
  end

  @doc false
  # Compare-and-swap on the whole stored value: jsonb equality is semantic
  # (key order and whitespace do not matter), so this matches exactly when
  # nobody wrote the column since `page/4` read it. `false` when somebody did.
  # Public for the test that proves a concurrent save is never overwritten.
  @spec write(Ecto.Repo.t(), map(), String.t(), atom(), [map()], [map()]) :: boolean()
  def write(repo, target, id, column, stored, rewritten) do
    query =
      from(r in target.table,
        where:
          field(r, ^target.pk) == type(^id, Ecto.UUID) and
            field(r, ^column) == type(^stored, {:array, :map})
      )

    case repo.update_all(query, [set: [{column, rewritten}]], prefix: target.prefix) do
      {1, _} -> true
      {0, _} -> false
    end
  end

  # ── one column value ────────────────────────────────────────────────────────

  @doc """
  What one stored column value (the raw decoded `jsonb[]`: a list of
  string-keyed maps) should become. Pure — no database — so the corpus can be
  run through it directly.

    * `{:canonical, notes}` — already the typed shape at rest; nothing to write.
      `notes` can still hold `:legacy_html_kept`.
    * `{:rewrite, value, notes}` — `value` is the list to store.
    * `{:error, refusals, notes}` — not convertible without losing something;
      `refusals` say what and where.

  `column` only prefixes the paths in the notes.
  """
  @spec convert([map()] | term(), String.t()) :: conversion()
  def convert(stored, column \\ "blocks")

  def convert(stored, column) when is_list(stored) do
    {inputs, notes} =
      stored
      |> Enum.with_index()
      |> Enum.map_reduce([], fn {element, index}, notes ->
        {input, element_notes} = prepare_top(element, "#{column}[#{index}]")
        {input, notes ++ element_notes}
      end)

    case Enum.split_with(notes, &(&1.kind in @refusals)) do
      {[], notes} -> encode(stored, inputs, notes, column)
      {refusals, notes} -> {:error, refusals, notes}
    end
  end

  def convert(_stored, column),
    do: {:error, [note(column, :unrecognized, "not a list of blocks")], []}

  defp encode(stored, inputs, notes, column) do
    with {:ok, constraints} <- Ash.Type.init(@block_type, []),
         {:ok, cast} <- Ash.Type.cast_stored(@block_type, inputs, constraints),
         {:ok, dumped} <- Ash.Type.dump_to_native(@block_type, cast, constraints) do
      rewritten = normalize(dumped)

      if rewritten == normalize(stored),
        do: {:canonical, notes},
        else: {:rewrite, rewritten, notes}
    else
      error ->
        {:error, [note(column, :invalid, inspect_error(error))], notes}
    end
  end

  # What Postgres will hand back: JSON-shaped, string keys throughout.
  defp normalize(value), do: value |> Jason.encode!() |> Jason.decode!()

  defp inspect_error({:error, error}) when is_exception(error), do: Exception.message(error)
  defp inspect_error({:error, error}), do: inspect(error, limit: 5)
  defp inspect_error(other), do: inspect(other, limit: 5)

  # A top-level element: the union's stored envelope, or one of the shapes the
  # tolerant read converts. Returns the typed input map for the stored cast.
  defp prepare_top(%{"type" => type, "value" => %{} = value} = element, path)
       when map_size(element) == 2 and is_binary(type) do
    prepare_typed(Map.put_new(value, "_type", type), path, [])
  end

  defp prepare_top(element, path), do: prepare_any(element, path)

  # Anything that is not the envelope: a bare typed map or a legacy block.
  # Also what a `columns` child is — children are stored as bare typed maps.
  defp prepare_any(%{"_type" => type} = map, path) when is_binary(type),
    do: prepare_typed(map, path, [note(path, :typed_map)])

  defp prepare_any(%{"type" => type} = map, path) when is_binary(type),
    do: prepare_legacy(map, path)

  defp prepare_any(other, path),
    do: {other, [note(path, :unrecognized, "not a block: #{inspect(other, limit: 3)}")]}

  defp prepare_legacy(map, path) do
    case TypedBlocks.legacy_loss(map) do
      [] ->
        [typed] = TypedBlocks.to_typed([map])
        parked = parked_note(typed, map, path)
        prepare_typed(TypedBlocks.input_map(typed), path, [note(path, :legacy_block) | parked])

      lost ->
        {map, [note(path, :lossy, Enum.join(lost, ", "))]}
    end
  end

  defp parked_note(%Blocks.Custom{legacy_type: legacy}, map, path)
       when legacy not in [nil, "custom"] do
    [note(path, :parked_custom, "legacy type #{inspect(Map.get(map, "type"))}")]
  end

  defp parked_note(_typed, _map, _path), do: []

  # A `_type`-tagged map, whatever it came out of: upcast to head, check every
  # key has somewhere to go, convert faithful `legacy_html`, recurse children.
  defp prepare_typed(map, path, notes) do
    case Blocks.module_for_tagged_map(map) do
      nil ->
        {map, notes ++ [note(path, :unknown_type, "no block type #{inspect(map["_type"])}")]}

      module ->
        case Upcaster.try_upcast_block_map(map) do
          {:ok, upcast} ->
            prepare_upcast(
              map,
              upcast,
              module,
              path,
              notes ++ version_note(map, upcast, module, path)
            )

          {:error, refusal} ->
            {map, notes ++ [note(path, :missing_migration, refusal.detail)]}
        end
    end
  end

  defp prepare_upcast(map, upcast, module, path, notes) do
    case foreign_keys(module, upcast) do
      [] ->
        {upcast, text_notes} = prepare_rich_text(upcast, module, path)
        {upcast, child_notes} = prepare_children(upcast, module, path)
        {upcast, notes ++ text_notes ++ child_notes}

      keys ->
        {map, notes ++ [note(path, :lossy, "undeclared field(s) " <> Enum.join(keys, ", "))]}
    end
  end

  defp version_note(before, upcast, module, path) do
    from = Map.get(before, "_version") || 1

    if from < Upcaster.current_version(module) and Map.get(upcast, "_version") != from,
      do: [note(path, :stale_version, "v#{from} → v#{Map.get(upcast, "_version")}")],
      else: []
  end

  defp foreign_keys(module, map) do
    declared = module |> Ash.Resource.Info.attributes() |> Enum.map(&to_string(&1.name))

    for {key, value} <- map, to_string(key) not in declared, value not in [nil, "", [], %{}] do
      to_string(key)
    end
  end

  # ── rich text: legacy_html → Portable Text, only when faithful ─────────────

  defp prepare_rich_text(%{"legacy_html" => html} = map, Blocks.RichText, path)
       when is_binary(html) do
    cond do
      String.trim(html) == "" ->
        {Map.delete(map, "legacy_html"), []}

      body_present?(map) ->
        # Portable Text already wins on every read; the stale copy goes.
        {Map.delete(map, "legacy_html"), []}

      true ->
        case PortableText.from_html_faithful(html) do
          {:ok, body} ->
            converted = map |> Map.delete("legacy_html") |> Map.put("body", body)
            {converted, [note(path, :legacy_html_converted)]}

          {:error, reason} ->
            {map, [note(path, :legacy_html_kept, reason)]}
        end
    end
  end

  defp prepare_rich_text(map, _module, _path), do: {map, []}

  defp body_present?(map), do: match?([_ | _], Map.get(map, "body"))

  # ── columns children ────────────────────────────────────────────────────────

  defp prepare_children(%{"columns" => cols} = map, Blocks.Columns, path) when is_list(cols) do
    {cols, notes} =
      cols
      |> Enum.with_index()
      |> Enum.map_reduce([], fn
        {%{} = col, ci}, notes ->
          {children, child_notes} = prepare_column(col, "#{path}.columns[#{ci}]")
          {Map.put(col, "blocks", children), notes ++ child_notes}

        {other, _ci}, notes ->
          {other, notes}
      end)

    {Map.put(map, "columns", cols), notes}
  end

  defp prepare_children(map, _module, _path), do: {map, []}

  # A child is stored as the bare typed map the write path's
  # `sanitize_children` leaves, so that shape is canonical here and only the
  # other ones are noted. A legacy child converts to the same bare map, with no
  # `nil`s and no id it did not have (`TypedBlocks.input_map/1`).
  defp prepare_column(col, path) do
    col
    |> Map.get("blocks", [])
    |> List.wrap()
    |> Enum.with_index()
    |> Enum.map_reduce([], fn {child, bi}, notes ->
      {input, child_notes} = prepare_child(child, "#{path}.blocks[#{bi}]")
      {input, notes ++ Enum.map(child_notes, &childish/1)}
    end)
  end

  defp prepare_child(%{"_type" => type} = map, path) when is_binary(type),
    do: prepare_typed(map, path, [])

  defp prepare_child(other, path), do: prepare_any(other, path)

  # Inside a columns block every shape note is a child note, so the summary
  # can say how much of the backlog lives in nested trees. Refusals keep
  # their own kind — they are what stops the row.
  defp childish(%{kind: kind} = note) when kind in [:legacy_block, :typed_map],
    do: %{note | kind: :legacy_child}

  defp childish(note), do: note

  defp note(path, kind, detail \\ nil), do: %{path: path, kind: kind, detail: detail}
end

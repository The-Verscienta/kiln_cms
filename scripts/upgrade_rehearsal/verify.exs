# Holds the candidate to what an upgrade rehearsal seeded at the old release
# (#1540).
#
#   mix run scripts/upgrade_rehearsal/verify.exs before|after MANIFEST_JSON RENDER_JSON
#
# Runs in the candidate's build, after `mix ash.migrate`, with the app booted.
#
# Both phases:
#
#   * no table shrank or disappeared (row counts only grow across an upgrade);
#   * every block-tree row the old release held is still there, with its title
#     and slug, and reads back through Ash with the same number of blocks and
#     the same block ids;
#   * every published page and post renders over HTTP, and the rendered page
#     carries its title and every heading its stored blocks hold.
#
# `before` (ahead of `mix kiln.blocks.backfill`) saves the rendered text;
# `after` also requires:
#
#   * the rendered text of every page is exactly what it was before the
#     backfill — rewriting storage must not change what a reader sees;
#   * every stored tree is canonical, and a dry run finds nothing left to write;
#   * the only rows the backfill left for a person are the corpus entries that
#     are meant to need one.

[phase, manifest_path, render_path] = System.argv()

defmodule Rehearsal.Verify do
  alias KilnCMS.CMS.BlockBackfill

  def q(sql, params \\ []), do: KilnCMS.Repo.query!(sql, params, timeout: :infinity)

  def problems, do: Process.get(:problems, [])
  def problem(message), do: Process.put(:problems, [message | problems()])

  def check_counts(%{"counts" => counts}) do
    for {table, before} <- counts do
      case q(
             "SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = $1",
             [table]
           ).rows do
        [] ->
          problem("table #{table} (#{before} rows at the old release) is gone")

        _ ->
          [[now]] = q(~s[SELECT count(*) FROM "#{table}"]).rows
          if now < before, do: problem("table #{table} shrank: #{before} → #{now} rows")
      end
    end
  end

  def targets_by_table do
    Map.new(BlockBackfill.targets(), &{&1.table, &1})
  end

  def check_rows(%{"rows" => rows}, targets) do
    for row <- rows do
      check_row(row, Map.get(targets, row["table"]))
    end
  end

  defp check_row(%{"table" => table} = row, nil) do
    problem("#{table} #{row["id"]} (#{row["slug"]}): no content type serves #{table} any more")
  end

  defp check_row(%{"table" => table, "id" => id} = row, target) do
    label = "#{table}/#{row["slug"] || id}"

    case q(~s(SELECT title, slug FROM "#{table}" WHERE id::text = $1), [id]).rows do
      [[title, slug]] ->
        if title != row["title"] or slug != row["slug"],
          do: problem("#{label}: title/slug changed to #{inspect({title, slug})}")

      [] ->
        problem("#{label}: row is gone")
    end

    case Ash.get(target.resource, id, authorize?: false, tenant: row["org_id"]) do
      {:ok, record} ->
        check_blocks(label, "blocks", row["blocks"], Map.get(record, :blocks))

        if Map.has_key?(row, "working_blocks") and not is_nil(row["working_blocks"]),
          do:
            check_blocks(
              label,
              "working_blocks",
              row["working_blocks"],
              Map.get(record, :working_blocks)
            )

      {:error, error} ->
        problem("#{label}: does not read back through Ash: #{Exception.message(error)}")
    end
  rescue
    error -> problem("#{row["table"]}/#{row["slug"]}: raised #{Exception.message(error)}")
  end

  defp check_blocks(label, column, stored, read) do
    stored = stored || []
    read = read || []

    if length(stored) != length(read) do
      problem("#{label}.#{column}: #{length(stored)} blocks stored, #{length(read)} read back")
    else
      for {s, r} <- Enum.zip(stored, read), (id = stored_id(s)) != nil do
        read_id = r |> union_value() |> Map.get(:id)

        if read_id != id,
          do: problem("#{label}.#{column}: block #{id} read back as #{inspect(read_id)}")
      end
    end
  end

  defp union_value(%Ash.Union{value: value}), do: value
  defp union_value(value), do: value

  defp stored_id(%{"value" => %{"id" => id}}), do: id
  defp stored_id(%{"id" => id}), do: id
  defp stored_id(_), do: nil

  # Headings are the one block every release renders as plain visible text.
  def headings(blocks) when is_list(blocks), do: Enum.flat_map(blocks, &headings/1)
  def headings(%{"type" => "heading", "content" => text}) when is_binary(text), do: [text]
  def headings(%{"_type" => "heading", "text" => text}) when is_binary(text), do: [text]

  def headings(%{"value" => %{"_type" => "heading", "text" => text}}) when is_binary(text),
    do: [text]

  def headings(_), do: []

  def render_published(%{"rows" => rows}) do
    for %{"status" => "published", "table" => table, "slug" => slug} = row <- rows,
        path = path(table, slug),
        path != nil,
        into: %{} do
      {path, render(path, row)}
    end
  end

  defp path("pages", slug), do: "/#{slug}"
  defp path("posts", slug), do: "/blog/#{slug}"
  defp path(_table, _slug), do: nil

  defp render(path, row) do
    conn =
      Phoenix.ConnTest.build_conn()
      |> Map.put(:host, "localhost")
      |> Phoenix.ConnTest.dispatch(KilnCMSWeb.Endpoint, :get, path)

    if conn.status != 200 do
      problem("GET #{path}: #{conn.status}")
      nil
    else
      doc = Floki.parse_document!(conn.resp_body)
      text = squeeze(Floki.text(doc))

      main =
        case Floki.find(doc, "main") do
          [] -> text
          found -> squeeze(Floki.text(found))
        end

      for expected <- [row["title"] | headings(row["blocks"])],
          not String.contains?(text, squeeze(expected)),
          do: problem("GET #{path}: #{inspect(expected)} is not on the page")

      main
    end
  rescue
    error ->
      problem("GET #{path}: raised #{Exception.message(error)}")
      nil
  end

  defp squeeze(text), do: text |> String.replace(~r/\s+/u, " ") |> String.trim()

  defp bare(nil), do: nil
  defp bare(text), do: String.replace(text, ~r/\s+/u, "")

  # Compared with all whitespace removed, as the backfill's own corpus test
  # compares them: a converted list item or quote renders its paragraph
  # breaks as markup the tolerant read joined without a space, so
  # "first linesecond line" becomes "first line second line" — the same text.
  def compare_renders(before, now) do
    for {path, text} <- before,
        text != nil,
        bare(Map.get(now, path)) != bare(text) do
      problem(
        "GET #{path}: the page reads differently after the backfill\n" <>
          "    before: #{String.slice(text, 0, 400)}\n" <>
          "    after:  #{String.slice(to_string(now[path]), 0, 400)}"
      )
    end
  end

  def check_canonical(%{"rows" => rows}, targets) do
    for %{"table" => table, "id" => id} <- rows,
        target = targets[table],
        target != nil,
        column <- target.columns do
      [[stored]] = q(~s(SELECT "#{column}" FROM "#{table}" WHERE id::text = $1), [id]).rows

      case stored && BlockBackfill.convert(stored, column) do
        nil ->
          :ok

        {:canonical, _notes} ->
          :ok

        {:rewrite, _, notes} ->
          problem("#{table} #{id}.#{column}: still not canonical #{kinds(notes)}")

        {:error, refusals, _} ->
          problem("#{table} #{id}.#{column}: refused #{kinds(refusals)}")
      end
    end
  end

  defp kinds(notes), do: inspect(Enum.map(notes, & &1.kind))

  # The corpus entries that are meant to be left for a person.
  def expected_attention(%{"corpus_pages" => pages}) do
    wanted = [:legacy_html_kept, :parked_custom]
    notes = KilnCMS.LegacyBlockCorpus.expected_notes()

    for %{"id" => id, "corpus" => name} <- pages,
        Enum.any?(Map.get(notes, name, []), &(&1 in wanted)),
        into: MapSet.new(),
        do: id
  end

  def check_dry_run(manifest) do
    reports = BlockBackfill.run(dry_run: true)
    expected = expected_attention(manifest)

    for r <- reports do
      if r.rewritten > 0,
        do: problem("#{r.table}.#{r.column}: #{r.rewritten} rows still to rewrite")

      for f <- r.unconvertible,
          do: problem("#{r.table}.#{r.column}: #{f.id} unconvertible #{kinds(f.notes)}")

      for f <- r.attention,
          not MapSet.member?(expected, f.id),
          do:
            problem(
              "#{r.table}.#{r.column}: #{f.id} unexpectedly needs a person #{kinds(f.notes)}"
            )
    end
  end
end

alias Rehearsal.Verify

manifest = manifest_path |> File.read!() |> JSON.decode!()
targets = Verify.targets_by_table()

Verify.check_counts(manifest)
Verify.check_rows(manifest, targets)
renders = Verify.render_published(manifest)

case phase do
  "before" ->
    File.write!(render_path, JSON.encode!(renders))

  "after" ->
    Verify.compare_renders(render_path |> File.read!() |> JSON.decode!(), renders)
    Verify.check_canonical(manifest, targets)
    Verify.check_dry_run(manifest)
end

rendered = renders |> Map.values() |> Enum.count(&(&1 != nil))

case Enum.reverse(Verify.problems()) do
  [] ->
    IO.puts(
      "verify #{phase}: OK — #{length(manifest["rows"])} block-tree rows read back, " <>
        "#{rendered} published pages rendered"
    )

  problems ->
    Enum.each(problems, &IO.puts("verify #{phase}: #{&1}"))
    IO.puts("verify #{phase}: #{length(problems)} problem(s)")
    System.halt(1)
end

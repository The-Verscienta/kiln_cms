defmodule KilnCMS.Docs.EnvVarTiersTest do
  @moduledoc """
  `docs/environment-variables.md` and `.env.example` present the same variables
  in the same three tiers — Required (3), Common (10), Everything else (#1322).

  The document is ~130 variables across 28 feature sections, and the complaint
  that produced the tiers was that nothing told a new operator which handful
  actually mattered. That only stays true while three things hold, and each has
  its own way of quietly becoming false:

    * **Required means "refuses to boot".** Not "you should set this" — the
      previous section mixed the two, listing `PHX_HOST` and `PHX_SERVER`
      alongside the three that raise, so "required" stopped meaning anything
      checkable. Here it is derived from the source.
    * **The two files agree.** They are edited by different reflexes — a new
      variable goes in whichever one you had open — and a `.env.example` that
      recommends a different ten than the document is worse than no list.
    * **Common is a signpost, not a second definition.** Each row must point at
      a real detail row elsewhere in the document, or the short list becomes the
      only documentation for those ten and drifts from the full one.
  """
  use ExUnit.Case, async: true

  @doc_path "docs/environment-variables.md"
  @env_example ".env.example"

  # The three that raise on a :prod boot with nothing else set. Pinned as a
  # literal AND checked against the config source below, so this list cannot
  # simply be edited to match a regression.
  @required ~w(DATABASE_URL SECRET_KEY_BASE TOKEN_SIGNING_SECRET)

  defp doc_lines, do: @doc_path |> File.read!() |> String.split("\n")

  # Rows under one `##`/`###` heading, by the variable each names.
  defp rows_under(heading) do
    doc_lines()
    |> Enum.reduce({nil, []}, fn line, {section, acc} ->
      cond do
        String.starts_with?(line, "## ") -> {String.trim(String.slice(line, 3..-1//1)), acc}
        String.starts_with?(line, "### ") -> {String.trim(String.slice(line, 4..-1//1)), acc}
        true -> {section, collect_row(section, heading, line, acc)}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp collect_row(section, heading, line, acc) when section == heading do
    case Regex.run(~r/^\|\s*`([A-Z0-9_]+)`\s*\|/, line) do
      [_, var] -> [var | acc]
      _ -> acc
    end
  end

  defp collect_row(_section, _heading, _line, acc), do: acc

  test "Required (3) lists exactly the variables that raise on a production boot" do
    assert rows_under("Required (3)") == @required
  end

  test "and those are the only unconditional raises in the runtime config" do
    # The guard on the list above: derived from the source, so a fourth
    # unconditional raise added to a fragment fails here rather than silently
    # making the document's headline number wrong.
    #
    # "Unconditional" means at the top level of a prod fragment — not nested
    # inside an `if`/`case` that some other variable opts into (S3, SMTP).
    # Indentation is the tell, and these files are `mix format`ed.
    raising =
      for path <- Path.wildcard("config/runtime/**/*.exs") ++ ["config/runtime.exs"],
          {line, _n} <- Enum.with_index(File.read!(path) |> String.split("\n"), 1),
          Regex.match?(~r/^\s{0,2}(raise|.*\|\|$)/, line) or
            String.contains?(line, "System.fetch_env!"),
          var <- Regex.scan(~r/\b([A-Z][A-Z0-9_]{3,})\b/, line) |> Enum.map(&Enum.at(&1, 1)),
          var in @required,
          uniq: true,
          do: var

    assert Enum.sort(raising) == Enum.sort(@required),
           """
           The three required variables should each still be read on a line that \
           raises without them. Found: #{inspect(Enum.sort(raising))}.
           """
  end

  test "Common (10) has ten rows, and .env.example indexes the same ten in the same order" do
    common = rows_under("Common (10)")

    assert length(common) == 10,
           "The heading says ten; the table has #{length(common)}. Change both or neither."

    from_env =
      @env_example
      |> File.read!()
      |> String.split("# Common (10)", parts: 2)
      |> List.last()
      |> String.split("# Everything else", parts: 2)
      |> List.first()
      |> String.split("\n")
      |> Enum.flat_map(fn line ->
        case Regex.run(~r/^#   ([A-Z][A-Z0-9_]+)\s/, line) do
          [_, var] -> [var]
          _ -> []
        end
      end)

    assert from_env == common,
           """
           .env.example's Common index and #{@doc_path}'s Common (10) table have \
           drifted. They are the first thing a new operator reads in either file, \
           so they must name the same variables in the same order.

             #{@doc_path}: #{inspect(common)}
             #{@env_example}: #{inspect(from_env)}
           """
  end

  test "every Common row points at a detail row elsewhere in the document" do
    # Otherwise the short list silently becomes the only documentation for those
    # ten, with no default column and no source anchor.
    common = rows_under("Common (10)")

    documented =
      for line <- doc_lines(),
          [_, var] <- [Regex.run(~r/^\|\s*`([A-Z0-9_]+)`\s*\|.*#L\d+\)/, line) || []],
          into: MapSet.new(),
          do: var

    missing = Enum.reject(common, &MapSet.member?(documented, &1))

    assert missing == [],
           """
           These Common (10) variables have no detailed row (one with a source \
           anchor) anywhere else in #{@doc_path}: #{inspect(missing)}. The Common \
           table is a signpost — it links to the real row rather than replacing it.\
           """
  end
end

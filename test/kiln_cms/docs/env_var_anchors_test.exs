defmodule KilnCMS.Docs.EnvVarAnchorsTest do
  @moduledoc """
  Every `config/runtime.exs` line anchor in `docs/environment-variables.md`
  points at the line that actually reads that variable.

  That document cites its source by **line number** —
  `[config/runtime.exs:601](../config/runtime.exs#L601)` — for every variable it
  lists. Any insertion into `runtime.exs` shifts every anchor below it at once,
  and nothing else checks them: `mix docs --warnings-as-errors` verifies
  cross-references between docs and *modules*, not line offsets into source.

  So they rot silently, and have repeatedly: 42 of 47 were wrong when #610 was
  filed, 56 of ~70 on a later re-check, and the same PR that first re-pointed
  them broke them again with one more twelve-line edit before commit. The
  failure mode is always the same — correct when written, correct when the
  tests passed, wrong by the time it merged.

  This is the check that makes that impossible rather than merely regrettable.
  Run `mix test #{Path.relative_to_cwd(__ENV__.file)}` after touching
  `runtime.exs`; the fix is to re-point the rows, not to relax the test.

  Tracked as #610, #645 and #657 — three issues for one drift, which is itself
  a symptom of it recurring.
  """
  use ExUnit.Case, async: true

  @doc_path "docs/environment-variables.md"

  # A table row naming a variable, e.g. "| `TENANT_STRICT_HOST` | ..."
  @row ~r/^\|\s*`([A-Z0-9_]+)`\s*\|/

  # "[`config/runtime.exs:601`](../config/runtime.exs#L601)" — the label and the
  # link fragment are separate numbers and can disagree, so both are captured.
  @anchor ~r/\[`([^`]+):(\d+)`\]\(\.\.\/([^)#]+)#L(\d+)\)/

  test "every anchor resolves to a line that mentions its variable" do
    problems =
      @doc_path
      |> File.read!()
      |> String.split("\n")
      |> Enum.flat_map(&check_row/1)

    assert problems == [],
           """
           These anchors in #{@doc_path} do not point at the line that reads the
           variable:

           #{Enum.map_join(problems, "\n", &"  - #{&1}")}

           An insertion into the source file shifts every anchor below it. Re-point
           the rows against the current source — see the moduledoc.
           """
  end

  test "the check can fail" do
    # Otherwise a regex that stopped matching would pass the test above forever,
    # which is precisely how the anchors rotted unnoticed in the first place.
    assert [_ | _] =
             check_row(
               "| `PHX_HOST` | x | y | [`config/runtime.exs:1`](../config/runtime.exs#L1) |"
             )

    assert [] = check_row("| not a variable row | at all |")
  end

  defp check_row(line) do
    case Regex.run(@row, line) do
      [_, var] -> line |> then(&Regex.scan(@anchor, &1)) |> Enum.flat_map(&check_anchor(var, &1))
      _ -> []
    end
  end

  defp check_anchor(var, [_full, _label_path, label_line, path, link_line]) do
    cond do
      label_line != link_line ->
        ["#{var}: label says :#{label_line} but the link points at #L#{link_line}"]

      not File.exists?(path) ->
        ["#{var}: #{path} does not exist"]

      true ->
        check_line(var, path, String.to_integer(link_line))
    end
  end

  defp check_line(var, path, n) do
    source = path |> File.read!() |> String.split("\n")

    case Enum.at(source, n - 1) do
      nil -> ["#{var}: #{path}:#{n} is past the end of the file"]
      text -> if String.contains?(text, var), do: [], else: [miss(var, path, n, text)]
    end
  end

  defp miss(var, path, n, text) do
    "#{var}: #{path}:#{n} reads #{inspect(String.trim(text) |> String.slice(0, 60))}"
  end
end

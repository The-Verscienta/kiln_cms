defmodule KilnCMS.CMS.BlockBackfillCorpusTest do
  @moduledoc """
  The #1537 backfill's conversion (`KilnCMS.CMS.BlockBackfill.convert/2`) run
  over `KilnCMS.LegacyBlockCorpus` — every shape a stored block tree can still
  hold — with no database in the way.

  "Converts" is not enough on its own: the typed tree it writes has to read
  back as what every reader was already being shown. So for each convertible
  entry this compares, block by block, what the tolerant read made of the
  stored value against what the plain read makes of the rewritten one, on the
  two fired surfaces headless readers and delivery see (`:web`, `:json`).
  """
  use ExUnit.Case, async: true

  alias KilnCMS.CMS.BlockBackfill
  alias KilnCMS.CMS.TypedBlocks
  alias KilnCMS.LegacyBlockCorpus

  @type_ {:array, KilnCMS.CMS.BlockUnion}

  defp read(stored) do
    {:ok, constraints} = Ash.Type.init(@type_, [])
    {:ok, cast} = Ash.Type.cast_stored(@type_, stored, constraints)
    TypedBlocks.to_typed(cast)
  end

  defp squeeze(html) do
    {:ok, nodes} = Floki.parse_fragment(IO.iodata_to_binary(html))
    nodes |> Floki.text() |> String.replace(~r/\s+/u, "")
  end

  for {name, expectation, stored} <- LegacyBlockCorpus.entries() do
    @stored stored
    @expectation expectation

    @must_note Map.get(LegacyBlockCorpus.expected_notes(), name, [])

    test "#{name} → #{inspect(expectation)}" do
      result = BlockBackfill.convert(@stored, "blocks")

      noted = result |> Tuple.to_list() |> List.last() |> Enum.map(& &1.kind)

      for kind <- @must_note,
          do: assert(kind in noted, "expected a #{kind} note, got #{inspect(noted)}")

      case @expectation do
        :canonical ->
          assert {:canonical, _notes} = result

        :rewrite ->
          assert {:rewrite, rewritten, notes} = result
          assert_reads_the_same(@stored, rewritten, notes)

          assert {:canonical, _} = BlockBackfill.convert(rewritten, "blocks"),
                 "a second pass must find nothing to do"

        {:refuse, kind} ->
          assert {:error, refusals, _notes} = result
          assert Enum.any?(refusals, &(&1.kind == kind)), inspect(refusals)
      end
    end
  end

  defp assert_reads_the_same(stored, rewritten, notes) do
    converted_paths =
      for %{kind: :legacy_html_converted, path: path} <- notes, do: path

    before = read(stored)
    after_ = read(rewritten)

    assert Enum.map(before, & &1.id) == Enum.map(after_, & &1.id), "block ids must survive"
    assert Enum.map(before, & &1.__struct__) == Enum.map(after_, & &1.__struct__)

    for {{old, new}, index} <- Enum.with_index(Enum.zip(before, after_)) do
      path = "blocks[#{index}]"

      converted =
        Enum.filter(converted_paths, &(&1 == path or String.starts_with?(&1, path <> ".")))

      assert_same_block(old, new, path, converted)
    end
  end

  # A block whose prose moved from `legacy_html` to `body` (itself, or a child)
  # renders through a different serializer, so it is held to the same words
  # rather than the same bytes — `PortableText.from_html_faithful/1` has held it to the
  # same markup. Every other block must come out byte-identical on both
  # surfaces.
  defp assert_same_block(old, new, path, []) do
    assert web(old) == web(new), "#{path} renders differently"
    assert KilnCMS.Blocks.render(old, :json) == KilnCMS.Blocks.render(new, :json)
  end

  defp assert_same_block(old, new, path, _converted),
    do: assert(squeeze(web(old)) == squeeze(web(new)), "#{path} reads differently")

  defp web(block), do: IO.iodata_to_binary(KilnCMS.Blocks.render(block, :web) || "")
end

defmodule KilnCMS.Blocks.SerializersPropertyTest do
  @moduledoc """
  Phase J — the v2 headline guarantee (decision A4): every serializer handles every
  block type without crashing, and the web surface always produces a binary.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias KilnCMS.Blocks
  alias KilnCMS.Blocks.{Custom, Embed, Heading, Image, Quote, RichText}

  defp text, do: StreamData.string(:printable, max_length: 40)

  defp pt_block do
    StreamData.fixed_map(%{
      "_type" => StreamData.constant("block"),
      "style" => StreamData.member_of(["normal", "h2", "blockquote"]),
      "children" =>
        StreamData.list_of(
          StreamData.fixed_map(%{
            "_type" => StreamData.constant("span"),
            "text" => text(),
            "marks" => StreamData.constant([])
          }),
          max_length: 3
        )
    })
  end

  defp block_generator do
    StreamData.one_of([
      StreamData.map(StreamData.tuple({text(), StreamData.integer(0..9)}), fn {t, l} ->
        %Heading{text: t, level: l}
      end),
      StreamData.map(StreamData.tuple({text(), text()}), fn {u, a} -> %Image{url: u, alt: a} end),
      StreamData.map(StreamData.list_of(pt_block(), max_length: 3), fn body ->
        %RichText{body: body}
      end),
      StreamData.map(text(), fn h -> %RichText{body: [], legacy_html: "<p>#{h}</p>"} end),
      StreamData.map(StreamData.tuple({text(), StreamData.boolean()}), fn {t, f} ->
        %Quote{text: t, featured: f}
      end),
      StreamData.map(text(), fn u -> %Embed{url: u} end),
      StreamData.map(text(), fn lt -> %Custom{legacy_type: lt, content: "x", data: %{}} end)
    ])
  end

  property "every serializer is total over arbitrary blocks" do
    check all(block <- block_generator()) do
      # Web is always renderable to a binary (iodata), never raises.
      assert is_binary(IO.iodata_to_binary(Blocks.render(block, :web)))

      # JSON is a map; JSON-LD is a map or nil (no contribution) — never raises.
      assert is_map(Blocks.render(block, :json))
      assert match?(nil, Blocks.render(block, :json_ld)) or is_map(Blocks.render(block, :json_ld))

      # Search projection is always a string.
      assert is_binary(Blocks.search_text(block))
    end
  end
end

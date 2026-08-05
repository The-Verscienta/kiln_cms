defmodule KilnCMS.Blocks.SerializersPropertyTest do
  @moduledoc """
  Phase J — the v2 headline guarantee (decision A4): every serializer handles every
  block type without crashing, and the web surface always produces a binary.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias KilnCMS.Blocks
  alias KilnCMS.Blocks.{Accordion, Audio, Claim, Columns, Custom, Divider, Embed, Faq, Form}
  alias KilnCMS.Blocks.{Gallery, Heading, HowTo, Image, Quote, RichText, Video}
  # Not aliased bare as `File` — that would shadow the stdlib module.
  alias KilnCMS.Blocks.File, as: FileBlock

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
      StreamData.map(
        StreamData.list_of(
          StreamData.map(StreamData.tuple({text(), text(), text()}), fn {u, a, c} ->
            %{"url" => u, "alt" => a, "caption" => c, "media_id" => ""}
          end),
          max_length: 3
        ),
        fn images -> %Gallery{images: images, layout: "grid"} end
      ),
      StreamData.map(
        StreamData.list_of(
          StreamData.map(StreamData.tuple({text(), text()}), fn {t, c} ->
            %{"title" => t, "content" => c}
          end),
          max_length: 3
        ),
        fn panels -> %Accordion{panels: panels} end
      ),
      StreamData.map(text(), fn s -> %Form{form_slug: s} end),
      StreamData.constant(%Divider{}),
      StreamData.map(StreamData.tuple({text(), text(), text(), text()}), fn {t, st, su, r} ->
        %Claim{text: t, source_title: st, source_url: su, rating: r}
      end),
      StreamData.map(
        StreamData.list_of(
          StreamData.map(StreamData.tuple({text(), text()}), fn {q, a} ->
            %{"question" => q, "answer" => a}
          end),
          max_length: 3
        ),
        fn items -> %Faq{items: items} end
      ),
      StreamData.map(
        StreamData.list_of(
          StreamData.map(StreamData.tuple({text(), text()}), fn {n, t} ->
            %{"name" => n, "text" => t}
          end),
          max_length: 3
        ),
        fn steps -> %HowTo{steps: steps} end
      ),
      # Children are raw maps typed lazily at render, so the interesting inputs
      # are a well-formed child, a junk child, and none at all.
      StreamData.map(
        StreamData.one_of([
          StreamData.constant([]),
          StreamData.constant([%{"blocks" => [%{"_type" => "divider"}]}]),
          StreamData.constant([%{"blocks" => ["not a block"]}])
        ]),
        fn cols -> %Columns{columns: cols, layout: "1-1"} end
      ),
      StreamData.map(text(), fn lt -> %Custom{legacy_type: lt, content: "x", data: %{}} end),
      StreamData.map(
        StreamData.tuple({text(), text(), text(), StreamData.integer(0..9_999_999)}),
        fn {mid, title, filename, size} ->
          %FileBlock{
            media_id: mid,
            title: title,
            filename: filename,
            content_type: "application/pdf",
            byte_size: size
          }
        end
      ),
      # A/V (#494): the interesting axis is which of the three `src` inputs is
      # present, because `src/1` prefers `media_id` and only falls back to a
      # pasted `url` — a generator that always sets both would never exercise
      # the fallback, and one that always sets neither would never exercise
      # the rendered element at all.
      StreamData.map(
        StreamData.tuple(
          {StreamData.one_of([text(), StreamData.constant("")]),
           StreamData.one_of([text(), StreamData.constant("")]), text(), text(),
           StreamData.one_of([StreamData.float(min: 0.0, max: 7200.0), StreamData.constant(nil)])}
        ),
        fn {mid, url, title, caption, duration} ->
          %Video{
            media_id: mid,
            url: url,
            title: title,
            caption: caption,
            captions_media_id: mid,
            duration_seconds: duration,
            autoplay: false,
            loop: false
          }
        end
      ),
      StreamData.map(
        StreamData.tuple(
          {StreamData.one_of([text(), StreamData.constant("")]),
           StreamData.one_of([text(), StreamData.constant("")]), text(),
           StreamData.one_of([StreamData.float(min: 0.0, max: 7200.0), StreamData.constant(nil)])}
        ),
        fn {mid, url, title, duration} ->
          %Audio{media_id: mid, url: url, title: title, duration_seconds: duration, loop: false}
        end
      )
    ])
  end

  # The generator above is hand-maintained, which means a new block type joins
  # the registry and this property quietly stops covering it — it does not fail,
  # it just tests one fewer thing. This is the test that notices.
  #
  # Totality (decision A4) is the guarantee the whole firing pipeline rests on:
  # an unhandled surface must return nil, never raise, because `Engine` maps a
  # serializer over every block of a document and one raise takes the whole
  # artifact down.
  test "the generator covers every registered block type" do
    generated =
      block_generator()
      |> Enum.take(400)
      |> MapSet.new(fn %mod{} -> Kiln.Block.Info.name(mod) end)

    # Core types only. A plugin's blocks are the plugin's own to guarantee, and
    # the installed plugin set varies by config — asserting over the full
    # registry would make this fail for a reason that has nothing to do with the
    # core serializers.
    core = MapSet.new(KilnCMS.Blocks.core_types())

    assert MapSet.subset?(core, generated),
           "no generator for: #{inspect(MapSet.to_list(MapSet.difference(core, generated)))}. " <>
             "Add one to block_generator/0 — without it the totality property " <>
             "silently skips this block type."
  end

  property "every serializer is total over arbitrary blocks" do
    check all(block <- block_generator()) do
      # Web is always renderable to a binary (iodata), never raises.
      assert is_binary(IO.iodata_to_binary(Blocks.render(block, :web)))

      # JSON is a map; JSON-LD is nil (no contribution), one node, or several —
      # never raises. The list arm is not slack: `Kiln.Block.Renderer` declares
      # `[map()]` and a container block legitimately returns its children's
      # nodes, which is exactly what `Engine.json_ld_nodes/1` flattens into the
      # document `@graph`. Asserting map-or-nil here described a narrower
      # contract than the one the engine implements, and it went unnoticed only
      # because the generator had no container block in it.
      assert is_map(Blocks.render(block, :json))

      case Blocks.render(block, :json_ld) do
        nil -> :ok
        node when is_map(node) -> :ok
        nodes when is_list(nodes) -> assert Enum.all?(nodes, &is_map/1)
      end

      # Search projection is always a string.
      assert is_binary(Blocks.search_text(block))
    end
  end
end

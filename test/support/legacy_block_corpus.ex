defmodule KilnCMS.LegacyBlockCorpus do
  @moduledoc """
  Stored block trees in every shape a Kiln database can still hold at rest —
  the corpus the #1537 backfill (`KilnCMS.CMS.BlockBackfill`) is run on.

  Each entry is `{name, expectation, stored}`: `stored` is a column value
  exactly as Postgres hands it back (a list of string-keyed maps), and
  `expectation` is what the backfill must make of it:

    * `:rewrite` — convertible; the typed tree must render as the stored one did.
    * `:canonical` — already the typed shape at rest; nothing to write.
    * `{:refuse, kind}` — not convertible without loss; reported, not written.

  Where the shapes come from:

    * **pre-flip rows** — the `KilnCMS.CMS.Block` embedded dump
      (`id`/`type`/`content`/`data`/`order`, `nil` keys omitted), for the eight
      types its `type` constraint allowed, with the content `priv/repo/seeds.exs`
      and the TipTap editor of the time actually wrote;
    * **bare typed maps** — `_type`-tagged maps outside the union envelope, for
      every registered block type, core and plugin;
    * **stored envelopes** — what the union dumps today, including ones behind
      the head `_version` and rich text still holding `legacy_html`;
    * **columns trees** — typed containers with legacy, typed and nested children;
    * **the ones that must be refused** — data a typed block has nowhere to put,
      and a block type this build no longer has.
  """

  @doc "Every corpus entry."
  @spec entries() :: [{String.t(), :rewrite | :canonical | {:refuse, atom()}, [map()]}]
  def entries do
    pre_flip() ++ bare_typed() ++ envelopes() ++ columns() ++ refused()
  end

  @doc """
  The note kinds the backfill must report for an entry, by name — so the
  classification is pinned, not just the outcome. Entries not listed here are
  only held to their expectation.
  """
  @spec expected_notes() :: %{String.t() => [atom()]}
  def expected_notes do
    %{
      "seeded welcome page" => [:legacy_block, :legacy_html_converted],
      "tiptap prose: marks, links, lists, quote, code, rule, table" => [:legacy_html_converted],
      "paragraph breaks inside a list item, a quote and a cell" => [:legacy_html_converted],
      "prose next to a code block with marks Portable Text code cannot hold" => [
        :legacy_block,
        :legacy_html_kept
      ],
      "custom and a type with no typed block" => [:legacy_block, :parked_custom],
      "legacy columns with legacy and typed children" => [:legacy_block, :legacy_child],
      "bare typed maps for every core block" => [:typed_map],
      "a plugin block as a bare typed map" => [:typed_map],
      "a heading written while heading was v1" => [:stale_version],
      "an envelope still holding legacy_html" => [:legacy_html_converted],
      "an envelope holding legacy_html that cannot convert" => [:legacy_html_kept],
      "typed columns with legacy and nested children" => [:legacy_child, :legacy_html_converted]
    }
  end

  @doc "A fixed uuid for position `n`, so assertions can name blocks."
  @spec id(pos_integer()) :: String.t()
  def id(n), do: "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(n), 12, "0")

  # ── pre-flip `KilnCMS.CMS.Block` rows ─────────────────────────────────────

  defp legacy(n, type, content, data \\ nil) do
    %{"id" => id(n), "type" => type, "order" => n}
    |> put("content", content)
    |> put("data", data)
  end

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  defp pre_flip do
    [
      {"seeded welcome page", :rewrite,
       [
         legacy(1, "heading", "Welcome to KilnCMS", %{"level" => 1}),
         legacy(
           2,
           "rich_text",
           "<p>This page was created by the seed script and published via the workflow.</p>"
         )
       ]},
      {"heading levels as the form posted them", :rewrite,
       [
         legacy(3, "heading", "String level", %{"level" => "3"}),
         legacy(4, "heading", "No level"),
         legacy(5, "heading", "Empty data", %{})
       ]},
      {"tiptap prose: marks, links, lists, quote, code, rule, table", :rewrite,
       [
         legacy(
           6,
           "rich_text",
           ~s(<p>Some <strong>bold</strong>, <em>italic</em>, <u>under</u>, <s>struck</s> and ) <>
             ~s(<code>code</code> with <a href="https://example.com/x" target="_blank" rel="noopener">a link</a>.</p>) <>
             ~s(<h2>Section</h2><h3>Subsection</h3><ul><li><p>one</p></li><li><p>two</p></li></ul>) <>
             ~s(<ol><li><p>first</p></li></ol><blockquote><p>quoted</p></blockquote>) <>
             ~s(<pre><code>mix test</code></pre><hr><p>line<br>break</p>)
         ),
         legacy(
           7,
           "rich_text",
           "<table><tbody><tr><th><p>A</p></th><th><p>B</p></th></tr>" <>
             "<tr><td><p>1</p></td><td><p>2</p></td></tr></tbody></table>"
         ),
         legacy(8, "rich_text", "<p><b>old bold</b> and <i>old italic</i> tags</p>")
       ]},
      {"prose the sanitizer already stripped at write time", :rewrite,
       [legacy(9, "rich_text", ~s(<p>x<sup>2</sup> <span style="color:red">red</span></p>))]},
      {"an inline image the sanitizer never let a reader see", :rewrite,
       [legacy(10, "rich_text", ~s(<p>Look: <img src="https://example.com/a.png" alt="a"></p>))]},
      {"paragraph breaks inside a list item, a quote and a cell", :rewrite,
       [
         legacy(
           24,
           "rich_text",
           "<ul><li><p>first line</p><p>second line</p></li></ul>" <>
             "<blockquote><p>one</p><p>two</p></blockquote>" <>
             "<table><tr><td><p>a</p><p>b</p></td></tr></table>"
         )
       ]},
      {"prose next to a code block with marks Portable Text code cannot hold", :rewrite,
       [
         legacy(25, "heading", "Kept"),
         legacy(26, "rich_text", "<pre><code>plain <strong>bold</strong></code></pre>")
       ]},
      {"empty rich text", :rewrite, [legacy(11, "rich_text", ""), legacy(12, "rich_text", nil)]},
      {"image, quote, embed, divider", :rewrite,
       [
         legacy(13, "image", "https://example.com/i.jpg", %{
           "url" => "https://example.com/i.jpg",
           "alt" => "Alt",
           "caption" => "Caption",
           "media_id" => "0b8c8f9e-0000-4000-8000-000000000001"
         }),
         legacy(14, "image", "https://example.com/content-only.jpg"),
         legacy(15, "quote", "To be or not", %{"citation" => "Hamlet"}),
         legacy(16, "embed", "https://www.youtube.com/watch?v=dQw4w9WgXcQ", %{
           "title" => "A video",
           "provider_name" => "YouTube",
           "thumbnail_url" => "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg"
         }),
         legacy(17, "divider", nil)
       ]},
      {"custom and a type with no typed block", :rewrite,
       [
         legacy(18, "custom", "hero", %{"variant" => "dark", "cta" => %{"label" => "Go"}}),
         legacy(19, "pricing_table", "Plans", %{"tiers" => [%{"name" => "Pro"}]})
       ]},
      {"legacy columns with legacy and typed children", :rewrite,
       [
         legacy(20, "columns", nil, %{
           "layout" => "1-2",
           "gap" => "lg",
           "columns" => [
             %{"blocks" => [legacy(21, "heading", "Left", %{"level" => 3})]},
             %{
               "blocks" => [
                 legacy(22, "rich_text", "<p>Right</p>"),
                 %{"_type" => "quote", "id" => id(23), "text" => "Typed child"}
               ]
             }
           ]
         })
       ]}
    ]
  end

  # ── bare typed maps (`_type`, no envelope) ──────────────────────────────────

  defp bare_typed do
    [
      {"bare typed maps for every core block", :rewrite,
       [
         %{"_type" => "heading", "id" => id(30), "text" => "Typed", "level" => 2},
         %{"_type" => "rich_text", "id" => id(31), "body" => pt("Portable text")},
         %{
           "_type" => "image",
           "id" => id(32),
           "url" => "https://example.com/t.jpg",
           "alt" => "t"
         },
         %{"_type" => "quote", "id" => id(33), "text" => "Typed quote", "citation" => "Me"},
         %{"_type" => "embed", "id" => id(34), "url" => "https://vimeo.com/1"},
         %{"_type" => "divider", "id" => id(35)},
         %{"_type" => "form", "id" => id(36), "form_slug" => "contact"},
         %{
           "_type" => "gallery",
           "id" => id(37),
           "title" => "Gallery",
           "layout" => "grid",
           "images" => [%{"url" => "https://example.com/g1.jpg", "alt" => "g1"}]
         },
         %{
           "_type" => "accordion",
           "id" => id(38),
           "title" => "FAQ-ish",
           "first_open" => true,
           "panels" => [%{"title" => "Q", "content" => "A"}]
         },
         %{
           "_type" => "faq",
           "id" => id(39),
           "title" => "FAQ",
           "items" => [%{"question" => "Q?", "answer" => "A."}]
         },
         %{
           "_type" => "how_to",
           "id" => id(40),
           "name" => "Brew",
           "description" => "Coffee",
           "steps" => [%{"name" => "Boil", "text" => "Bring water to 95 °C."}]
         },
         %{
           "_type" => "video",
           "id" => id(44),
           "url" => "https://example.com/v.mp4",
           "title" => "Clip",
           "duration_seconds" => 12.5
         },
         %{
           "_type" => "audio",
           "id" => id(45),
           "url" => "https://example.com/a.mp3",
           "title" => "Pod"
         },
         %{
           "_type" => "file",
           "id" => id(46),
           "title" => "Spec",
           "filename" => "spec.pdf",
           "content_type" => "application/pdf",
           "byte_size" => 1024
         },
         %{
           "_type" => "fragment",
           "id" => id(47),
           "ref" => %{"type" => "page", "id" => id(99)},
           "label" => "Shared banner"
         },
         %{
           "_type" => "claim",
           "id" => id(41),
           "text" => "The sky is blue",
           "source_title" => "NASA",
           "source_url" => "https://nasa.gov",
           "rating" => "true"
         },
         %{"_type" => "custom", "id" => id(42), "legacy_type" => "hero", "data" => %{"k" => "v"}}
       ]},
      {"a plugin block as a bare typed map", :rewrite,
       [%{"_type" => "callout", "id" => id(43), "text" => "Heads up", "tone" => "warn"}]}
    ]
  end

  # ── stored envelopes ────────────────────────────────────────────────────────

  defp envelope(type, value), do: %{"type" => type, "value" => Map.put(value, "_type", type)}

  defp envelopes do
    [
      {"typed envelopes at head", :canonical,
       [
         envelope("heading", %{"id" => id(50), "text" => "Head", "level" => 2, "_version" => 2}),
         envelope("rich_text", %{"id" => id(51), "body" => pt("Body"), "_version" => 1}),
         envelope("divider", %{"id" => id(52), "_version" => 1})
       ]},
      {"a heading written while heading was v1", :rewrite,
       [envelope("heading", %{"id" => id(53), "text" => "Old head", "_version" => 1})]},
      {"an envelope still holding legacy_html", :rewrite,
       [
         envelope("rich_text", %{
           "id" => id(54),
           "body" => [],
           "legacy_html" => "<p>Seeded <strong>prose</strong></p>",
           "_version" => 1
         })
       ]},
      {"an envelope holding legacy_html that cannot convert", :canonical,
       [
         envelope("rich_text", %{
           "id" => id(55),
           "body" => [],
           "legacy_html" => "<pre><code>IO.puts(<em>1</em>)</code></pre>",
           "_version" => 1
         })
       ]}
    ]
  end

  # ── columns trees ───────────────────────────────────────────────────────────

  defp columns do
    [
      {"typed columns with typed children", :canonical,
       [
         envelope("columns", %{
           "id" => id(60),
           "layout" => "1-1",
           "_version" => 1,
           "columns" => [
             %{
               "blocks" => [
                 %{
                   "_type" => "heading",
                   "id" => id(61),
                   "text" => "L",
                   "level" => 2,
                   "_version" => 2
                 }
               ]
             },
             %{"blocks" => [%{"_type" => "divider", "id" => id(62), "_version" => 1}]}
           ]
         })
       ]},
      {"typed columns with legacy and nested children", :rewrite,
       [
         envelope("columns", %{
           "id" => id(63),
           "_version" => 1,
           "columns" => [
             %{"blocks" => [legacy(64, "rich_text", "<p>Legacy child</p>")]},
             %{
               "blocks" => [
                 %{
                   "_type" => "columns",
                   "id" => id(65),
                   "columns" => [%{"blocks" => [legacy(66, "heading", "Deep", %{"level" => 4})]}]
                 }
               ]
             }
           ]
         })
       ]}
    ]
  end

  # ── must be refused ─────────────────────────────────────────────────────────

  defp refused do
    [
      {"legacy data the typed block has nowhere to keep", {:refuse, :lossy},
       [
         legacy(70, "heading", "Fine"),
         legacy(71, "image", "https://example.com/w.jpg", %{
           "url" => "https://example.com/w.jpg",
           "width" => 640
         })
       ]},
      {"legacy children on a leaf block", {:refuse, :lossy},
       [Map.put(legacy(72, "rich_text", "<p>p</p>"), "children", [%{"type" => "heading"}])]},
      {"a block from a plugin that is gone", {:refuse, :unknown_type},
       [
         legacy(73, "heading", "Fine"),
         envelope("retired_widget", %{"id" => id(74), "_version" => 1, "size" => 3})
       ]},
      {"a lossy child inside columns", {:refuse, :lossy},
       [
         envelope("columns", %{
           "id" => id(75),
           "_version" => 1,
           "columns" => [%{"blocks" => [legacy(76, "divider", "text a divider cannot show")]}]
         })
       ]},
      {"not a block", {:refuse, :unrecognized}, [%{"nothing" => "here"}]}
    ]
  end

  defp pt(text) do
    [
      %{
        "_type" => "block",
        "_key" => "b0",
        "style" => "normal",
        "markDefs" => [],
        "children" => [%{"_type" => "span", "_key" => "s0", "text" => text, "marks" => []}]
      }
    ]
  end
end

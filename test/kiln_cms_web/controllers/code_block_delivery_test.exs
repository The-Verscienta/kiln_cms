defmodule KilnCMSWeb.CodeBlockDeliveryTest do
  @moduledoc """
  A published page's code blocks reach readers keyboard-focusable and named
  (#2164), in the language of the page — including when the page comes from
  the published-payload cache, which builds it in a process that has no
  request locale.
  """
  # Not async: these read through the published-payload cache, one global
  # Cachex table, and `setup` clears it.
  use KilnCMSWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias KilnCMS.CMS.Page
  alias KilnCMS.Repo

  setup do
    KilnCMS.Cache.bust_published()
    :ok
  end

  defp uniq, do: System.unique_integer([:positive])

  defp page(attrs) do
    Ash.Seed.seed!(
      Page,
      Map.merge(
        %{
          title: "Code page",
          slug: "code-#{uniq()}",
          state: :published,
          published_at: DateTime.utc_now()
        },
        attrs
      )
    )
  end

  defp code(text, language) do
    %{
      "_type" => "block",
      "style" => "code",
      "language" => language,
      "children" => [%{"_type" => "span", "text" => text, "marks" => []}],
      "markDefs" => []
    }
  end

  defp rich(body), do: %{"_type" => "rich_text", "body" => body}

  test "a Portable Text code block takes focus and a name", %{conn: conn} do
    page = page(%{blocks: [rich([code("IO.puts(1)", "elixir")])]})

    html = conn |> get(~p"/#{page.slug}") |> html_response(200)

    assert html =~
             ~s(<pre class="highlight" tabindex="0" role="group" aria-label="Code sample">)
  end

  test "a legacy_html code block takes focus and a name", %{conn: conn} do
    page =
      page(%{
        blocks: [
          %{
            "_type" => "rich_text",
            "legacy_html" =>
              ~s(<pre tabindex="-1"><code class="language-elixir">) <>
                String.duplicate("x", 300) <> "</code></pre>"
          }
        ]
      })

    html = conn |> get(~p"/#{page.slug}") |> html_response(200)

    assert html =~
             ~s(<pre tabindex="0" role="group" aria-label="Code sample"><code class="language-elixir">)

    refute html =~ ~s(tabindex="-1")
  end

  # The label follows the page's own locale. The payload cache computes a miss
  # in Cachex's courier process, which never saw `Plugs.SetLocale`, so without
  # the explicit locale the French page would carry the English label — on
  # every hit after the first, and on the first too.
  test "a French page carries the French label, cached hits included", %{conn: conn} do
    page = page(%{locale: "fr", blocks: [rich([code("x = 1", "cobol")])]})

    first = conn |> get("/fr/#{page.slug}") |> html_response(200)
    assert first =~ ~s(aria-label="Exemple de code")
    refute first =~ ~s(aria-label="Code sample")

    # Rewrite the column behind the cache's back: a second response that still
    # shows the original block came from the cache.
    {1, _} =
      Repo.update_all(
        from(p in "pages", where: p.id == type(^page.id, Ecto.UUID)),
        set: [blocks: []]
      )

    second = build_conn() |> get("/fr/#{page.slug}") |> html_response(200)
    assert second =~ "x = 1"
    assert second =~ ~s(aria-label="Exemple de code")
  end

  # A fallback-served page is in the record's language, and so is its label:
  # the article says so with its own `lang`, while `<html lang>` is the
  # reader's, the URL's (#2595).
  test "an English page served at /fr/ by fallback keeps the English label", %{conn: conn} do
    page = page(%{locale: "en", blocks: [rich([code("x = 1", "cobol")])]})

    html = conn |> get("/fr/#{page.slug}") |> html_response(200)
    doc = LazyHTML.from_document(html)

    assert doc |> LazyHTML.query("html") |> LazyHTML.attribute("lang") == ["fr"]
    assert doc |> LazyHTML.query("article.public-article") |> LazyHTML.attribute("lang") == ["en"]
    assert html =~ ~s(aria-label="Code sample")
    refute html =~ ~s(aria-label="Exemple de code")
  end

  test "a code block inside columns takes focus and a name", %{conn: conn} do
    page =
      page(%{
        blocks: [
          %{
            "_type" => "columns",
            "layout" => "1-1",
            "columns" => [
              %{"blocks" => [rich([code("left()", "cobol")])]},
              %{"blocks" => [%{"_type" => "heading", "text" => "Right"}]}
            ]
          }
        ]
      })

    html = conn |> get(~p"/#{page.slug}") |> html_response(200)

    assert html =~ "kiln-columns"

    assert html =~
             ~s{<pre tabindex="0" role="group" aria-label="Code sample"><code class="language-cobol">left()</code>}
  end

  test "a code block inlined from a fragment takes focus and a name", %{conn: conn} do
    shared = page(%{title: "Shared snippet", blocks: [rich([code("shared()", "cobol")])]})

    host =
      page(%{
        blocks: [%{"_type" => "fragment", "ref" => %{"type" => "page", "id" => shared.id}}]
      })

    html = conn |> get(~p"/#{host.slug}") |> html_response(200)

    assert html =~
             ~s{<pre tabindex="0" role="group" aria-label="Code sample"><code class="language-cobol">shared()</code>}
  end
end

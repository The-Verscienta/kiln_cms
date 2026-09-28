defmodule KilnCMSWeb.LegacyBlockDeliveryTest do
  @moduledoc """
  A row the block backfill refused still delivers (#1543).

  1.0 removed the write side of the legacy block bridge, but kept the read
  side: a stored block in the pre-typed shape, a block of a type this build no
  longer has, one behind a gap in its migrate chain, and rich text whose prose
  only Portable Text-unfaithful HTML holds are all converted on read — to a
  typed block, or to `KilnCMS.Blocks.Custom`. Every entry the corpus says the
  backfill must refuse is planted, raw, into a published page's `blocks`, and
  the page must still render.
  """
  use KilnCMSWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]

  alias KilnCMS.CMS.Page
  alias KilnCMS.LegacyBlockCorpus
  alias KilnCMS.Repo

  defp published_page do
    Ash.Seed.seed!(Page, %{
      title: "Legacy delivery",
      slug: "legacy-#{System.unique_integer([:positive])}",
      state: :published,
      published_at: DateTime.utc_now()
    })
  end

  # Straight to the column, bypassing the write cast that refuses this shape —
  # the way a pre-flip row, or one the backfill left alone, sits at rest.
  defp plant(page, stored) do
    {1, _} =
      Repo.update_all(
        from(p in "pages", where: p.id == type(^page.id, Ecto.UUID)),
        set: [blocks: stored]
      )

    :ok
  end

  for {name, {:refuse, kind}, stored} <- LegacyBlockCorpus.entries() do
    @stored stored
    test "a refused row (#{kind}: #{name}) still renders", %{conn: conn} do
      page = published_page()
      :ok = plant(page, @stored)

      assert html_response(get(conn, ~p"/#{page.slug}"), 200) =~ "Legacy delivery"
    end
  end

  test "a refused legacy heading still shows its text", %{conn: conn} do
    page = published_page()
    :ok = plant(page, [%{"type" => "heading", "content" => "Still here", "data" => %{}}])

    assert html_response(get(conn, ~p"/#{page.slug}"), 200) =~ "Still here"
  end

  test "rich text kept as legacy_html renders that HTML, sanitized", %{conn: conn} do
    page = published_page()

    :ok =
      plant(page, [
        %{
          "type" => "rich_text",
          "value" => %{
            "_type" => "rich_text",
            "id" => Ash.UUID.generate(),
            "body" => [],
            "legacy_html" => "<pre><code>IO.puts(<em>1</em>)</code></pre><script>x()</script>",
            "_version" => 1
          }
        }
      ])

    html = html_response(get(conn, ~p"/#{page.slug}"), 200)
    assert html =~ "IO.puts("
    refute html =~ "<script>x()"
  end
end

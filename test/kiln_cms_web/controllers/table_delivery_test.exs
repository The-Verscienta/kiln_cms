defmodule KilnCMSWeb.TableDeliveryTest do
  @moduledoc """
  A published page's tables reach readers in a keyboard-focusable, named
  scroll wrapper (#2464), in the language of the page — including when the
  page comes from the published-payload cache, which builds it in a process
  that has no request locale.
  """
  # Not async: these read through the published-payload cache, one global
  # Cachex table, and `setup` clears it.
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.CMS.Page

  @open ~s(<div class="kiln-table-wrap" tabindex="0" role="group" aria-label="Scrollable table">)

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
          title: "Table page",
          slug: "table-#{uniq()}",
          state: :published,
          published_at: DateTime.utc_now()
        },
        attrs
      )
    )
  end

  defp table(text) do
    cell = %{"children" => [%{"_type" => "span", "text" => text, "marks" => []}]}
    %{"_type" => "table", "rows" => [%{"cells" => [cell]}]}
  end

  defp rich(body), do: %{"_type" => "rich_text", "body" => body}

  test "a Portable Text table's wrapper takes focus and a name", %{conn: conn} do
    page = page(%{blocks: [rich([table("Flour")])]})

    html = conn |> get(~p"/#{page.slug}") |> html_response(200)

    assert html =~ ~s(#{@open}<table><tbody><tr><td>Flour</td>)
  end

  test "a bare legacy_html table is wrapped, and an author's tabindex dropped", %{conn: conn} do
    page =
      page(%{
        blocks: [
          %{
            "_type" => "rich_text",
            "legacy_html" =>
              ~s(<table tabindex="-1"><tr><td>) <>
                String.duplicate("x", 300) <> "</td></tr></table>"
          }
        ]
      })

    html = conn |> get(~p"/#{page.slug}") |> html_response(200)

    assert html =~ ~s(#{@open}<table><tr><td>xxx)
    refute html =~ ~s(tabindex="-1")
  end

  test "a French page carries the French label", %{conn: conn} do
    page = page(%{locale: "fr", blocks: [rich([table("x")])]})

    first = conn |> get("/fr/#{page.slug}") |> html_response(200)
    assert first =~ ~s(aria-label="Tableau défilant")
    refute first =~ ~s(aria-label="Scrollable table")

    # A cache hit keeps it: the miss was built in the page's locale.
    second = build_conn() |> get("/fr/#{page.slug}") |> html_response(200)
    assert second =~ ~s(aria-label="Tableau défilant")
  end
end

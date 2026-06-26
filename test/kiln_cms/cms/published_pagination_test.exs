defmodule KilnCMS.CMS.PublishedPaginationTest do
  @moduledoc """
  The public `:published` read is always paginated, so the anonymous blog index
  can't be made to load an unbounded number of rows into memory per request.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Post

  # A unique locale isolates this test's posts from anything else in the shared
  # sandbox, so the assertions are exact regardless of other seeded content.
  defp seed_posts(count, locale) do
    for i <- 1..count do
      Ash.Seed.seed!(Post, %{
        title: "P#{i}",
        slug: "pg-#{System.unique_integer([:positive])}",
        state: :published,
        locale: locale,
        published_at: DateTime.add(DateTime.utc_now(), -i, :minute)
      })
    end
  end

  test "a page-less call is capped at the action's default limit" do
    locale = "pl-#{System.unique_integer([:positive])}"
    seed_posts(25, locale)

    page = CMS.list_published_posts!(authorize?: false, query: [filter: [locale: locale]])

    assert %Ash.Page.Offset{results: results, more?: true} = page
    assert length(results) == 20
  end

  test "an explicit smaller limit is honored, with offset paging the rest" do
    locale = "pl-#{System.unique_integer([:positive])}"
    seed_posts(25, locale)

    first =
      CMS.list_published_posts!(
        authorize?: false,
        query: [filter: [locale: locale]],
        page: [limit: 10, offset: 0, count: true]
      )

    assert length(first.results) == 10
    assert first.more?
    assert first.count == 25

    last =
      CMS.list_published_posts!(
        authorize?: false,
        query: [filter: [locale: locale]],
        page: [limit: 10, offset: 20]
      )

    assert length(last.results) == 5
    refute last.more?
  end

  test "a limit above the action's max_page_size is rejected (can't request everything)" do
    assert {:error, _} =
             CMS.list_published_posts(authorize?: false, page: [limit: 100_000])
  end
end

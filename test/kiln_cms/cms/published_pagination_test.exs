defmodule KilnCMS.CMS.PublishedPaginationTest do
  @moduledoc """
  The public `:published` read is paginated, so a paged request (e.g. the
  anonymous blog index) can't be made to load an unbounded number of rows into
  memory: an explicit `page:` is capped at `default_limit`, and `max_page_size`
  rejects an oversized caller-supplied limit.
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

  test "a limitless page request is still capped at the action's default_limit (25)" do
    locale = "pl-#{System.unique_integer([:positive])}"
    seed_posts(30, locale)

    page =
      CMS.list_published_posts!(
        authorize?: false,
        query: [filter: [locale: locale]],
        page: [offset: 0]
      )

    assert %Ash.Page.Offset{results: results, more?: true} = page
    assert length(results) == 25
  end

  test "an explicit smaller limit is honored, with offset paging the rest" do
    locale = "pl-#{System.unique_integer([:positive])}"
    seed_posts(30, locale)

    first =
      CMS.list_published_posts!(
        authorize?: false,
        query: [filter: [locale: locale]],
        page: [limit: 10, offset: 0, count: true]
      )

    assert length(first.results) == 10
    assert first.more?
    assert first.count == 30

    last =
      CMS.list_published_posts!(
        authorize?: false,
        query: [filter: [locale: locale]],
        page: [limit: 10, offset: 25]
      )

    assert length(last.results) == 5
    refute last.more?
  end

  test "a limit above the action's max_page_size (100) is rejected" do
    assert {:error, _} =
             CMS.list_published_posts(authorize?: false, page: [limit: 100_000])
  end
end

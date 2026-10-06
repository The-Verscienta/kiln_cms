defmodule KilnCMS.Portability.GhostImportTest do
  @moduledoc """
  A Ghost export written into the CMS (#1876), end to end through
  `KilnCMS.Portability.Import` — the write path `mix kiln.import.ghost` uses.
  The parser's own decisions are pinned in `GhostTest`; this pins that they
  survive the real Ash actions. Media is skipped: sideloading is covered by
  `ImportTest`, and is source-neutral.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.GhostFixture
  alias KilnCMS.Portability.Ghost
  alias KilnCMS.Portability.Import

  setup do
    actor =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "ghost-import-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    {:ok, parsed} = Ghost.parse(GhostFixture.json(), site_url: "https://blog.example.com")

    {:ok, report} = Import.run(parsed, actor: actor, skip_media: true)

    %{actor: actor, report: report}
  end

  defp posts(actor), do: CMS.list_posts!(actor: actor, load: [:tags])
  defp find(records, slug), do: Enum.find(records, &(&1.slug == slug))

  test "every record lands, none failed", %{actor: actor, report: report} do
    assert report.failed == []

    assert Enum.map(posts(actor), & &1.slug) |> Enum.sort() ==
             ~w(a-draft coming-soon hello-world members-only weekly-letter)

    assert [%{slug: "about"}] = CMS.list_pages!(actor: actor)
  end

  test "published, with its Ghost date, SEO, excerpt and tags", %{actor: actor} do
    post = actor |> posts() |> find("hello-world")

    assert post.state == :published
    assert DateTime.compare(post.published_at, ~U[2026-01-15 09:30:00Z]) == :eq
    assert post.seo_title == "Hello, SEO"
    assert post.seo_description == "The search snippet."
    assert post.excerpt == "A short summary."
    assert post.audience == :public
    assert Enum.map(post.tags, & &1.slug) |> Enum.sort() == ["how-to", "news"]
  end

  test "a members-only post is published, and still gated", %{actor: actor} do
    post = actor |> posts() |> find("members-only")

    assert post.state == :published
    assert post.audience == :member
  end

  test "scheduled and email-only posts do not go live", %{actor: actor} do
    assert (actor |> posts() |> find("coming-soon")).state == :draft
    assert (actor |> posts() |> find("weekly-letter")).state == :draft
  end

  test "the internal # tag is not created", %{actor: actor} do
    refute Enum.any?(CMS.list_tags!(actor: actor), &String.starts_with?(&1.name, "#"))
  end

  test "each old /{slug}/ permalink redirects to the imported record", %{actor: actor} do
    post = actor |> posts() |> find("hello-world")
    redirect = CMS.list_redirects!(actor: actor) |> Enum.find(&(&1.path == "/hello-world"))

    assert redirect.target_type == "post"
    assert redirect.target_id == post.id
  end

  test "a second run skips everything", %{actor: actor} do
    {:ok, parsed} = Ghost.parse(GhostFixture.json(), site_url: "https://blog.example.com")
    {:ok, report} = Import.run(parsed, actor: actor, skip_media: true)

    assert report.created == []
    assert length(report.skipped) == 6
  end
end

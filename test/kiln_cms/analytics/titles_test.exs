defmodule KilnCMS.Analytics.TitlesTest do
  @moduledoc """
  Id-batched title resolution shared by `AnalyticsLive` and the analytics
  export (#618) — one policy-gated lookup per content type, actor-scoped
  (never `authorize?: false`), with "(deleted)" / "(unknown type: ...)" left
  to `title_for/3` rather than baked into `resolve/3`.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Accounts
  alias KilnCMS.Analytics.Titles
  alias KilnCMS.CMS

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "titles-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp viewer do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "titles-viewer-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :viewer
    })
  end

  defp slug, do: "titles-#{System.unique_integer([:positive])}"

  test "resolves titles and slugs, batched per content type" do
    actor = admin()
    org = Accounts.default_org()

    page = CMS.create_page!(%{title: "A Page", slug: slug()}, actor: actor, tenant: org)
    post = CMS.create_post!(%{title: "A Post", slug: slug()}, actor: actor, tenant: org)

    rows = [
      %{content_type: "page", content_id: page.id},
      %{content_type: "post", content_id: post.id}
    ]

    titles = Titles.resolve(rows, org, actor)

    assert titles[page.id] == {"A Page", page.slug}
    assert titles[post.id] == {"A Post", post.slug}
  end

  test "omits ids for content that no longer exists — callers apply their own fallback" do
    actor = admin()
    org = Accounts.default_org()
    missing_id = Ash.UUID.generate()

    titles = Titles.resolve([%{content_type: "page", content_id: missing_id}], org, actor)

    refute Map.has_key?(titles, missing_id)
    assert Map.get(titles, missing_id, {"(deleted)", nil}) == {"(deleted)", nil}
  end

  test "an unregistered content type contributes nothing rather than raising" do
    actor = admin()
    org = Accounts.default_org()
    id = Ash.UUID.generate()

    assert Titles.resolve([%{content_type: "not_a_real_type", content_id: id}], org, actor) == %{}
  end

  test "accepts a bare org id as well as an org struct" do
    actor = admin()
    org_id = Accounts.default_org_id()
    page = CMS.create_page!(%{title: "By Id", slug: slug()}, actor: actor, tenant: org_id)

    titles = Titles.resolve([%{content_type: "page", content_id: page.id}], org_id, actor)

    assert titles[page.id] == {"By Id", page.slug}
  end

  # The point of threading `actor` through at all (#618): a title read is
  # policy-gated, not `authorize?: false`, so it can't surface content the
  # actor couldn't otherwise read.
  test "an actor with no read access to the content sees it as absent, not titled" do
    admin_actor = admin()
    org = Accounts.default_org()

    page =
      CMS.create_page!(%{title: "Hidden From Viewer", slug: slug()},
        actor: admin_actor,
        tenant: org
      )

    titles = Titles.resolve([%{content_type: "page", content_id: page.id}], org, viewer())

    refute Map.has_key?(titles, page.id)
  end

  describe "title_for/3" do
    test "returns the resolved title when present" do
      org = Accounts.default_org()
      row = %{content_type: "page", content_id: Ash.UUID.generate()}
      titles = %{row.content_id => {"Resolved", "resolved-slug"}}

      assert Titles.title_for(row, titles, org) == "Resolved"
    end

    test "falls back to \"(deleted)\" when the type is known but the id is absent" do
      org = Accounts.default_org()
      row = %{content_type: "page", content_id: Ash.UUID.generate()}

      assert Titles.title_for(row, %{}, org) == "(deleted)"
    end

    test "labels an unregistered content type distinctly from a deleted item" do
      org = Accounts.default_org()
      row = %{content_type: "not_a_real_type", content_id: Ash.UUID.generate()}

      assert Titles.title_for(row, %{}, org) == "(unknown type: not_a_real_type)"
    end
  end
end

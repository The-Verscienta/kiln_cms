defmodule KilnCMSWeb.ContentEditorSlugTest do
  @moduledoc """
  Auto-derived slugs in the content editor: while the slug is still the
  scaffold placeholder (or tracks the title), editing the title re-derives the
  slug live with stop words stripped; typing in the slug field pins it;
  clearing the slug field unpins it again. Published content never follows —
  a title edit must not move a live URL.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role) do
    email = "slugsync-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => email,
        "password" => @password
      })

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp open_editor(conn, user, page, type \\ "page") do
    {:ok, lv, _html} = conn |> log_in(user) |> live(~p"/editor/content/#{type}/#{page.id}")
    lv
  end

  defp change(lv, field, params) do
    render_change(lv, "validate", %{"form" => params, "_target" => ["form", field]})
  end

  defp slug_value(lv) do
    [value] =
      Regex.run(~r/name="form\[slug\]"[^>]*\bvalue="([^"]*)"/, slug_input(lv),
        capture: :all_but_first
      )

    value
  end

  defp slug_input(lv), do: lv |> element(~s{input[name="form[slug]"]}) |> render()

  test "editing the title re-derives a placeholder slug, stop words stripped", %{conn: conn} do
    editor = authed_user(:editor)
    n = System.unique_integer([:positive])
    page = CMS.create_page!(%{title: "Untitled page", slug: "untitled-#{n}"}, actor: editor)
    lv = open_editor(conn, editor, page)

    change(lv, "title", %{"title" => "A Guide to the Kiln", "slug" => "untitled-#{n}"})
    assert slug_value(lv) == "guide-kiln"
  end

  test "typing in the slug field pins it against later title edits", %{conn: conn} do
    editor = authed_user(:editor)
    n = System.unique_integer([:positive])
    page = CMS.create_page!(%{title: "Untitled page", slug: "untitled-#{n}"}, actor: editor)
    lv = open_editor(conn, editor, page)

    change(lv, "slug", %{"title" => "Untitled page", "slug" => "my-own-slug"})
    change(lv, "title", %{"title" => "A Guide to the Kiln", "slug" => "my-own-slug"})
    assert slug_value(lv) == "my-own-slug"
  end

  test "clearing the slug field resumes derivation from the title", %{conn: conn} do
    editor = authed_user(:editor)

    page =
      CMS.create_page!(
        %{title: "Pinned", slug: "hand-picked-#{System.unique_integer([:positive])}"},
        actor: editor
      )

    lv = open_editor(conn, editor, page)

    change(lv, "slug", %{"title" => "Pinned", "slug" => ""})
    change(lv, "title", %{"title" => "Fresh Start for the Draft", "slug" => ""})
    assert slug_value(lv) == "fresh-start-draft"
  end

  test "editing SEO keywords re-derives an unpinned slug from the focus keyphrase",
       %{conn: conn} do
    editor = authed_user(:editor)
    n = System.unique_integer([:positive])
    page = CMS.create_page!(%{title: "Untitled page", slug: "untitled-#{n}"}, actor: editor)
    lv = open_editor(conn, editor, page)

    change(lv, "seo_keywords", %{
      "title" => "Untitled page",
      "slug" => "untitled-#{n}",
      "seo_keywords" => "Ceramic Kiln Care, pottery"
    })

    assert slug_value(lv) == "ceramic-kiln-care"
  end

  test "SEO keywords never move a pinned slug", %{conn: conn} do
    editor = authed_user(:editor)
    slug = "hand-chosen-#{System.unique_integer([:positive])}"
    page = CMS.create_page!(%{title: "Pinned", slug: slug}, actor: editor)
    lv = open_editor(conn, editor, page)

    change(lv, "seo_keywords", %{
      "title" => "Pinned",
      "slug" => slug,
      "seo_keywords" => "ceramic kiln"
    })

    assert slug_value(lv) == slug
  end

  test "live derivation dedupes against an existing record", %{conn: conn} do
    editor = authed_user(:editor)
    CMS.create_page!(%{title: "Existing", slug: "guide-kiln"}, actor: editor)
    n = System.unique_integer([:positive])
    page = CMS.create_page!(%{title: "Untitled page", slug: "untitled-#{n}"}, actor: editor)
    lv = open_editor(conn, editor, page)

    change(lv, "title", %{"title" => "A Guide to the Kiln", "slug" => "untitled-#{n}"})
    assert slug_value(lv) == "guide-kiln-2"
  end

  test "the full public URL is previewed under the slug field", %{conn: conn} do
    editor = authed_user(:editor)
    slug = "url-preview-#{System.unique_integer([:positive])}"
    post = CMS.create_post!(%{title: "Post", slug: slug}, actor: editor)
    lv = open_editor(conn, editor, post, "post")

    assert render(lv) =~ "/blog/#{slug}"
  end

  test "published content links its live URL", %{conn: conn} do
    admin = authed_user(:admin)
    slug = "live-link-#{System.unique_integer([:positive])}"
    page = CMS.create_page!(%{title: "Live", slug: slug}, actor: admin)
    published = CMS.publish_page!(page, %{}, actor: admin)
    lv = open_editor(conn, admin, published)

    assert has_element?(lv, ~s{a[href="/#{slug}"]})
  end

  test "a dynamic type's slug pattern drives the editor's live derivation", %{conn: conn} do
    admin = authed_user(:admin)

    type =
      CMS.create_type_definition!(
        %{
          name: "dyn#{System.unique_integer([:positive])}",
          label: "Dynamic",
          slug_pattern: "[yyyy]-[title]"
        },
        actor: admin
      )

    n = System.unique_integer([:positive])

    entry =
      KilnCMS.CMS.ContentTypes.create!(
        type.name,
        %{title: "Untitled entry", slug: "untitled-#{n}"},
        actor: admin
      )

    lv = open_editor(conn, admin, entry, type.name)

    change(lv, "title", %{"title" => "A Guide to the Kiln", "slug" => "untitled-#{n}"})
    assert slug_value(lv) == "#{Date.utc_today().year}-guide-kiln"
  end

  test "date tokens anchor to the record's creation date, not today", %{conn: conn} do
    admin = authed_user(:admin)

    type =
      CMS.create_type_definition!(
        %{
          name: "dyn#{System.unique_integer([:positive])}",
          label: "Dynamic",
          slug_pattern: "[yyyy]-[title]"
        },
        actor: admin
      )

    n = System.unique_integer([:positive])

    # A draft created long ago (simulating reopening it much later): the
    # expected base must use inserted_at's year, so the slug neither flips to
    # "pinned" nor re-derives with today's year.
    entry =
      Ash.Seed.seed!(KilnCMS.CMS.Entry, %{
        title: "Untitled entry",
        slug: "untitled-#{n}",
        type_definition_id: type.id,
        inserted_at: ~U[2020-03-01 12:00:00Z]
      })

    lv = open_editor(conn, admin, entry, type.name)

    change(lv, "title", %{"title" => "A Guide to the Kiln", "slug" => "untitled-#{n}"})
    assert slug_value(lv) == "2020-guide-kiln"
  end

  test "a live scheduled date reaches date tokens", %{conn: conn} do
    admin = authed_user(:admin)

    type =
      CMS.create_type_definition!(
        %{
          name: "dyn#{System.unique_integer([:positive])}",
          label: "Dynamic",
          slug_pattern: "[yyyy]-[mm]-[title]"
        },
        actor: admin
      )

    n = System.unique_integer([:positive])

    entry =
      KilnCMS.CMS.ContentTypes.create!(
        type.name,
        %{title: "Untitled entry", slug: "untitled-#{n}"},
        actor: admin
      )

    lv = open_editor(conn, admin, entry, type.name)

    change(lv, "scheduled_at", %{
      "title" => "A Guide to the Kiln",
      "slug" => "untitled-#{n}",
      "scheduled_at" => "2027-01-15T00:00:00Z"
    })

    assert slug_value(lv) == "2027-01-guide-kiln"
  end

  test "an author's -1 suffix is never mistaken for a dedupe variant", %{conn: conn} do
    editor = authed_user(:editor)
    # Derivation of "Pinned" is "pinned"; ensure_unique never mints "-1", so
    # "pinned-1" must be treated as author-chosen and left alone.
    page = CMS.create_page!(%{title: "Pinned", slug: "pinned-1"}, actor: editor)
    lv = open_editor(conn, editor, page)

    change(lv, "title", %{"title" => "Renamed Draft", "slug" => "pinned-1"})
    assert slug_value(lv) == "pinned-1"
  end

  test "category edits don't re-derive on pattern-less types", %{conn: conn} do
    editor = authed_user(:editor)
    n = System.unique_integer([:positive])
    page = CMS.create_page!(%{title: "Untitled page", slug: "untitled-#{n}"}, actor: editor)
    lv = open_editor(conn, editor, page)

    change(lv, "category_id", %{"title" => "Untitled page", "slug" => "untitled-#{n}"})
    assert slug_value(lv) == "untitled-#{n}"
  end

  test "a published record's slug never follows the title", %{conn: conn} do
    admin = authed_user(:admin)
    slug = "live-url-#{System.unique_integer([:positive])}"
    page = CMS.create_page!(%{title: "Live Page", slug: slug}, actor: admin)
    published = CMS.publish_page!(page, %{}, actor: admin)
    lv = open_editor(conn, admin, published)

    change(lv, "title", %{"title" => "Renamed Live Page", "slug" => slug})
    assert slug_value(lv) == slug
  end
end

defmodule KilnCMSWeb.ContentEditorSeoTest do
  @moduledoc """
  The SEO & readability panel in the content editor (#476): a traffic-light
  grade in the panel header and a live, non-blocking findings checklist that
  updates as the author types. Nothing here ever blocks a save.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role) do
    email = "seo-panel-#{System.unique_integer([:positive])}@example.com"

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

  defp open_editor(conn, user, page) do
    {:ok, lv, html} = conn |> log_in(user) |> live(~p"/editor/content/page/#{page.id}")
    {lv, html}
  end

  defp change(lv, field, params) do
    render_change(lv, "validate", %{"form" => params, "_target" => ["form", field]})
  end

  # The seo_image input's own value. Asserting against the whole page would be
  # satisfied by the featured-image thumbnail, which renders the same URL.
  # An empty field renders with no `value` attribute at all.
  defp seo_image_value(lv) do
    html = lv |> element(~s(input[name="form[seo_image]"])) |> render()

    case Regex.run(~r/\bvalue="([^"]*)"/, html, capture: :all_but_first) do
      [value] -> value
      nil -> ""
    end
  end

  # Ten short, readable paragraphs — enough to clear the thin-content floor,
  # with the keyphrase only in the opening few so density stays in band.
  defp prose_blocks do
    body =
      for i <- 1..10 do
        opener =
          if i <= 3,
            do: "The kiln firing step #{i} is simple. ",
            else: "Step #{i} is just as simple. "

        %{
          "_type" => "block",
          "style" => "normal",
          "children" => [
            %{
              "text" =>
                opener <>
                  "Load the shelves with care. " <>
                  "Set the ramp rate low for the first hour. Watch the cones as the heat climbs. " <>
                  "Let the work cool in the closed kiln before you open it."
            }
          ]
        }
      end

    [
      %{"_type" => "heading", "text" => "Understanding kiln firing", "level" => 2},
      %{"_type" => "rich_text", "body" => body}
    ]
  end

  describe "the panel renders on mount" do
    test "a bare draft shows the grade badge and a missing-description warning", %{conn: conn} do
      editor = authed_user(:editor)
      page = CMS.create_page!(%{title: "Bare Draft", slug: "bare-seo"}, actor: editor)
      {_lv, html} = open_editor(conn, editor, page)

      assert html =~ "SEO &amp; scheduling"
      assert html =~ "search engines will invent one"
      # Warnings present, so the badge is not green.
      assert html =~ "Needs work" or html =~ "Poor"
    end

    test "an empty draft is never a wall of failures", %{conn: conn} do
      editor = authed_user(:editor)
      page = CMS.create_page!(%{title: "Empty", slug: "empty-seo"}, actor: editor)
      {_lv, html} = open_editor(conn, editor, page)

      # Checks with nothing to judge stay :n_a rather than shouting at an
      # author who has only just started.
      refute html =~ "rarely rank well"
      refute html =~ "No headings"
      refute html =~ "no alt text"
    end
  end

  describe "findings update live as the author types" do
    test "an over-long SEO title is reported with its measured length", %{conn: conn} do
      editor = authed_user(:editor)
      page = CMS.create_page!(%{title: "Length", slug: "length-seo"}, actor: editor)
      {lv, _html} = open_editor(conn, editor, page)

      html =
        change(lv, "seo_title", %{
          "title" => "Length",
          "slug" => "length-seo",
          "seo_title" => String.duplicate("a", 61)
        })

      assert html =~ "SEO title is 61 characters"
    end

    test "filling the description clears its warning", %{conn: conn} do
      editor = authed_user(:editor)
      page = CMS.create_page!(%{title: "Desc", slug: "desc-seo"}, actor: editor)
      {lv, html} = open_editor(conn, editor, page)

      assert html =~ "search engines will invent one"

      html =
        change(lv, "seo_description", %{
          "title" => "Desc",
          "slug" => "desc-seo",
          "seo_description" =>
            "A practical guide to kiln firing schedules, covering ramp rates, soak times and cone packs for the studio potter."
        })

      refute html =~ "search engines will invent one"
    end
  end

  describe "body-derived findings" do
    test "a page with images missing alt text reports an error", %{conn: conn} do
      editor = authed_user(:editor)

      page =
        CMS.create_page!(
          %{
            title: "Gallery",
            slug: "gallery-seo",
            blocks: prose_blocks() ++ [%{"_type" => "image", "url" => "/a.jpg", "alt" => ""}]
          },
          actor: editor
        )

      {_lv, html} = open_editor(conn, editor, page)

      assert html =~ "no alt text"
      assert html =~ "Poor"
    end

    test "thin content is reported with its word count", %{conn: conn} do
      editor = authed_user(:editor)

      page =
        CMS.create_page!(
          %{
            title: "Stub",
            slug: "stub-seo",
            blocks: [
              %{
                "_type" => "rich_text",
                "body" => [
                  %{
                    "_type" => "block",
                    "style" => "normal",
                    "children" => [%{"text" => "Only a handful of words live here."}]
                  }
                ]
              }
            ]
          },
          actor: editor
        )

      {_lv, html} = open_editor(conn, editor, page)
      assert html =~ "rarely rank well"
    end
  end

  describe "a well-formed page" do
    test "shows the good grade and no findings at all", %{conn: conn} do
      editor = authed_user(:editor)

      page =
        CMS.create_page!(
          %{
            title: "Understanding kiln firing",
            slug: "kiln-firing",
            seo_title: "Understanding kiln firing schedules for beginners",
            seo_description:
              "A practical guide to kiln firing schedules, covering ramp rates, soak times and cone packs for the studio potter.",
            seo_keywords: "kiln firing, glaze",
            seo_image: "/uploads/kiln.jpg",
            blocks: prose_blocks()
          },
          actor: editor
        )

      {_lv, html} = open_editor(conn, editor, page)

      assert html =~ "Good"
      refute html =~ "rarely rank well"
      refute html =~ "search engines will invent one"
      refute html =~ "focus keyphrase"
    end
  end

  describe "reusable fragments are expanded in the preview (#910)" do
    test "the Preview tab renders an embedded fragment's content, not empty", %{conn: conn} do
      editor = authed_user(:editor)
      # Publishing needs an admin actor (the editor's own policy check below
      # is what's under test, not who may publish).
      admin = authed_user(:admin)

      shared =
        CMS.create_page!(
          %{
            title: "Shared CTA",
            slug: "shared-cta-#{System.unique_integer([:positive])}",
            blocks: [%{"_type" => "heading", "text" => "Book a studio tour today"}]
          },
          actor: admin
        )
        |> then(&CMS.publish_page!(&1, %{}, actor: admin))

      host =
        CMS.create_page!(
          %{
            title: "Host",
            slug: "host-fragment-#{System.unique_integer([:positive])}",
            blocks: [%{"_type" => "fragment", "ref" => %{"type" => "page", "id" => shared.id}}]
          },
          actor: editor
        )

      {_lv, html} = open_editor(conn, editor, host)

      assert html =~ "Book a studio tour today"
    end

    test "the SEO word count includes an embedded fragment's words", %{conn: conn} do
      editor = authed_user(:editor)
      admin = authed_user(:admin)

      shared =
        CMS.create_page!(
          %{
            title: "Shared CTA",
            slug: "shared-cta-wc-#{System.unique_integer([:positive])}",
            blocks: prose_blocks()
          },
          actor: admin
        )
        |> then(&CMS.publish_page!(&1, %{}, actor: admin))

      empty_host =
        CMS.create_page!(
          %{title: "Empty host", slug: "empty-host-#{System.unique_integer([:positive])}"},
          actor: editor
        )

      fragment_host =
        CMS.create_page!(
          %{
            title: "Fragment host",
            slug: "fragment-host-#{System.unique_integer([:positive])}",
            blocks: [%{"_type" => "fragment", "ref" => %{"type" => "page", "id" => shared.id}}]
          },
          actor: editor
        )

      {empty_lv, _html} = open_editor(conn, editor, empty_host)
      {fragment_lv, _html} = open_editor(conn, editor, fragment_host)

      empty_count = :sys.get_state(empty_lv.pid).socket.assigns.seo_body_stats.word_count
      fragment_count = :sys.get_state(fragment_lv.pid).socket.assigns.seo_body_stats.word_count

      assert fragment_count > empty_count
    end
  end

  describe "social image" do
    defp media(attrs \\ %{}) do
      Ash.Seed.seed!(
        KilnCMS.CMS.MediaItem,
        Map.merge(
          %{
            filename: "card-#{System.unique_integer([:positive])}.jpg",
            url: "/uploads/card-#{System.unique_integer([:positive])}.jpg",
            alt: "A loaded kiln"
          },
          attrs
        )
      )
    end

    test "choosing from the library sets seo_image and clears the finding", %{conn: conn} do
      editor = authed_user(:editor)
      item = media()
      page = CMS.create_page!(%{title: "Social", slug: "social-seo"}, actor: editor)
      {lv, html} = open_editor(conn, editor, page)

      assert html =~ "No social image"

      render_click(lv, "open_seo_image_picker", %{})

      html =
        render_click(lv, "pick_image", %{
          "index" => "seo_image",
          "id" => item.id,
          "url" => item.url
        })

      assert html =~ item.url
      refute html =~ "links to this page will share without a preview picture"
    end

    test "\"use featured image\" copies the featured image url across", %{conn: conn} do
      editor = authed_user(:editor)
      item = media()

      page =
        CMS.create_page!(
          %{title: "Feat", slug: "feat-seo", featured_image_id: item.id},
          actor: editor
        )

      {lv, html} = open_editor(conn, editor, page)

      # A featured image alone does NOT satisfy og:image — delivery reads
      # seo_image only — so the advisory must still be showing.
      assert html =~ "links to this page will share without a preview picture"

      html = render_click(lv, "use_featured_image", %{})

      assert html =~ item.url
      refute html =~ "links to this page will share without a preview picture"
    end

    test "removing the social image brings the finding back", %{conn: conn} do
      editor = authed_user(:editor)

      page =
        CMS.create_page!(
          %{title: "Rm", slug: "rm-seo", seo_image: "/uploads/existing.jpg"},
          actor: editor
        )

      {lv, html} = open_editor(conn, editor, page)
      refute html =~ "links to this page will share without a preview picture"

      html = render_click(lv, "clear_seo_image", %{})
      assert html =~ "links to this page will share without a preview picture"
    end
  end

  describe "collaborative locking" do
    alias KilnCMSWeb.Presence

    test "a peer holding seo_image blocks the server-side write, not just the button",
         %{conn: conn} do
      editor = authed_user(:editor)
      item = media()

      page =
        CMS.create_page!(
          %{title: "Contended", slug: "lock-seo", featured_image_id: item.id},
          actor: editor
        )

      {lv, _html} = open_editor(conn, editor, page)

      topic = Presence.topic("page", page.id)
      cursor = %{id: "other-editor", name: "bob", field: "seo_image"}
      Phoenix.PubSub.broadcast(KilnCMS.PubSub, topic, {:cursor, cursor})
      assert render(lv) =~ "ring-warning"

      # The lock is advisory — a readonly input still submits — so the write
      # has to be refused in the handler. A replayed or stale-DOM event gets
      # here with the button disabled.
      html = render_click(lv, "use_featured_image", %{})

      assert seo_image_value(lv) == ""
      assert html =~ "Another editor is editing the social image"

      # Released when they move away.
      Phoenix.PubSub.broadcast(KilnCMS.PubSub, topic, {:cursor, %{cursor | field: nil}})
      render_click(lv, "use_featured_image", %{})
      assert seo_image_value(lv) == item.url
    end
  end

  describe "social preview card" do
    test "mirrors delivery's fallbacks: title falls back, description does not", %{conn: conn} do
      editor = authed_user(:editor)

      page =
        CMS.create_page!(
          %{title: "Plain page title", slug: "card-seo"},
          actor: editor
        )

      {lv, html} = open_editor(conn, editor, page)

      assert html =~ "Social preview"
      # No seo_title, so the card shows the page title (delivery does the same).
      assert html =~ "Plain page title"
      # No seo_description, and delivery has no excerpt fallback — say so
      # rather than inventing one.
      assert html =~ "search engines will write their own"

      html =
        change(lv, "seo_title", %{
          "title" => "Plain page title",
          "slug" => "card-seo",
          "seo_title" => "A sharper social headline"
        })

      assert html =~ "A sharper social headline"
    end

    test "on a tenant subdomain, the card shows that org's host, not the default (#557)",
         %{conn: conn} do
      # A platform admin passes `KilnCMS.CMS.Checks.OrgAdmin` on every org
      # (see `KilnCMS.CMS.Checks.OrgAdmin` moduledoc), so no org-membership
      # fixture is needed to read/edit a foreign org's content here.
      admin = authed_user(:admin)

      org =
        Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
          name: "Tenant Org",
          slug: "tenant-org-#{System.unique_integer([:positive])}",
          status: :active
        })

      page =
        CMS.create_page!(%{title: "Tenant page", slug: "tenant-card-seo"},
          actor: admin,
          tenant: org
        )

      host = "#{org.slug}.#{KilnCMSWeb.Tenant.base_host()}"
      {_lv, html} = open_editor(%{conn | host: host}, admin, page)

      # The card's host line (see the `p.text-xs.uppercase` in `social_card/1`).
      assert html =~ ~s(text-xs uppercase text-base-content/50">#{host}</p>)
    end
  end

  describe "findings link to the blocks they name" do
    test "a missing-alt finding links to the offending block", %{conn: conn} do
      editor = authed_user(:editor)

      page =
        CMS.create_page!(
          %{
            title: "Gallery",
            slug: "jump-seo",
            blocks: prose_blocks() ++ [%{"_type" => "image", "url" => "/a.jpg", "alt" => ""}]
          },
          actor: editor
        )

      {_lv, html} = open_editor(conn, editor, page)

      # The image is the third top-level block (index 2), shown 1-based.
      assert html =~ "no alt text"
      assert html =~ ~s(href="#block-2")
      assert html =~ "block 3"
    end
  end

  describe "internal links panel" do
    test "does not load until explicitly asked", %{conn: conn} do
      editor = authed_user(:editor)
      page = CMS.create_page!(%{title: "Links", slug: "links-lazy"}, actor: editor)
      {lv, html} = open_editor(conn, editor, page)

      # Never on mount: it costs a vector query plus a read per neighbour, and
      # most editing sessions never look at this panel.
      assert html =~ "Internal links"
      assert html =~ "Find related pages"
      refute html =~ "No related pages"

      render_click(lv, "seo_links_refresh", %{})
      # Explicit timeout: the suggest run is a vector query plus a read per
      # neighbour, which outruns render_async/1's 100ms default on a busy machine.
      loaded = render_async(lv, 2_000)

      assert loaded =~ "Refresh"
    end

    test "an empty result explains why rather than showing a blank list", %{conn: conn} do
      editor = authed_user(:editor)
      page = CMS.create_page!(%{title: "Links", slug: "links-empty"}, actor: editor)
      {lv, _html} = open_editor(conn, editor, page)

      render_click(lv, "seo_links_refresh", %{})
      html = render_async(lv, 2_000)

      # It used to say "Publish this page to index it", which stopped being the
      # reason when an unpublished anchor started getting a centroid computed in
      # memory (#852) — and publishing would not have helped an empty page
      # anyway. Semantic search is off in this suite, and the keyword fallback
      # builds its query from the title rather than the blocks, so the honest
      # answer here is the setting and not the empty body.
      assert html =~ "Enabling semantic search"
    end

    test "the Clipboard hook's copied event is handled", %{conn: conn} do
      # The hook (assets/js/app.js) pushes "copied" after writing to the
      # clipboard. This LiveView had no clause for it, so the push would have
      # crashed the whole editor the first time anyone used the copy button.
      editor = authed_user(:editor)
      page = CMS.create_page!(%{title: "Links", slug: "links-copy"}, actor: editor)
      {lv, _html} = open_editor(conn, editor, page)

      assert render_click(lv, "copied", %{}) =~ "Copied to clipboard"
      assert render(lv) =~ "SEO &amp; scheduling"
    end
  end

  describe "body stats stay fresh" do
    # The editor caches the body walk behind a hash of the typed blocks, so a
    # bug there would show up as findings frozen at their mount-time values.
    test "editing the body updates body-derived findings", %{conn: conn} do
      editor = authed_user(:editor)

      page =
        CMS.create_page!(
          %{
            title: "Gallery",
            slug: "fresh-seo",
            blocks: [%{"_type" => "image", "url" => "/a.jpg", "alt" => "A loaded kiln"}]
          },
          actor: editor
        )

      {lv, html} = open_editor(conn, editor, page)

      refute html =~ "no alt text"

      # Clearing the alt in the body must move the finding, not serve a cached
      # answer from mount.
      html =
        lv
        |> form("#page-editor")
        |> render_change(%{"form" => %{"blocks" => %{"0" => %{"alt" => ""}}}})

      assert html =~ "no alt text"

      # ...and restoring it must clear the finding again.
      html =
        lv
        |> form("#page-editor")
        |> render_change(%{"form" => %{"blocks" => %{"0" => %{"alt" => "A loaded kiln"}}}})

      refute html =~ "no alt text"
    end
  end

  describe "analysis never blocks a save" do
    test "a page with every warning still saves", %{conn: conn} do
      editor = authed_user(:editor)
      page = CMS.create_page!(%{title: "Messy", slug: "messy-seo"}, actor: editor)
      {lv, _html} = open_editor(conn, editor, page)

      html =
        change(lv, "seo_title", %{"title" => "Messy", "slug" => "messy-seo", "seo_title" => "x"})

      # The analysis complains loudly...
      assert html =~ "SEO title is short"

      # ...and the save goes through anyway. Findings are advice, never gates.
      lv |> form("#page-editor", form: %{seo_title: "x"}) |> render_submit()

      assert Ash.get!(KilnCMS.CMS.Page, page.id, actor: editor).seo_title == "x"
    end
  end
end

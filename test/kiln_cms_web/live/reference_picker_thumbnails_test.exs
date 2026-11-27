defmodule KilnCMSWeb.ReferencePickerThumbnailsTest do
  @moduledoc """
  Thumbnails in the reference picker (#3223): each search result, picked row
  and reverse-field row shows its record's featured image as a small,
  decorative thumbnail — the generated `"thumb"` variant, never the
  full-size original — loaded with the read that lists the rows, as the
  editor, so a search over many records costs one more query, not one per
  record.
  """
  # async: false — the query-count tests empty the node's caches before
  # measuring (`QueryCounting.warm_up/1`), which only a sync module may do.
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.Test.AccessibleNames
  alias KilnCMS.Test.QueryCounting

  @password "password123456"

  defp authed_user(role) do
    email = "ref-thumbs-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{"email" => email, "password" => @password},
        []
      )

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp uniq, do: System.unique_integer([:positive])

  # An uploaded image the pipeline has processed: its original, and the small
  # `"thumb"` variant the picker shows.
  defp image!(admin, attrs \\ %{}) do
    n = uniq()

    CMS.create_media_item!(
      Map.merge(
        %{
          filename: "thumb-#{n}.png",
          url: "/uploads/original-#{n}.png",
          content_type: "image/png",
          width: 2400,
          height: 1600,
          variants: %{"thumb" => %{"url" => "/uploads/thumb-#{n}.png", "width" => 150}}
        },
        attrs
      ),
      actor: admin
    )
  end

  defp thumb_url(image), do: image.variants["thumb"]["url"]

  defp page!(title, admin, image \\ nil) do
    CMS.create_page!(
      %{title: title, slug: "rt-#{uniq()}", featured_image_id: image && image.id},
      actor: admin
    )
  end

  defp post!(title, admin, attrs \\ %{}) do
    CMS.create_post!(Map.merge(%{title: title, slug: "rt-#{uniq()}"}, attrs), actor: admin)
  end

  defp field!(admin, name, extra) do
    CMS.create_field_definition!(
      Map.merge(
        %{content_type: :post, name: name, label: name, field_type: :reference},
        extra
      ),
      actor: admin
    )
  end

  setup do
    admin = authed_user(:admin)
    editor = authed_user(:editor)

    field!(admin, "rt_list", %{target_type: "page", multiple: true})
    field!(admin, "rt_mixed", %{target_types: ["page", "post"], multiple: true})
    field!(admin, "rt_pick", %{target_type: "page", widget: "dropdown"})

    # A word no other test's records carry, so a search is about these alone.
    word = "Quince#{uniq()}"
    image = image!(admin)
    with_image = page!("#{word} Alpha", admin, image)
    without_image = page!("#{word} Bravo", admin)
    post = post!("Spring", admin)

    %{
      admin: admin,
      editor: editor,
      word: word,
      image: image,
      with_image: with_image,
      without_image: without_image,
      post: post
    }
  end

  defp open_editor(conn, user, record, type \\ "post") do
    {:ok, lv, _html} = conn |> log_in(user) |> live(~p"/editor/content/#{type}/#{record.id}")
    lv
  end

  defp search(lv, field, query) do
    lv
    |> element("#custom-field-#{field}-search")
    |> render_change(%{"_kiln_ref_q" => %{field => query}})
  end

  defp option(field, id), do: "#custom-field-#{field}-opt-#{id}"
  defp row(field, id), do: "#cf-ref-#{field}-#{id}"

  defp thumb(lv, selector) do
    lv
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#{selector} img[data-ref-thumb]")
    |> Enum.map(fn img ->
      Map.new(LazyHTML.attributes(img) |> List.first())
    end)
  end

  defp placeholder?(lv, selector),
    do: has_element?(lv, "#{selector} [data-ref-thumb-placeholder]")

  describe "search results" do
    test "show the featured image's thumb variant, decorative, as the editor reads it", ctx do
      lv = open_editor(ctx.conn, ctx.editor, ctx.post)
      search(lv, "rt_list", ctx.word)

      assert [img] = thumb(lv, option("rt_list", ctx.with_image.id))
      assert img["src"] == thumb_url(ctx.image)
      assert img["alt"] == ""
      assert img["aria-hidden"] == "true"
      assert img["loading"] == "lazy"

      # The record without one has no image, but keeps the slot so the
      # titles line up.
      assert thumb(lv, option("rt_list", ctx.without_image.id)) == []
      assert placeholder?(lv, option("rt_list", ctx.without_image.id))
      refute placeholder?(lv, option("rt_list", ctx.with_image.id))
    end

    test "leave the option's role, state and accessible name as they were", ctx do
      lv = open_editor(ctx.conn, ctx.editor, ctx.post)
      html = search(lv, "rt_list", ctx.word)

      # The image adds nothing to the name: with the titles taken out, the
      # option with a thumbnail is named exactly as the one without.
      [with_name, without_name] =
        for page <- [ctx.with_image, ctx.without_image] do
          selector = option("rt_list", page.id)

          assert has_element?(
                   lv,
                   ~s(#{selector}[role="option"][aria-selected="false"][aria-disabled="false"])
                 )

          name = AccessibleNames.name(html, selector)
          assert String.starts_with?(name, page.title)
          String.replace_prefix(name, page.title, "")
        end

      assert with_name == without_name
      assert with_name =~ "Page"
    end

    test "render no slot at all when no result has a featured image", ctx do
      word = "Medlar#{uniq()}"
      bare = page!("#{word} One", ctx.admin)
      page!("#{word} Two", ctx.admin)

      lv = open_editor(ctx.conn, ctx.editor, ctx.post)
      search(lv, "rt_list", word)

      assert has_element?(lv, option("rt_list", bare.id))
      refute has_element?(lv, "#custom-field-rt_list-listbox img")
      refute has_element?(lv, "#custom-field-rt_list-listbox [data-ref-thumb-placeholder]")
    end

    test "never fall back to the full-size original when no thumb was generated", ctx do
      original = image!(ctx.admin, %{variants: %{}})
      page = page!("#{ctx.word} Charlie", ctx.admin, original)

      lv = open_editor(ctx.conn, ctx.editor, ctx.post)
      html = search(lv, "rt_list", ctx.word)

      assert thumb(lv, option("rt_list", page.id)) == []
      assert placeholder?(lv, option("rt_list", page.id))
      refute html =~ original.url
    end

    test "show a small original that the pipeline left without a thumb variant", ctx do
      small = image!(ctx.admin, %{width: 320, height: 200, variants: %{}})
      page = page!("#{ctx.word} Charlie", ctx.admin, small)

      lv = open_editor(ctx.conn, ctx.editor, ctx.post)
      search(lv, "rt_list", ctx.word)

      assert [img] = thumb(lv, option("rt_list", page.id))
      assert img["src"] == small.url
    end

    test "show a video's poster frame", ctx do
      video =
        image!(ctx.admin, %{
          content_type: "video/mp4",
          url: "/uploads/clip-#{uniq()}.mp4",
          variants: %{"poster" => %{"url" => "/uploads/poster-#{uniq()}.jpg"}}
        })

      page = page!("#{ctx.word} Delta", ctx.admin, video)

      lv = open_editor(ctx.conn, ctx.editor, ctx.post)
      search(lv, "rt_list", ctx.word)

      assert [img] = thumb(lv, option("rt_list", page.id))
      assert img["src"] == video.variants["poster"]["url"]
    end

    test "show nothing for a featured image in the trash, and don't fail", ctx do
      CMS.destroy_media_item!(ctx.image, actor: ctx.admin)

      lv = open_editor(ctx.conn, ctx.editor, ctx.post)
      search(lv, "rt_list", ctx.word)

      assert has_element?(lv, option("rt_list", ctx.with_image.id))
      refute has_element?(lv, "#custom-field-rt_list-listbox img")
    end

    test "a later page of results carries its thumbnails too", ctx do
      word = "Loquat#{uniq()}"
      for i <- 1..20, do: page!("#{word} A#{String.pad_leading("#{i}", 2, "0")}", ctx.admin)
      late_image = image!(ctx.admin)
      late = page!("#{word} Z", ctx.admin, late_image)

      lv = open_editor(ctx.conn, ctx.editor, ctx.post)
      search(lv, "rt_list", word)
      refute has_element?(lv, option("rt_list", late.id))

      lv |> element("#custom-field-rt_list-more") |> render_click()

      assert [img] = thumb(lv, option("rt_list", late.id))
      assert img["src"] == thumb_url(late_image)
    end

    test "span every allowed type", ctx do
      other_image = image!(ctx.admin)
      other_post = post!("#{ctx.word} Echo", ctx.admin, %{featured_image_id: other_image.id})

      lv = open_editor(ctx.conn, ctx.editor, ctx.post)
      search(lv, "rt_mixed", ctx.word)

      assert [page_img] = thumb(lv, option("rt_mixed", "page-#{ctx.with_image.id}"))
      assert page_img["src"] == thumb_url(ctx.image)
      assert [post_img] = thumb(lv, option("rt_mixed", "post-#{other_post.id}"))
      assert post_img["src"] == thumb_url(other_image)
    end
  end

  describe "picked rows" do
    test "a stored reference shows its thumbnail when the editor opens", ctx do
      post =
        post!("Summer", ctx.admin, %{
          custom_fields: %{
            "rt_list" => [%{"id" => ctx.with_image.id}, %{"id" => ctx.without_image.id}]
          }
        })

      lv = open_editor(ctx.conn, ctx.editor, post)

      assert [img] = thumb(lv, row("rt_list", ctx.with_image.id))
      assert img["src"] == thumb_url(ctx.image)
      assert img["alt"] == ""
      assert placeholder?(lv, row("rt_list", ctx.without_image.id))
    end

    test "a stored reference whose image is in the trash shows none", ctx do
      CMS.destroy_media_item!(ctx.image, actor: ctx.admin)

      post =
        post!("Autumn", ctx.admin, %{
          custom_fields: %{"rt_list" => [%{"id" => ctx.with_image.id}]}
        })

      lv = open_editor(ctx.conn, ctx.editor, post)

      assert has_element?(lv, row("rt_list", ctx.with_image.id), ctx.with_image.title)
      refute has_element?(lv, "#custom-field-rt_list-items img")
      refute placeholder?(lv, row("rt_list", ctx.with_image.id))
    end

    test "a picked search result keeps its thumbnail in the row", ctx do
      lv = open_editor(ctx.conn, ctx.editor, ctx.post)
      search(lv, "rt_list", ctx.word)
      lv |> element(option("rt_list", ctx.with_image.id)) |> render_click()

      assert [img] = thumb(lv, row("rt_list", ctx.with_image.id))
      assert img["src"] == thumb_url(ctx.image)
    end

    test "a choice from the dropdown shows its thumbnail at once", ctx do
      lv = open_editor(ctx.conn, ctx.editor, ctx.post)

      lv
      |> element("#custom-field-rt_pick-select")
      |> render_change(%{"_kiln_ref_pick" => %{"rt_pick" => ctx.with_image.id}})

      assert [img] = thumb(lv, row("rt_pick", ctx.with_image.id))
      assert img["src"] == thumb_url(ctx.image)
    end

    test "a record made with Add new connects as a row, beside a thumbnailed one", ctx do
      lv = open_editor(ctx.conn, ctx.editor, ctx.post)
      search(lv, "rt_list", ctx.word)
      lv |> element(option("rt_list", ctx.with_image.id)) |> render_click()

      lv |> element("#custom-field-rt_list-new-page") |> render_click()

      lv
      |> element("#custom-field-rt_list-new-form-title")
      |> render_change(%{"_kiln_ref_new" => %{"rt_list" => %{"title" => "#{ctx.word} Fresh"}}})

      lv |> element("#custom-field-rt_list-new-form-submit") |> render_click()

      [created] = CMS.list_pages!(actor: ctx.admin, query: [filter: [title: "#{ctx.word} Fresh"]])

      assert has_element?(lv, row("rt_list", created.id), "Draft")
      assert thumb(lv, row("rt_list", created.id)) == []
      assert placeholder?(lv, row("rt_list", created.id))
      assert [_img] = thumb(lv, row("rt_list", ctx.with_image.id))
    end
  end

  describe "reverse-field rows" do
    test "show the connecting record's thumbnail", ctx do
      field =
        field!(ctx.admin, "rt_parts_#{uniq()}", %{
          target_type: "page",
          multiple: true,
          inverse_label: "Posts using this page"
        })

      target = page!("Flour", ctx.admin)
      item = [%{"id" => target.id}]
      image = image!(ctx.admin)

      with_image =
        post!("Bread", ctx.admin, %{
          featured_image_id: image.id,
          custom_fields: %{field.name => item}
        })

      without_image = post!("Cake", ctx.admin, %{custom_fields: %{field.name => item}})

      lv = open_editor(ctx.conn, ctx.editor, target, "page")
      root = "#reverse-field-post-#{field.name}"

      assert [img] = thumb(lv, "#{root}-#{with_image.id}")
      assert img["src"] == thumb_url(image)
      assert img["alt"] == ""
      assert placeholder?(lv, "#{root}-#{without_image.id}")
    end
  end

  # One read per type lists the rows and one more loads every row's featured
  # image — never one query per record.
  describe "query count" do
    defp pages_with_images(admin, word, n) do
      for i <- 1..n, do: page!("#{word} #{i}", admin, image!(admin))
    end

    defp search_queries(lv, field, word) do
      {_html, queries} = QueryCounting.queries(fn -> search(lv, field, word) end)
      queries
    end

    test "a search costs the same for 2 results as for 6: one media read in all", ctx do
      [two, six, bare] = for _ <- 1..3, do: "Sorb#{uniq()}"
      pages_with_images(ctx.admin, two, 2)
      pages_with_images(ctx.admin, six, 6)
      for i <- 1..6, do: page!("#{bare} #{i}", ctx.admin)

      lv = open_editor(ctx.conn, ctx.editor, ctx.post)
      QueryCounting.warm_up(fn -> search(lv, "rt_list", ctx.word) end)
      # A component event is idle activity (#2491): the warm-up search sends the
      # page its one throttled `tokens` touch. `render/1` is a call to the
      # LiveView, so it returns only after that message is handled, and the
      # touch never lands inside a measured search.
      _ = render(lv)

      two_queries = search_queries(lv, "rt_list", two)
      six_queries = search_queries(lv, "rt_list", six)
      bare_queries = search_queries(lv, "rt_list", bare)

      QueryCounting.assert_same_queries(six_queries, two_queries, "6 results minus 2")
      # One media read for the whole page of results — the same read whether
      # the results have featured images or not.
      assert QueryCounting.by_source(six_queries)["media_items"] == 1

      QueryCounting.assert_same_queries(
        six_queries,
        bare_queries,
        "6 with images minus 6 without"
      )
    end

    test "a search over several types costs one media read per type", ctx do
      [two, six, bare] = for _ <- 1..3, do: "Loquat#{uniq()}"

      for {word, n} <- [{two, 1}, {six, 3}] do
        pages_with_images(ctx.admin, word, n)

        for i <- 1..n,
            do: post!("#{word} p#{i}", ctx.admin, %{featured_image_id: image!(ctx.admin).id})
      end

      for i <- 1..3, do: page!("#{bare} #{i}", ctx.admin)
      for i <- 1..3, do: post!("#{bare} p#{i}", ctx.admin)

      lv = open_editor(ctx.conn, ctx.editor, ctx.post)
      QueryCounting.warm_up(fn -> search(lv, "rt_mixed", ctx.word) end)
      # A component event is idle activity (#2491): the warm-up search sends the
      # page its one throttled `tokens` touch. `render/1` is a call to the
      # LiveView, so it returns only after that message is handled, and the
      # touch never lands inside a measured search.
      _ = render(lv)

      two_queries = search_queries(lv, "rt_mixed", two)
      six_queries = search_queries(lv, "rt_mixed", six)
      bare_queries = search_queries(lv, "rt_mixed", bare)

      QueryCounting.assert_same_queries(six_queries, two_queries, "6 results minus 2")
      # One media read per type read.
      assert QueryCounting.by_source(six_queries)["media_items"] == 2

      QueryCounting.assert_same_queries(
        six_queries,
        bare_queries,
        "6 with images minus 6 without"
      )
    end

    test "opening with 6 picked records costs the same as with 2", ctx do
      [two, six] =
        for n <- [2, 6] do
          items =
            ctx.admin
            |> pages_with_images("Rowan#{uniq()}", n)
            |> Enum.map(&%{"id" => &1.id})

          post!("Picked #{n}", ctx.admin, %{custom_fields: %{"rt_list" => items}})
        end

      conn = log_in(ctx.conn, ctx.editor)

      QueryCounting.warm_up(fn ->
        QueryCounting.page_queries(conn, ~p"/editor/content/post/#{two.id}")
      end)

      two_queries = QueryCounting.page_queries(conn, ~p"/editor/content/post/#{two.id}")
      six_queries = QueryCounting.page_queries(conn, ~p"/editor/content/post/#{six.id}")

      QueryCounting.assert_same_queries(six_queries, two_queries, "6 picked minus 2")
    end
  end
end

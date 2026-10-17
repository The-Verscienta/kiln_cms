defmodule KilnCMSWeb.ReferencePickerTest do
  @moduledoc """
  The content editor's reference picker (R9, `docs/relationships-plan.md`):
  search the target type as you type, add, remove and reorder a list of
  references, hold a single one — and never surface a record the editor
  could not read.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role, attrs \\ %{}) do
    email = "ref-picker-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: email,
          hashed_password: Bcrypt.hash_pwd_salt(@password),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )

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

  defp uniq, do: System.unique_integer([:positive])

  defp page!(title, admin, opts \\ []) do
    page = CMS.create_page!(%{title: "#{title} #{uniq()}", slug: "rp-#{uniq()}"}, actor: admin)
    if opts[:publish], do: CMS.publish_page!(page, %{}, actor: admin), else: page
  end

  setup do
    admin = authed_user(:admin)

    for {name, label, extra} <- [
          {"see_also", "See also", %{multiple: true, max_items: 3}},
          {"hero", "Hero page", %{}}
        ] do
      CMS.create_field_definition!(
        Map.merge(
          %{
            content_type: :post,
            name: name,
            label: label,
            field_type: :reference,
            target_type: "page"
          },
          extra
        ),
        actor: admin
      )
    end

    # A word no other test's pages carry, so a search is about these alone.
    word = "Zinnia#{uniq()}"

    published = page!("#{word} Alpha", admin, publish: true)
    draft = page!("#{word} Bravo", admin)
    other = page!("#{word} Charlie", admin, publish: true)
    post = CMS.create_post!(%{title: "Spring", slug: "rp-#{uniq()}"}, actor: admin)

    %{admin: admin, word: word, published: published, draft: draft, other: other, post: post}
  end

  defp open_editor(conn, user, post) do
    {:ok, lv, _html} = conn |> log_in(user) |> live(~p"/editor/content/post/#{post.id}")
    lv
  end

  defp search(lv, field, query) do
    lv
    |> element("#custom-field-#{field}-search")
    |> render_change(%{"_kiln_ref_q" => %{field => query}})
  end

  defp pick(lv, field, id),
    do: lv |> element("#custom-field-#{field}-opt-#{id}") |> render_click()

  defp option_ids(lv, field) do
    lv
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#custom-field-#{field}-listbox [role=option][phx-value-id]")
    |> LazyHTML.attribute("phx-value-id")
  end

  defp list_ids(lv, field) do
    lv
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#custom-field-#{field}-items input[type=hidden]")
    |> LazyHTML.attribute("value")
  end

  defp single_value(lv, field) do
    lv
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#custom-field-#{field} > input[type=hidden]")
    |> LazyHTML.attribute("value")
  end

  defp save(lv), do: lv |> form("#post-editor") |> render_submit()

  defp stored(post, admin),
    do: CMS.get_post!(post.id, actor: admin, tenant: post.org_id).custom_fields

  describe "search" do
    test "matches by title as the editor types, with each record's type and state", ctx do
      lv = open_editor(ctx.conn, ctx.admin, ctx.post)

      search_input = "#custom-field-see_also-search"
      assert has_element?(lv, "#{search_input}[role=combobox][aria-expanded=false]")

      html = search(lv, "see_also", "#{ctx.word} a")

      assert has_element?(lv, "#{search_input}[aria-expanded=true]")
      assert option_ids(lv, "see_also") == [ctx.published.id]
      assert html =~ "Page"
      assert has_element?(lv, "#custom-field-see_also-opt-#{ctx.published.id}", "Published")

      search(lv, "see_also", ctx.word)

      assert option_ids(lv, "see_also") == [ctx.published.id, ctx.draft.id, ctx.other.id]
      assert has_element?(lv, "#custom-field-see_also-opt-#{ctx.draft.id}", "Draft")

      assert search(lv, "see_also", "#{ctx.word} nothing-like-this") =~ "No matches for"

      lv |> element("#custom-field-see_also") |> render_hook("ref_close", %{})
      refute has_element?(lv, "#custom-field-see_also-listbox")
    end

    test "pages through every match instead of capping the list", ctx do
      batch = "Batch#{uniq()}"
      for n <- 1..23, do: page!("#{batch} #{String.pad_leading("#{n}", 2, "0")}", ctx.admin)

      lv = open_editor(ctx.conn, ctx.admin, ctx.post)
      search(lv, "see_also", batch)

      assert length(option_ids(lv, "see_also")) == 20
      lv |> element("#custom-field-see_also-more") |> render_click()

      assert length(option_ids(lv, "see_also")) == 23
      refute has_element?(lv, "#custom-field-see_also-more")
    end

    test "an empty search on focus lists the type's records", ctx do
      lv = open_editor(ctx.conn, ctx.admin, ctx.post)
      lv |> element("#custom-field-see_also-search") |> render_focus()

      assert has_element?(lv, "#custom-field-see_also-listbox")
      assert ctx.other.id in option_ids(lv, "see_also")
    end
  end

  describe "a list of references" do
    test "adds, reorders, removes and saves in order", ctx do
      %{published: a, draft: b, other: c} = ctx
      lv = open_editor(ctx.conn, ctx.admin, ctx.post)

      search(lv, "see_also", ctx.word)
      pick(lv, "see_also", b.id)
      pick(lv, "see_also", a.id)

      assert list_ids(lv, "see_also") == [b.id, a.id]
      # The list stays open for the next pick, without what is already picked.
      assert option_ids(lv, "see_also") == [c.id]
      search(lv, "see_also", ctx.word)
      assert option_ids(lv, "see_also") == [c.id]

      # Rows show the title, type and state, and open the target's editor.
      assert has_element?(lv, "#cf-ref-see_also-#{b.id}", "Draft")

      assert has_element?(
               lv,
               ~s(#cf-ref-see_also-#{a.id} a[href="/editor/content/page/#{a.id}"][target=_blank])
             )

      # Drag (the hook's `reorder`), then the keyboard path.
      lv
      |> element("#custom-field-see_also")
      |> render_hook("ref_reorder", %{"order" => [a.id, b.id]})

      assert list_ids(lv, "see_also") == [a.id, b.id]

      lv
      |> element("#cf-ref-see_also-#{b.id} button[phx-value-dir=up]")
      |> render_click()

      assert list_ids(lv, "see_also") == [b.id, a.id]

      save(lv)
      saved = stored(ctx.post, ctx.admin)["see_also"]
      assert Enum.map(saved, & &1["id"]) == [b.id, a.id]
      assert Enum.map(saved, & &1["title"]) == [b.title, a.title]

      # Removing every row clears the field.
      lv |> element("#cf-ref-see_also-#{b.id} button[data-ref-remove]") |> render_click()
      lv |> element("#cf-ref-see_also-#{a.id} button[data-ref-remove]") |> render_click()
      assert list_ids(lv, "see_also") == []

      save(lv)
      refute Map.has_key?(stored(ctx.post, ctx.admin), "see_also")
    end

    test "a dragged order can only reorder, never add or drop", ctx do
      %{published: a, draft: b, other: c} = ctx
      lv = open_editor(ctx.conn, ctx.admin, ctx.post)

      search(lv, "see_also", ctx.word)
      pick(lv, "see_also", a.id)
      pick(lv, "see_also", b.id)

      lv
      |> element("#custom-field-see_also")
      |> render_hook("ref_reorder", %{"order" => [c.id, b.id]})

      assert list_ids(lv, "see_also") == [b.id, a.id]
    end

    test "a full list stops offering more", ctx do
      lv = open_editor(ctx.conn, ctx.admin, ctx.post)
      extra = page!("#{ctx.word} Delta", ctx.admin, publish: true)

      search(lv, "see_also", ctx.word)
      for page <- [ctx.published, ctx.draft, ctx.other], do: pick(lv, "see_also", page.id)

      refute has_element?(lv, "#custom-field-see_also-search")
      assert render(lv) =~ "3 of 3"
      assert render(lv) =~ "The limit is reached."

      lv |> element("#custom-field-see_also") |> render_hook("ref_pick", %{"id" => extra.id})
      assert length(list_ids(lv, "see_also")) == 3
    end
  end

  describe "a single reference" do
    test "holds one record, replaced by removing and picking again", ctx do
      lv = open_editor(ctx.conn, ctx.admin, ctx.post)

      assert single_value(lv, "hero") == [""]
      search(lv, "hero", ctx.word)
      pick(lv, "hero", ctx.other.id)

      assert single_value(lv, "hero") == [ctx.other.id]
      assert has_element?(lv, "#cf-ref-hero-#{ctx.other.id}", "Published")
      refute has_element?(lv, "#custom-field-hero-search")
      # No list controls on a single reference.
      refute has_element?(lv, "#cf-ref-hero-#{ctx.other.id} button[phx-value-dir]")

      save(lv)
      assert stored(ctx.post, ctx.admin)["hero"]["id"] == ctx.other.id

      lv |> element("#cf-ref-hero-#{ctx.other.id} button[data-ref-remove]") |> render_click()
      assert single_value(lv, "hero") == [""]
      assert has_element?(lv, "#custom-field-hero-search")

      search(lv, "hero", ctx.word)
      pick(lv, "hero", ctx.published.id)
      save(lv)
      assert stored(ctx.post, ctx.admin)["hero"]["id"] == ctx.published.id

      lv |> element("#cf-ref-hero-#{ctx.published.id} button[data-ref-remove]") |> render_click()
      save(lv)
      refute stored(ctx.post, ctx.admin)["hero"]
    end
  end

  describe "read access" do
    test "a search never surfaces a record the editor can't read", ctx do
      # An editor whose read scope leaves out pages reads them as the public
      # does: published only.
      restricted = authed_user(:editor, %{readable_types: ["post"]})
      lv = open_editor(ctx.conn, restricted, ctx.post)

      html = search(lv, "see_also", ctx.word)

      assert option_ids(lv, "see_also") == [ctx.published.id, ctx.other.id]
      refute html =~ ctx.draft.title

      # Nor can a hand-made pick of it slip past the list.
      lv
      |> element("#custom-field-see_also")
      |> render_hook("ref_pick", %{"id" => ctx.draft.id})

      assert list_ids(lv, "see_also") == []
    end

    test "a stored reference the editor can't read stays, marked unavailable", ctx do
      post =
        CMS.update_post!(ctx.post, %{custom_fields: %{"see_also" => [ctx.draft.id]}},
          actor: ctx.admin
        )

      restricted = authed_user(:editor, %{readable_types: ["post"]})
      lv = open_editor(ctx.conn, restricted, post)

      assert list_ids(lv, "see_also") == [ctx.draft.id]
      assert has_element?(lv, "#cf-ref-see_also-#{ctx.draft.id}", ctx.draft.title)
      assert has_element?(lv, "#cf-ref-see_also-#{ctx.draft.id}", "Unavailable")
      refute has_element?(lv, "#cf-ref-see_also-#{ctx.draft.id} a[target=_blank]")
    end
  end
end

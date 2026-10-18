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

  describe "create and connect" do
    defp new_button(field, type \\ "page"), do: "#custom-field-#{field}-new-#{type}"
    defp new_form(field), do: "#custom-field-#{field}-new-form"

    defp fill_new(lv, field, params) do
      lv
      |> element("#{new_form(field)}-title")
      |> render_change(%{"_kiln_ref_new" => %{field => params}})
    end

    defp create(lv, field), do: lv |> element("#{new_form(field)}-submit") |> render_click()

    defp pages_titled(title, admin) do
      CMS.list_pages!(actor: admin, query: [filter: [title: title]])
    end

    test "creates a draft of the target type and adds it to the list", ctx do
      lv = open_editor(ctx.conn, ctx.admin, ctx.post)
      search(lv, "see_also", ctx.word)
      pick(lv, "see_also", ctx.published.id)

      assert has_element?(lv, new_button("see_also"), "Add new Page")
      lv |> element(new_button("see_also")) |> render_click()

      assert has_element?(lv, new_form("see_also"), "New Page")
      # The search's list closes, and the menu gives way to the form.
      refute has_element?(lv, "#custom-field-see_also-listbox")
      refute has_element?(lv, new_button("see_also"))

      title = "#{ctx.word} Fresh"
      fill_new(lv, "see_also", %{"title" => title})
      html = create(lv, "see_also")

      assert [created] = pages_titled(title, ctx.admin)
      assert created.state == :draft
      assert html =~ "Created “#{title}” as a draft and connected it."

      # Connected after what was there, as a pick would be — a row with a
      # Draft badge and a link to open it.
      assert list_ids(lv, "see_also") == [ctx.published.id, created.id]
      assert has_element?(lv, "#cf-ref-see_also-#{created.id}", "Draft")

      assert has_element?(
               lv,
               ~s(#cf-ref-see_also-#{created.id} a[href="/editor/content/page/#{created.id}"])
             )

      refute has_element?(lv, new_form("see_also"))
      assert has_element?(lv, new_button("see_also"))

      save(lv)

      assert Enum.map(stored(ctx.post, ctx.admin)["see_also"], & &1["id"]) ==
               [ctx.published.id, created.id]
    end

    test "fills a single reference, which then offers nothing more", ctx do
      lv = open_editor(ctx.conn, ctx.admin, ctx.post)

      lv |> element(new_button("hero")) |> render_click()
      fill_new(lv, "hero", %{"title" => "#{ctx.word} Hero"})
      create(lv, "hero")

      assert [created] = pages_titled("#{ctx.word} Hero", ctx.admin)
      assert single_value(lv, "hero") == [created.id]
      refute has_element?(lv, new_button("hero"))
      refute has_element?(lv, "#custom-field-hero-search")

      save(lv)
      assert stored(ctx.post, ctx.admin)["hero"]["id"] == created.id
    end

    test "asks for a title and the type's required fields, and creates nothing until given",
         ctx do
      CMS.create_field_definition!(
        %{
          content_type: :page,
          name: "subtitle",
          label: "Subtitle",
          field_type: :string,
          required: true
        },
        actor: ctx.admin
      )

      # A required field with a default doesn't need asking.
      CMS.create_field_definition!(
        %{
          content_type: :page,
          name: "tier",
          label: "Tier",
          field_type: :select,
          options: ["gold", "silver"],
          default: "silver",
          required: true
        },
        actor: ctx.admin
      )

      lv = open_editor(ctx.conn, ctx.admin, ctx.post)
      lv |> element(new_button("see_also")) |> render_click()

      assert has_element?(lv, "#{new_form("see_also")}-cf-subtitle")
      refute has_element?(lv, "#{new_form("see_also")}-cf-tier")

      assert create(lv, "see_also") =~ "Give it a title."

      title = "#{ctx.word} Needs more"
      fill_new(lv, "see_also", %{"title" => title})
      assert create(lv, "see_also") =~ "Subtitle (subtitle) is required"
      assert pages_titled(title, ctx.admin) == []
      assert list_ids(lv, "see_also") == []

      fill_new(lv, "see_also", %{"title" => title, "custom_fields" => %{"subtitle" => "Sub"}})
      create(lv, "see_also")

      assert [created] = pages_titled(title, ctx.admin)
      assert created.custom_fields["subtitle"] == "Sub"
      assert created.custom_fields["tier"] == "silver"
      assert list_ids(lv, "see_also") == [created.id]
    end

    test "cancel closes the form and creates nothing", ctx do
      lv = open_editor(ctx.conn, ctx.admin, ctx.post)
      lv |> element(new_button("see_also")) |> render_click()
      fill_new(lv, "see_also", %{"title" => "#{ctx.word} Never"})

      lv |> element("#{new_form("see_also")} button[data-ref-new-cancel]") |> render_click()

      refute has_element?(lv, new_form("see_also"))
      assert has_element?(lv, new_button("see_also"))
      assert pages_titled("#{ctx.word} Never", ctx.admin) == []
    end

    test "is not offered for a type with a required field the form can't render", ctx do
      CMS.create_field_definition!(
        %{content_type: :page, name: "cover", label: "Cover", field_type: :media, required: true},
        actor: ctx.admin
      )

      lv = open_editor(ctx.conn, ctx.admin, ctx.post)

      assert has_element?(lv, "#custom-field-see_also-search")
      refute has_element?(lv, new_button("see_also"))
    end

    test "creates an entry of an admin-defined target type", ctx do
      type =
        CMS.create_type_definition!(%{name: "ingr#{uniq()}", label: "Ingredient"},
          actor: ctx.admin
        )

      CMS.create_field_definition!(
        %{
          content_type: :post,
          name: "ingredients",
          label: "Ingredients",
          field_type: :reference,
          target_type: type.name,
          multiple: true
        },
        actor: ctx.admin
      )

      lv = open_editor(ctx.conn, ctx.admin, ctx.post)
      lv |> element(new_button("ingredients", type.name)) |> render_click()
      fill_new(lv, "ingredients", %{"title" => "#{ctx.word} Basil"})
      create(lv, "ingredients")

      assert [created] =
               KilnCMS.CMS.ContentTypes.list!(type.name,
                 actor: ctx.admin,
                 tenant: ctx.post.org_id,
                 query: [filter: [title: "#{ctx.word} Basil"]]
               )

      assert created.state == :draft
      assert list_ids(lv, "ingredients") == [created.id]

      # Admin-defined types are authored under one `entry` grant.
      scoped = authed_user(:editor, %{editable_types: ["post"]})
      lv = open_editor(ctx.conn, scoped, ctx.post)
      refute has_element?(lv, new_button("ingredients", type.name))
    end

    test "is hidden from an editor who may not create the target type", ctx do
      scoped = authed_user(:editor, %{editable_types: ["post"]})
      lv = open_editor(ctx.conn, scoped, ctx.post)

      assert has_element?(lv, "#custom-field-see_also-search")
      refute has_element?(lv, new_button("see_also"))

      # Nor does a hand-sent event open the form or create anything.
      lv |> element("#custom-field-see_also") |> render_hook("ref_new", %{"type" => "page"})
      refute has_element?(lv, new_form("see_also"))

      # An editor who may author pages is offered it.
      unscoped = authed_user(:editor)
      lv = open_editor(ctx.conn, unscoped, ctx.post)
      assert has_element?(lv, new_button("see_also"), "Add new Page")
    end

    test "a full list offers no Add new, and a stale form can't overfill it", ctx do
      lv = open_editor(ctx.conn, ctx.admin, ctx.post)
      search(lv, "see_also", ctx.word)
      pick(lv, "see_also", ctx.published.id)
      pick(lv, "see_also", ctx.draft.id)

      # Open the form at two of three, then fill the list another way.
      lv |> element(new_button("see_also")) |> render_click()
      fill_new(lv, "see_also", %{"title" => "#{ctx.word} Overflow"})
      search(lv, "see_also", ctx.word)
      pick(lv, "see_also", ctx.other.id)

      assert render(lv) =~ "3 of 3"
      refute has_element?(lv, new_button("see_also"))
      refute has_element?(lv, new_form("see_also"))

      lv |> element("#custom-field-see_also") |> render_hook("ref_new_create", %{})
      lv |> element("#custom-field-see_also") |> render_hook("ref_new", %{"type" => "page"})

      refute has_element?(lv, new_form("see_also"))
      assert pages_titled("#{ctx.word} Overflow", ctx.admin) == []
      assert length(list_ids(lv, "see_also")) == 3
    end
  end

  # R2: a field that allows several types searches all of them, shows each
  # result's type, and keys every row by `"type:id"`, which reaches the write
  # as `%{"id", "type"}` — so the saved snapshot keeps the type it was picked as.
  describe "several target types" do
    setup %{admin: admin, word: word} do
      for {name, extra} <- [{"mixed", %{multiple: true}}, {"lead", %{}}] do
        CMS.create_field_definition!(
          Map.merge(
            %{
              content_type: :post,
              name: name,
              label: name,
              field_type: :reference,
              target_types: ["page", "post"]
            },
            extra
          ),
          actor: admin
        )
      end

      other_post =
        CMS.create_post!(%{title: "#{word} Delta", slug: "rp-#{uniq()}"}, actor: admin)

      %{other_post: other_post}
    end

    test "offers Add new for each allowed type, and connects what it creates by its type", ctx do
      lv = open_editor(ctx.conn, ctx.admin, ctx.post)

      assert has_element?(lv, new_button("mixed", "page"), "Add new Page")
      assert has_element?(lv, new_button("mixed", "post"), "Add new Post")

      lv |> element(new_button("mixed", "post")) |> render_click()
      assert has_element?(lv, new_form("mixed"), "New Post")
      fill_new(lv, "mixed", %{"title" => "#{ctx.word} Echo"})
      create(lv, "mixed")

      [created] = CMS.list_posts!(actor: ctx.admin, query: [filter: [title: "#{ctx.word} Echo"]])
      assert created.state == :draft
      assert list_ids(lv, "mixed") == ["post:#{created.id}"]
      assert has_element?(lv, "#cf-ref-mixed-post-#{created.id}", "Draft")

      save(lv)
      assert [%{"type" => "post", "id" => id}] = stored(ctx.post, ctx.admin)["mixed"]
      assert id == created.id
    end

    test "search spans every allowed type; picks keep their type through a save", ctx do
      lv = open_editor(ctx.conn, ctx.admin, ctx.post)
      page_key = "page:#{ctx.published.id}"
      post_key = "post:#{ctx.other_post.id}"

      search(lv, "mixed", ctx.word)
      options = option_ids(lv, "mixed")
      assert page_key in options
      assert post_key in options
      assert "page:#{ctx.draft.id}" in options

      # Merged in title order across the two types.
      assert Enum.take(options, 4) == [
               page_key,
               "page:#{ctx.draft.id}",
               "page:#{ctx.other.id}",
               post_key
             ]

      assert lv |> element("#custom-field-mixed-opt-post-#{ctx.other_post.id}") |> render() =~
               "Post"

      pick(lv, "mixed", "post-#{ctx.other_post.id}")
      pick(lv, "mixed", "page-#{ctx.published.id}")
      assert list_ids(lv, "mixed") == [post_key, page_key]

      # A picked record leaves the results, by its own type.
      search(lv, "mixed", ctx.word)
      refute post_key in option_ids(lv, "mixed")
      refute page_key in option_ids(lv, "mixed")

      # Reordering keeps each item's type.
      lv
      |> element("#cf-ref-mixed-page-#{ctx.published.id} button[phx-value-dir=up]")
      |> render_click()

      assert list_ids(lv, "mixed") == [page_key, post_key]

      search(lv, "lead", ctx.word)
      pick(lv, "lead", "post-#{ctx.other_post.id}")
      assert single_value(lv, "lead") == [post_key]

      save(lv)

      fields = stored(ctx.post, ctx.admin)

      assert Enum.map(fields["mixed"], &{&1["type"], &1["id"]}) == [
               {"page", ctx.published.id},
               {"post", ctx.other_post.id}
             ]

      assert %{"type" => "post", "id" => id} = fields["lead"]
      assert id == ctx.other_post.id

      # Reopened, the stored snapshots render as typed rows again.
      lv = open_editor(ctx.conn, ctx.admin, ctx.post)
      assert list_ids(lv, "mixed") == [page_key, post_key]
      assert single_value(lv, "lead") == [post_key]
      assert has_element?(lv, "#cf-ref-mixed-post-#{ctx.other_post.id}", "Post")
    end
  end

  # R1b: a target whose field caps how many records may link to it is listed
  # but disabled once full, so the editor sees why it can't be picked.
  test "a full target is listed as full and can't be picked", %{
    conn: conn,
    admin: admin,
    word: word
  } do
    CMS.create_field_definition!(
      %{
        content_type: :post,
        name: "seat",
        label: "Seat",
        field_type: :reference,
        target_type: "page",
        max_sources: 1
      },
      actor: admin
    )

    full = page!("#{word} Delta", admin, publish: true)
    free = page!("#{word} Echo", admin, publish: true)

    holder =
      CMS.create_post!(
        %{title: "Holder", slug: "rp-#{uniq()}", custom_fields: %{"seat" => full.id}},
        actor: admin
      )

    post = CMS.create_post!(%{title: "Seeker", slug: "rp-#{uniq()}"}, actor: admin)
    lv = open_editor(conn, admin, post)

    html = search(lv, "seat", word)
    assert html =~ "Full — 1 of 1 connected"
    assert has_element?(lv, "#custom-field-seat-opt-#{full.id}[aria-disabled=true]")
    assert has_element?(lv, "#custom-field-seat-opt-#{free.id}[aria-disabled=false]")

    # A hand-sent pick of the full one changes nothing.
    lv |> with_target("#custom-field-seat") |> render_click("ref_pick", %{"id" => full.id})
    refute has_element?(lv, "#custom-field-seat input[type=hidden][value='#{full.id}']")

    # The record that holds the slot doesn't see its own target as full.
    lv = open_editor(conn, admin, holder)
    lv |> element("#custom-field-seat button[phx-click=ref_remove]") |> render_click()
    refute search(lv, "seat", word) =~ "Full — 1 of 1 connected"
  end
end

defmodule KilnCMSWeb.ReferenceDropdownTest do
  @moduledoc """
  The reference picker's dropdown widget (#2284): a single reference whose
  widget is `"dropdown"` lists its candidates in a `<select>` in place of the
  search. The value still lives in the picker's hidden input and picked row,
  a choice is a pick, and the list holds only what the editor could have
  found by searching — never a record of another site.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role, attrs \\ %{}) do
    email = "ref-dropdown-#{System.unique_integer([:positive])}@example.com"

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

  defp page!(title, admin, opts \\ []) do
    page = CMS.create_page!(%{title: "#{title} #{uniq()}", slug: "rd-#{uniq()}"}, actor: admin)
    if opts[:publish], do: CMS.publish_page!(page, %{}, actor: admin), else: page
  end

  defp field!(admin, name, extra \\ %{}) do
    CMS.create_field_definition!(
      Map.merge(
        %{
          content_type: :post,
          name: name,
          label: String.capitalize(name),
          field_type: :reference,
          target_type: "page",
          widget: "dropdown"
        },
        extra
      ),
      actor: admin
    )
  end

  setup do
    admin = authed_user(:admin)
    field!(admin, "hero")

    word = "Dahlia#{uniq()}"
    published = page!("#{word} Alpha", admin, publish: true)
    draft = page!("#{word} Bravo", admin)
    post = CMS.create_post!(%{title: "Spring", slug: "rd-#{uniq()}"}, actor: admin)

    %{admin: admin, word: word, published: published, draft: draft, post: post}
  end

  defp open_editor(conn, user, post) do
    {:ok, lv, _html} = conn |> log_in(user) |> live(~p"/editor/content/post/#{post.id}")
    lv
  end

  defp select(field), do: "#custom-field-#{field}-select"

  defp choose(lv, field, id),
    do: lv |> element(select(field)) |> render_change(%{"_kiln_ref_pick" => %{field => id}})

  defp option_values(lv, field) do
    lv
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#{select(field)} option")
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

  test "a select of the candidates replaces the search; a choice is a pick", ctx do
    lv = open_editor(ctx.conn, ctx.admin, ctx.post)

    assert has_element?(
             lv,
             ~s(select#{select("hero")}[name="_kiln_ref_pick[hero]"][aria-labelledby="custom-field-hero-label"])
           )

    refute has_element?(lv, "#custom-field-hero-search")
    # The value input is the picker's own, as with the search.
    assert single_value(lv, "hero") == [""]

    values = option_values(lv, "hero")
    assert List.first(values) == ""
    assert ctx.published.id in values
    assert ctx.draft.id in values
    # Title order.
    assert Enum.find_index(values, &(&1 == ctx.published.id)) <
             Enum.find_index(values, &(&1 == ctx.draft.id))

    choose(lv, "hero", ctx.draft.id)

    assert single_value(lv, "hero") == [ctx.draft.id]
    assert has_element?(lv, "#cf-ref-hero-#{ctx.draft.id}", "Draft")
    assert has_element?(lv, "#{select("hero")} option[value='#{ctx.draft.id}'][selected]")

    save(lv)
    assert stored(ctx.post, ctx.admin)["hero"]["id"] == ctx.draft.id

    # Another choice replaces it; "— None —" clears it.
    choose(lv, "hero", ctx.published.id)
    assert single_value(lv, "hero") == [ctx.published.id]
    save(lv)
    assert stored(ctx.post, ctx.admin)["hero"]["id"] == ctx.published.id

    choose(lv, "hero", "")
    assert single_value(lv, "hero") == [""]
    save(lv)
    refute stored(ctx.post, ctx.admin)["hero"]
  end

  test "lists only what the editor can read, and a hand-sent id changes nothing", ctx do
    restricted = authed_user(:editor, %{readable_types: ["post"]})
    lv = open_editor(ctx.conn, restricted, ctx.post)

    values = option_values(lv, "hero")
    assert ctx.published.id in values
    refute ctx.draft.id in values

    choose(lv, "hero", ctx.draft.id)
    assert single_value(lv, "hero") == [""]
  end

  test "never lists a record of another site", ctx do
    org =
      Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
        name: "Other site",
        slug: "rd-other-#{uniq()}",
        status: :active
      })

    elsewhere =
      CMS.create_page!(%{title: "#{ctx.word} Elsewhere", slug: "rd-#{uniq()}"},
        actor: ctx.admin,
        tenant: org
      )

    {:ok, _} = CMS.publish_page(elsewhere, %{}, actor: ctx.admin, tenant: org)

    lv = open_editor(ctx.conn, ctx.admin, ctx.post)
    values = option_values(lv, "hero")

    assert ctx.published.id in values
    refute elsewhere.id in values

    choose(lv, "hero", elsewhere.id)
    assert single_value(lv, "hero") == [""]
  end

  test "keeps the current pick as an option, even one the editor can't read", ctx do
    post =
      CMS.update_post!(ctx.post, %{custom_fields: %{"hero" => ctx.draft.id}}, actor: ctx.admin)

    lv = open_editor(ctx.conn, ctx.admin, post)
    assert has_element?(lv, "#{select("hero")} option[value='#{ctx.draft.id}'][selected]")

    restricted = authed_user(:editor, %{readable_types: ["post"]})
    lv = open_editor(ctx.conn, restricted, post)

    assert single_value(lv, "hero") == [ctx.draft.id]

    assert has_element?(
             lv,
             "#{select("hero")} option[value='#{ctx.draft.id}'][selected]",
             "Unavailable"
           )

    # Saving untouched keeps it.
    save(lv)
    assert stored(post, ctx.admin)["hero"]["id"] == ctx.draft.id
  end

  test "a target full under max_sources is listed, disabled, and can't be chosen", ctx do
    field!(ctx.admin, "seat", %{max_sources: 1})
    full = page!("#{ctx.word} Full", ctx.admin, publish: true)

    CMS.create_post!(
      %{title: "Holder", slug: "rd-#{uniq()}", custom_fields: %{"seat" => full.id}},
      actor: ctx.admin
    )

    lv = open_editor(ctx.conn, ctx.admin, ctx.post)

    assert has_element?(
             lv,
             "#{select("seat")} option[value='#{full.id}'][disabled]",
             "Full — 1 of 1 connected"
           )

    refute has_element?(lv, "#{select("seat")} option[value='#{ctx.published.id}'][disabled]")

    choose(lv, "seat", full.id)
    assert single_value(lv, "seat") == [""]
  end

  test "over the limit, the picker searches instead and says why", ctx do
    batch = "Batch#{uniq()}"
    for n <- 1..101, do: page!("#{batch} #{n}", ctx.admin)

    lv = open_editor(ctx.conn, ctx.admin, ctx.post)

    refute has_element?(lv, select("hero"))
    assert has_element?(lv, "#custom-field-hero-search[role=combobox]")
    assert has_element?(lv, "#custom-field-hero-too-many", "Too many to list — search instead.")
  end

  test "Add new leaves the new record picked, and shown in the select", ctx do
    lv = open_editor(ctx.conn, ctx.admin, ctx.post)

    lv |> element("#custom-field-hero-new-page") |> render_click()

    lv
    |> element("#custom-field-hero-new-form-title")
    |> render_change(%{"_kiln_ref_new" => %{"hero" => %{"title" => "#{ctx.word} Fresh"}}})

    lv |> element("#custom-field-hero-new-form-submit") |> render_click()

    [created] = CMS.list_pages!(actor: ctx.admin, query: [filter: [title: "#{ctx.word} Fresh"]])
    assert single_value(lv, "hero") == [created.id]

    assert has_element?(
             lv,
             "#{select("hero")} option[value='#{created.id}'][selected]",
             "#{ctx.word} Fresh"
           )

    save(lv)
    assert stored(ctx.post, ctx.admin)["hero"]["id"] == created.id
  end

  test "a row picked from the dropdown keeps its link inputs", ctx do
    field = field!(ctx.admin, "lead")

    CMS.create_field_definition!(
      %{link_of_id: field.id, name: "role", label: "Role", field_type: :string},
      actor: ctx.admin
    )

    lv = open_editor(ctx.conn, ctx.admin, ctx.post)
    choose(lv, "lead", ctx.published.id)

    link = "#cf-ref-lead-#{ctx.published.id}-link-role"

    assert has_element?(
             lv,
             ~s(input#{link}[name="form[_kiln_ref_link][lead][#{ctx.published.id}][role]"])
           )

    lv
    |> form("#post-editor")
    |> render_submit(%{
      "form" => %{"_kiln_ref_link" => %{"lead" => %{ctx.published.id => %{"role" => "cover"}}}}
    })

    assert %{"id" => id, "link" => %{"role" => "cover"}} = stored(ctx.post, ctx.admin)["lead"]
    assert id == ctx.published.id
  end

  test "several target types: one group per type, keyed by type", ctx do
    field!(ctx.admin, "feature", %{target_type: nil, target_types: ["page", "post"]})
    other = CMS.create_post!(%{title: "#{ctx.word} Post", slug: "rd-#{uniq()}"}, actor: ctx.admin)

    lv = open_editor(ctx.conn, ctx.admin, ctx.post)

    assert has_element?(
             lv,
             ~s(#{select("feature")} optgroup[label="Page"] option[value="page:#{ctx.published.id}"])
           )

    assert has_element?(
             lv,
             ~s(#{select("feature")} optgroup[label="Post"] option[value="post:#{other.id}"])
           )

    choose(lv, "feature", "post:#{other.id}")
    assert single_value(lv, "feature") == ["post:#{other.id}"]

    save(lv)
    assert %{"type" => "post", "id" => id} = stored(ctx.post, ctx.admin)["feature"]
    assert id == other.id
  end

  test "a field with no widget keeps the search", ctx do
    CMS.create_field_definition!(
      %{
        content_type: :post,
        name: "plain",
        label: "Plain",
        field_type: :reference,
        target_type: "page"
      },
      actor: ctx.admin
    )

    lv = open_editor(ctx.conn, ctx.admin, ctx.post)
    assert has_element?(lv, "#custom-field-plain-search")
    refute has_element?(lv, select("plain"))
  end
end

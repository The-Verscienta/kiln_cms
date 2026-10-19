defmodule KilnCMSWeb.RelatedContentPickerTest do
  @moduledoc """
  Related content through the reference picker (#2025, R9 in
  `docs/relationships-plan.md`): `related_<type>s` is searched, added,
  reordered and removed with the same picker a reference field uses, over
  the record's own type only, and saved through `related_<type>_ids` with the
  order kept in each link's `position`.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentLinks

  @password "password123456"
  @root "#custom-field-_related"

  defp authed_user(role, attrs \\ %{}) do
    email = "related-picker-#{System.unique_integer([:positive])}@example.com"

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

  defp post!(title, admin, opts \\ []) do
    post = CMS.create_post!(%{title: "#{title} #{uniq()}", slug: "rcp-#{uniq()}"}, actor: admin)
    if opts[:publish], do: CMS.publish_post!(post, %{}, actor: admin), else: post
  end

  setup do
    admin = authed_user(:admin)
    # A word no other test's records carry, so a search is about these alone.
    word = "Quillwort#{uniq()}"

    %{
      admin: admin,
      word: word,
      post: post!("#{word} Source", admin),
      a: post!("#{word} Alpha", admin, publish: true),
      b: post!("#{word} Bravo", admin),
      c: post!("#{word} Charlie", admin, publish: true),
      page: CMS.create_page!(%{title: "#{word} Page", slug: "rcp-#{uniq()}"}, actor: admin)
    }
  end

  defp open_editor(conn, user, post) do
    {:ok, lv, _html} = conn |> log_in(user) |> live(~p"/editor/content/post/#{post.id}")
    lv
  end

  defp search(lv, query) do
    lv
    |> element("#{@root}-search")
    |> render_change(%{"_kiln_ref_q" => %{"_related" => query}})
  end

  defp pick(lv, id), do: lv |> element("#{@root}-opt-#{id}") |> render_click()

  defp option_ids(lv) do
    lv
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#{@root}-listbox [role=option][phx-value-id]")
    |> LazyHTML.attribute("phx-value-id")
  end

  defp list_ids(lv) do
    lv
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#{@root}-items input[type=hidden]")
    |> LazyHTML.attribute("value")
  end

  defp row(id), do: "#cf-ref-_related-#{id}"

  defp save(lv), do: lv |> form("#post-editor") |> render_submit()

  defp related(post), do: ContentLinks.related_order(post)

  test "the old sibling select is gone; the picker posts related_post_ids", ctx do
    lv = open_editor(ctx.conn, ctx.admin, ctx.post)

    assert has_element?(lv, "#{@root}[data-reference-picker=_related]", "Related posts")
    assert has_element?(lv, ~s(#{@root} input[type=hidden][name="form[related_post_ids][]"]))
    refute has_element?(lv, ~s(select[name="form[related_post_ids][]"]))
  end

  test "searches its own type as the editor types, never the record itself", ctx do
    lv = open_editor(ctx.conn, ctx.admin, ctx.post)

    search(lv, ctx.word)
    ids = option_ids(lv)

    assert Enum.sort(ids) == Enum.sort([ctx.a.id, ctx.b.id, ctx.c.id])
    refute ctx.post.id in ids

    search(lv, "#{ctx.word} Alp")
    assert option_ids(lv) == [ctx.a.id]
  end

  test "offers no other type's records, even by title", ctx do
    lv = open_editor(ctx.conn, ctx.admin, ctx.post)

    search(lv, "#{ctx.word} Page")

    assert option_ids(lv) == []
    assert has_element?(lv, "#{@root}-listbox", "No matches")

    # Nor can a hand-made pick of one slip past the list.
    lv |> element(@root) |> render_hook("ref_pick", %{"id" => ctx.page.id})
    assert list_ids(lv) == []
  end

  test "adds, reorders, removes and saves the order as each link's position", ctx do
    %{a: a, b: b, c: c} = ctx
    lv = open_editor(ctx.conn, ctx.admin, ctx.post)

    search(lv, ctx.word)
    pick(lv, b.id)
    pick(lv, a.id)
    pick(lv, c.id)
    assert list_ids(lv) == [b.id, a.id, c.id]

    # Rows show the state and open the target's editor in a new tab.
    assert has_element?(lv, row(b.id), "Draft")

    assert has_element?(
             lv,
             ~s(#{row(a.id)} a[href="/editor/content/post/#{a.id}"][target=_blank])
           )

    save(lv)
    assert related(ctx.post) == [b.id, a.id, c.id]

    # Drag (the hook's reorder), then the keyboard path.
    lv |> element(@root) |> render_hook("ref_reorder", %{"order" => [c.id, b.id, a.id]})
    assert list_ids(lv) == [c.id, b.id, a.id]

    lv |> element("#{row(a.id)} button[phx-value-dir=up]") |> render_click()
    assert list_ids(lv) == [c.id, a.id, b.id]

    save(lv)
    assert related(ctx.post) == [c.id, a.id, b.id]

    positions =
      [
        actor: KilnCMS.CMS.Bookkeeping.system(),
        tenant: ctx.post.org_id,
        query: [filter: [source_id: ctx.post.id, kind: :related]]
      ]
      |> CMS.list_content_links!()
      |> Map.new(&{&1.target_id, &1.position})

    assert positions == %{c.id => 0, a.id => 1, b.id => 2}

    # A fresh editor shows the saved order.
    lv = open_editor(ctx.conn, ctx.admin, ctx.post)
    assert list_ids(lv) == [c.id, a.id, b.id]

    # Removing one, then every row, clears the list.
    lv |> element("#{row(a.id)} button[data-ref-remove]") |> render_click()
    assert list_ids(lv) == [c.id, b.id]
    save(lv)
    assert related(ctx.post) == [c.id, b.id]

    lv |> element("#{row(c.id)} button[data-ref-remove]") |> render_click()
    lv |> element("#{row(b.id)} button[data-ref-remove]") |> render_click()
    assert list_ids(lv) == []
    save(lv)
    assert related(ctx.post) == []
  end

  test "a published record holds the reordered list in its working copy", ctx do
    %{a: a, c: c} = ctx

    post =
      ctx.post
      |> then(&CMS.update_post!(&1, %{related_post_ids: [a.id, c.id]}, actor: ctx.admin))
      |> then(&CMS.publish_post!(&1, %{}, actor: ctx.admin))

    lv = open_editor(ctx.conn, ctx.admin, post)
    assert list_ids(lv) == [a.id, c.id]

    lv |> element(@root) |> render_hook("ref_reorder", %{"order" => [c.id, a.id]})
    save(lv)

    # Readers keep the published order until the changes are published.
    assert related(post) == [a.id, c.id]
    lv = open_editor(ctx.conn, ctx.admin, post)
    assert list_ids(lv) == [c.id, a.id]

    post = CMS.get_post!(post.id, actor: ctx.admin)
    CMS.publish_post_changes!(post, %{}, actor: ctx.admin)
    assert related(post) == [c.id, a.id]
  end

  test "a search never surfaces a related record the editor can't read", ctx do
    # An editor whose read scope leaves out posts reads them as the public
    # does: published only — so the draft is never offered.
    restricted = authed_user(:editor, %{readable_types: ["page"]})
    published = CMS.publish_post!(ctx.post, %{}, actor: ctx.admin)
    lv = open_editor(ctx.conn, restricted, published)

    html = search(lv, ctx.word)

    assert Enum.sort(option_ids(lv)) == Enum.sort([ctx.a.id, ctx.c.id])
    refute html =~ ctx.b.title

    lv |> element(@root) |> render_hook("ref_pick", %{"id" => ctx.b.id})
    assert list_ids(lv) == []
  end

  test "points at a multi-type reference field for cross-type links", ctx do
    lv = open_editor(ctx.conn, ctx.admin, ctx.post)

    assert has_element?(lv, "#related-content-hint", "reference field")
    assert has_element?(lv, ~s(#related-content-hint a[href="/editor/fields?type=post"]))

    # Editors can't open the fields admin, so they get the sentence alone.
    lv = open_editor(ctx.conn, authed_user(:editor), ctx.post)
    assert has_element?(lv, "#related-content-hint", "reference field")
    refute has_element?(lv, "#related-content-hint a")
  end
end

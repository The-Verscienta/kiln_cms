defmodule KilnCMSWeb.ReverseWritesLiveTest do
  @moduledoc """
  Editing a relationship from the target's side in the editor (R4b,
  `docs/relationships-plan.md`, decision D23): add through the picker,
  remove, move — each an edit of the source, so a published source's change
  shows as pending, a source the editor may not write shows a lock, and a
  lock conflict fails only its row.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role, attrs \\ %{}) do
    email = "reverse-w-lv-#{System.unique_integer([:positive])}@example.com"

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
  defp slug, do: "reverse-w-lv-#{uniq()}"

  defp post!(admin, title, fields, opts \\ []) do
    post = CMS.create_post!(%{title: title, slug: slug(), custom_fields: fields}, actor: admin)
    if opts[:publish], do: CMS.publish_post!(post, %{}, actor: admin), else: post
  end

  defp ids(post, field) do
    CMS.get_post!(post.id, authorize?: false).custom_fields
    |> Map.get(field)
    |> List.wrap()
    |> Enum.map(& &1["id"])
  end

  setup do
    admin = authed_user(:admin)
    word = "Quince#{uniq()}"

    field =
      CMS.create_field_definition!(
        %{
          content_type: :post,
          name: "ingredients_#{uniq()}",
          label: "Ingredients",
          field_type: :reference,
          target_type: "page",
          multiple: true,
          inverse_label: "Posts using this page"
        },
        actor: admin
      )

    target = CMS.create_page!(%{title: "Flour", slug: slug()}, actor: admin)
    other = CMS.create_page!(%{title: "Sugar", slug: slug()}, actor: admin)

    %{admin: admin, field: field.name, target: target, other: other, word: word}
  end

  defp open(user, page) do
    {:ok, lv, _html} =
      build_conn() |> log_in(user) |> live(~p"/editor/content/page/#{page.id}")

    lv
  end

  defp root(ctx), do: "#reverse-field-post-#{ctx.field}"
  defp row(ctx, source), do: "#{root(ctx)}-#{source.id}"
  defp picker(ctx), do: "#custom-field-reverse-post-#{ctx.field}"

  test "adds a connection through the picker, as an edit of the source", ctx do
    source = post!(ctx.admin, "#{ctx.word} Bread", %{ctx.field => [ctx.other.id]})
    lv = open(ctx.admin, ctx.target)

    refute has_element?(lv, row(ctx, source))

    lv
    |> element("#{picker(ctx)}-search")
    |> render_change(%{"_kiln_ref_q" => %{"reverse-post-#{ctx.field}" => ctx.word}})

    lv |> element("#{picker(ctx)}-opt-#{source.id}") |> render_click()

    # The pick reaches the reverse field as a `send_update`, which the view
    # handles after the click's own reply; a render waits for it.
    render(lv)

    assert ids(source, ctx.field) == [ctx.other.id, ctx.target.id]
    assert has_element?(lv, row(ctx, source), "No. 2 in its list")
    assert has_element?(lv, "#{root(ctx)}-notice", "Connected")

    # Already connected, so the search no longer offers it.
    lv
    |> element("#{picker(ctx)}-search")
    |> render_change(%{"_kiln_ref_q" => %{"reverse-post-#{ctx.field}" => ctx.word}})

    refute has_element?(lv, "#{picker(ctx)}-opt-#{source.id}")
  end

  test "removes and moves from this side", ctx do
    source = post!(ctx.admin, "Cake", %{ctx.field => [ctx.target.id, ctx.other.id]})
    lv = open(ctx.admin, ctx.target)

    lv |> element("#{row(ctx, source)} button[phx-value-dir=down]") |> render_click()
    assert ids(source, ctx.field) == [ctx.other.id, ctx.target.id]
    assert has_element?(lv, row(ctx, source), "No. 2 in its list")

    lv |> element("#{row(ctx, source)} [data-ref-remove]") |> render_click()
    assert ids(source, ctx.field) == [ctx.other.id]
    refute has_element?(lv, row(ctx, source))
  end

  test "a published source's change is pending until it is published, with a link to it", ctx do
    source = post!(ctx.admin, "Bread", %{ctx.field => [ctx.target.id]}, publish: true)
    lv = open(ctx.admin, ctx.target)

    lv |> element("#{row(ctx, source)} [data-ref-remove]") |> render_click()

    # Live is untouched; the row stays, marked, with a way back.
    assert ids(source, ctx.field) == [ctx.target.id]
    pending = "#{row(ctx, source)}-pending"
    assert has_element?(lv, pending, "Removal pending")
    assert has_element?(lv, pending, "goes live when “Bread” is published")
    assert has_element?(lv, "#{pending} a[href='/editor/content/post/#{source.id}']")
    assert has_element?(lv, "#{root(ctx)}-notice", "Saved to the working copy of “Bread”")

    lv |> element("#{row(ctx, source)} button", "Put back") |> render_click()
    refute has_element?(lv, pending)
  end

  test "a source the editor may not write is shown with a lock, not controls", ctx do
    source = post!(ctx.admin, "Cake", %{ctx.field => [ctx.target.id]})
    editor = authed_user(:editor, %{readable_types: ["page", "post"], editable_types: ["page"]})
    lv = open(editor, ctx.target)

    assert has_element?(lv, row(ctx, source), "Cake")
    assert has_element?(lv, "#{row(ctx, source)}-locked")
    refute has_element?(lv, "#{row(ctx, source)} [data-ref-remove]")
  end

  test "a lock conflict fails that row only", ctx do
    stale = post!(ctx.admin, "Apple", %{ctx.field => [ctx.target.id]})
    fresh = post!(ctx.admin, "Banana", %{ctx.field => [ctx.target.id]})
    lv = open(ctx.admin, ctx.target)

    # Someone saves "Apple" after this list was read.
    CMS.update_post!(stale, %{title: "Apple (edited)"}, actor: ctx.admin)

    lv |> element("#{row(ctx, stale)} [data-ref-remove]") |> render_click()

    assert has_element?(
             lv,
             "#{row(ctx, stale)}-error",
             "This record was updated by someone else. Please reload and try again."
           )

    assert ids(stale, ctx.field) == [ctx.target.id]

    lv |> element("#{row(ctx, fresh)} [data-ref-remove]") |> render_click()
    assert ids(fresh, ctx.field) == []

    # The list was read again, so a retry on the stale row now goes through.
    lv |> element("#{row(ctx, stale)} [data-ref-remove]") |> render_click()
    assert ids(stale, ctx.field) == []
  end

  # R1b: a field capping how many records may connect to one target shows the
  # count beside the reverse field's heading, and hides the add control while
  # the target is full.
  test "a capped reverse field shows its count and stops offering adds when full", ctx do
    field = CMS.get_field_definition!(ctx.field |> field_id(), authorize?: false)
    CMS.update_field_definition!(field, %{max_sources: 2}, actor: ctx.admin)

    post!(ctx.admin, "One", %{ctx.field => [ctx.target.id]})
    lv = open(ctx.admin, ctx.target)

    assert has_element?(lv, "#{root(ctx)}-capacity", "1 of 2")
    assert has_element?(lv, "#{picker(ctx)}-search")
    refute has_element?(lv, "#{root(ctx)}-full")

    # A draft holds its slot like any other source.
    post!(ctx.admin, "Two", %{ctx.field => [ctx.target.id]})
    lv = open(ctx.admin, ctx.target)

    assert has_element?(lv, "#{root(ctx)}-capacity", "2 of 2")
    assert has_element?(lv, "#{root(ctx)}-full", "Full — 2 of 2 connected")
    refute has_element?(lv, "#{picker(ctx)}-search")
  end

  defp field_id(name) do
    :post
    |> CMS.field_definitions_for!(authorize?: false)
    |> Enum.find(&(&1.name == name))
    |> Map.fetch!(:id)
  end
end

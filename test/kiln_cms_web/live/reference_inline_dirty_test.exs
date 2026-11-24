defmodule KilnCMSWeb.ReferenceInlineDirtyTest do
  @moduledoc """
  The parent editor's view of the record cards (#2283, PR 2b): a card with
  unsaved edits lights the unsaved-changes guard without touching the parent's
  save state, a dirty row cannot be removed or replaced, and a record created
  from the field opens its card.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role, attrs \\ %{}) do
    email = "ref-dty-#{System.unique_integer([:positive])}@example.com"

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

  defp field!(admin, name, extra \\ %{}) do
    CMS.create_field_definition!(
      Map.merge(
        %{
          content_type: :post,
          name: name,
          label: "Linked #{name}",
          field_type: :reference,
          target_type: "page",
          multiple: true,
          edit_inline: true
        },
        extra
      ),
      actor: admin
    )
  end

  defp page_field!(admin, name, type, extra \\ %{}) do
    CMS.create_field_definition!(
      Map.merge(%{content_type: :page, name: name, label: name, field_type: type}, extra),
      actor: admin
    )
  end

  defp post_with!(admin, field, pages) do
    value = Enum.map(pages, &%{"id" => &1.id, "type" => "page"})

    CMS.create_post!(
      %{title: "Host", slug: "rin-#{uniq()}", custom_fields: %{field => value}},
      actor: admin
    )
  end

  defp open_editor(conn, user, post) do
    {:ok, lv, _html} = conn |> log_in(user) |> live(~p"/editor/content/post/#{post.id}")
    lv
  end

  defp edit(lv, field, page, params) do
    base = "#cf-ref-#{field}-#{page.id}-inline"

    selector =
      if has_element?(lv, "#{base}-title"), do: "#{base}-title", else: "#{base}-f-ris_kicker"

    lv
    |> element(selector)
    |> render_change(%{"_kiln_inline" => %{field => %{page.id => params}}})
  end

  defp save(lv, field, page),
    do: lv |> element("#cf-ref-#{field}-#{page.id}-inline-save") |> render_click()

  defp open_card(lv, field, page),
    do: lv |> element("#cf-ref-#{field}-#{page.id}-inline-toggle") |> render_click()

  defp page!(admin, attrs \\ %{}) do
    CMS.create_page!(
      Map.merge(
        %{title: "Child #{uniq()}", slug: "ris-#{uniq()}", custom_fields: %{"ris_kicker" => "k"}},
        attrs
      ),
      actor: admin
    )
  end

  setup do
    admin = authed_user(:admin)
    page_field!(admin, "ris_kicker", :string)
    page_field!(admin, "ris_stars", :integer)
    page_field!(admin, "ris_media", :media)
    %{admin: admin}
  end

  defp dirty?(lv) do
    lv
    |> render()
    |> Floki.parse_document!()
    |> Floki.attribute("form[phx-change=validate]", "data-dirty")
  end

  defp discard(lv, field, page),
    do: lv |> element("#cf-ref-#{field}-#{page.id} [data-inline-discard]") |> render_click()

  describe "the unsaved-changes guard" do
    test "a dirty card lights data-dirty and a save or discard clears it", ctx do
      field!(ctx.admin, "rid_guard")
      page = page!(ctx.admin)
      post = post_with!(ctx.admin, "rid_guard", [page])
      lv = open_editor(build_conn(), ctx.admin, post)

      assert dirty?(lv) == ["false"]
      open_card(lv, "rid_guard", page)
      assert dirty?(lv) == ["false"]

      edit(lv, "rid_guard", page, %{"title" => "Typed"})
      assert dirty?(lv) == ["true"]

      save(lv, "rid_guard", page)
      assert dirty?(lv) == ["false"]

      edit(lv, "rid_guard", page, %{"title" => "Typed again"})
      assert dirty?(lv) == ["true"]
      discard(lv, "rid_guard", page)
      assert dirty?(lv) == ["false"]
    end

    test "it never schedules the parent's autosave or flips its save state", ctx do
      field!(ctx.admin, "rid_state")
      page = page!(ctx.admin)
      post = post_with!(ctx.admin, "rid_state", [page])
      lv = open_editor(build_conn(), ctx.admin, post)

      open_card(lv, "rid_state", page)
      edit(lv, "rid_state", page, %{"title" => "Typed"})

      assert %{save_state: :saved, autosave_timer: nil} =
               :sys.get_state(lv.pid).socket.assigns |> Map.take([:save_state, :autosave_timer])
    end

    test "two fields: the guard stays lit until both are clean", ctx do
      field!(ctx.admin, "rid_one")
      field!(ctx.admin, "rid_two")
      a = page!(ctx.admin)
      b = page!(ctx.admin)

      post =
        CMS.create_post!(
          %{
            title: "Host",
            slug: "rid-#{uniq()}",
            custom_fields: %{
              "rid_one" => [%{"id" => a.id, "type" => "page"}],
              "rid_two" => [%{"id" => b.id, "type" => "page"}]
            }
          },
          actor: ctx.admin
        )

      lv = open_editor(build_conn(), ctx.admin, post)
      open_card(lv, "rid_one", a)
      open_card(lv, "rid_two", b)
      edit(lv, "rid_one", a, %{"title" => "A!"})
      edit(lv, "rid_two", b, %{"title" => "B!"})
      assert dirty?(lv) == ["true"]

      save(lv, "rid_one", a)
      assert dirty?(lv) == ["true"]
      save(lv, "rid_two", b)
      assert dirty?(lv) == ["false"]
    end
  end

  describe "a row with unsaved card edits stays put" do
    test "Remove is refused, then works once the card is discarded", ctx do
      field!(ctx.admin, "rid_rm")
      page = page!(ctx.admin)
      post = post_with!(ctx.admin, "rid_rm", [page])
      lv = open_editor(build_conn(), ctx.admin, post)

      open_card(lv, "rid_rm", page)
      edit(lv, "rid_rm", page, %{"title" => "Typed"})

      lv |> element("#custom-field-rid_rm") |> render_hook("ref_remove", %{"id" => page.id})

      assert has_element?(lv, "#cf-ref-rid_rm-#{page.id}")
      assert render(lv) =~ "before removing it"

      discard(lv, "rid_rm", page)
      lv |> element("#custom-field-rid_rm") |> render_hook("ref_remove", %{"id" => page.id})
      refute has_element?(lv, "#cf-ref-rid_rm-#{page.id}")
      assert :sys.get_state(lv.pid).socket.assigns.inline_dirty == %{}
    end

    test "removing a clean row clears nothing it should keep, and the guard is not stuck", ctx do
      field!(ctx.admin, "rid_clean")
      page = page!(ctx.admin)
      post = post_with!(ctx.admin, "rid_clean", [page])
      lv = open_editor(build_conn(), ctx.admin, post)

      open_card(lv, "rid_clean", page)
      edit(lv, "rid_clean", page, %{"title" => "Typed"})
      discard(lv, "rid_clean", page)
      lv |> element("#custom-field-rid_clean") |> render_hook("ref_remove", %{"id" => page.id})

      assert :sys.get_state(lv.pid).socket.assigns.inline_dirty == %{}
    end

    test "a single reference cannot be replaced over a dirty card", ctx do
      field!(ctx.admin, "rid_single", %{multiple: false})
      page = page!(ctx.admin, %{title: "Swapme #{uniq()}"})
      other = page!(ctx.admin, %{title: "Swapto #{uniq()}"})

      post =
        CMS.create_post!(
          %{
            title: "Host",
            slug: "rid-#{uniq()}",
            custom_fields: %{"rid_single" => %{"id" => page.id, "type" => "page"}}
          },
          actor: ctx.admin
        )

      lv = open_editor(build_conn(), ctx.admin, post)
      open_card(lv, "rid_single", page)
      edit(lv, "rid_single", page, %{"title" => "Typed"})

      lv
      |> element("#custom-field-rid_single")
      |> render_hook("ref_search", %{"_kiln_ref_q" => %{"rid_single" => "Swapto"}})

      lv |> element("#custom-field-rid_single") |> render_hook("ref_pick", %{"id" => other.id})

      assert has_element?(lv, "#cf-ref-rid_single-#{page.id}")
      refute has_element?(lv, "#cf-ref-rid_single-#{other.id}")
    end
  end

  describe "the parent's Save saves dirty cards first (I3)" do
    defp settle(lv), do: Enum.each(1..6, fn _ -> render(lv) end)

    defp submit(lv, kind, params),
      do: lv |> form("##{kind}-editor") |> render_submit(%{"form" => params})

    test "saves each dirty card, then the parent", ctx do
      field!(ctx.admin, "rid_cas")
      a = page!(ctx.admin)
      b = page!(ctx.admin)
      post = post_with!(ctx.admin, "rid_cas", [a, b])
      lv = open_editor(build_conn(), ctx.admin, post)

      open_card(lv, "rid_cas", a)
      open_card(lv, "rid_cas", b)
      edit(lv, "rid_cas", a, %{"title" => "Card A"})
      edit(lv, "rid_cas", b, %{"title" => "Card B"})

      submit(lv, "post", %{"title" => "Parent now"})
      settle(lv)

      assert CMS.get_page!(a.id, actor: ctx.admin).title == "Card A"
      assert CMS.get_page!(b.id, actor: ctx.admin).title == "Card B"
      assert CMS.get_post!(post.id, actor: ctx.admin).title == "Parent now"
      assert :sys.get_state(lv.pid).socket.assigns.cascade == nil
      assert dirty?(lv) == ["false"]
    end

    test "stops at the first failure: later cards and the parent are not written", ctx do
      field!(ctx.admin, "rid_stop")
      a = page!(ctx.admin)
      b = page!(ctx.admin)
      post = post_with!(ctx.admin, "rid_stop", [a, b])
      lv = open_editor(build_conn(), ctx.admin, post)

      open_card(lv, "rid_stop", a)
      open_card(lv, "rid_stop", b)
      edit(lv, "rid_stop", a, %{"title" => ""})
      edit(lv, "rid_stop", b, %{"title" => "Card B"})

      submit(lv, "post", %{"title" => "Parent now"})
      settle(lv)

      html = render(lv)
      assert html =~ "this record was not saved"
      assert html =~ "Give it a title."
      assert CMS.get_page!(b.id, actor: ctx.admin).title == b.title
      assert CMS.get_post!(post.id, actor: ctx.admin).title == post.title
      assert :sys.get_state(lv.pid).socket.assigns.cascade == nil
      assert dirty?(lv) == ["true"]
    end

    test "a second Save after fixing the card goes through", ctx do
      field!(ctx.admin, "rid_retry")
      a = page!(ctx.admin)
      post = post_with!(ctx.admin, "rid_retry", [a])
      lv = open_editor(build_conn(), ctx.admin, post)

      open_card(lv, "rid_retry", a)
      edit(lv, "rid_retry", a, %{"title" => ""})
      submit(lv, "post", %{"title" => "Parent now"})
      settle(lv)
      assert CMS.get_post!(post.id, actor: ctx.admin).title == post.title

      edit(lv, "rid_retry", a, %{"title" => "Fixed"})
      submit(lv, "post", %{"title" => "Parent now"})
      settle(lv)

      assert CMS.get_page!(a.id, actor: ctx.admin).title == "Fixed"
      assert CMS.get_post!(post.id, actor: ctx.admin).title == "Parent now"
    end

    test "a parent with no dirty card saves as before", ctx do
      field!(ctx.admin, "rid_none")
      a = page!(ctx.admin)
      post = post_with!(ctx.admin, "rid_none", [a])
      lv = open_editor(build_conn(), ctx.admin, post)

      submit(lv, "post", %{"title" => "Plain save"})
      settle(lv)

      assert CMS.get_post!(post.id, actor: ctx.admin).title == "Plain save"
    end

    test "a workflow step saves dirty cards first", ctx do
      field!(ctx.admin, "rid_wf")
      a = page!(ctx.admin)
      post = post_with!(ctx.admin, "rid_wf", [a])
      lv = open_editor(build_conn(), ctx.admin, post)

      open_card(lv, "rid_wf", a)
      edit(lv, "rid_wf", a, %{"title" => "Before publish"})
      lv |> render_hook("workflow", %{"action" => "publish"})
      settle(lv)

      assert CMS.get_page!(a.id, actor: ctx.admin).title == "Before publish"
    end
  end

  describe "create from the field opens the card (I11)" do
    defp create_new(lv, field, title) do
      lv |> element("#custom-field-#{field}") |> render_hook("ref_new", %{"type" => "page"})

      lv
      |> element("#custom-field-#{field}-new-form-title")
      |> render_change(%{"_kiln_ref_new" => %{field => %{"title" => title}}})

      lv |> element("#custom-field-#{field}-new-form-submit") |> render_click()
    end

    test "the created draft's card is open and editable", ctx do
      field!(ctx.admin, "rid_new")
      post = post_with!(ctx.admin, "rid_new", [])
      lv = open_editor(build_conn(), ctx.admin, post)

      create_new(lv, "rid_new", "Fresh #{uniq()}")

      [created] = CMS.list_pages!(actor: ctx.admin, query: [filter: [state: :draft]])
      assert has_element?(lv, "#cf-ref-rid_new-#{created.id}-inline-title")
      assert has_element?(lv, "#cf-ref-rid_new-#{created.id}-inline-toggle[aria-expanded=true]")
    end

    test "a field without edit_inline gets a plain row", ctx do
      field!(ctx.admin, "rid_plain", %{edit_inline: nil})
      post = post_with!(ctx.admin, "rid_plain", [])
      lv = open_editor(build_conn(), ctx.admin, post)

      create_new(lv, "rid_plain", "Plain #{uniq()}")

      refute render(lv) =~ "-inline-title"
    end
  end
end

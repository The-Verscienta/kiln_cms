defmodule KilnCMSWeb.ReferenceInlineCascadeTest do
  @moduledoc """
  The parent's Save cascades into its dirty record cards (#2283, PR 3, I3):
  children first, in field and row order, each its own write; the first
  failure stops it and the parent is not written; a parent with no dirty card
  saves as it always did. A workflow transition settles the cards the same way.
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
    lv
    |> element("#cf-ref-#{field}-#{page.id}-inline-title")
    |> render_change(%{"_kiln_inline" => %{field => %{page.id => params}}})
  end

  defp open_card(lv, field, page),
    do: lv |> element("#cf-ref-#{field}-#{page.id}-inline-toggle") |> render_click()

  defp page!(admin, attrs \\ %{}) do
    CMS.create_page!(
      Map.merge(
        %{title: "Child #{uniq()}", slug: "ric-#{uniq()}", custom_fields: %{}},
        attrs
      ),
      actor: admin
    )
  end

  # The Save is a chain of messages (editor -> card -> editor), so wait for
  # the cascade to finish before looking at the page.
  defp save_parent(lv, title \\ nil) do
    form =
      if title,
        do: form(lv, "#post-editor", form: %{title: title}),
        else: form(lv, "#post-editor")

    render_submit(form)
    settle(lv)
  end

  defp settle(lv, tries \\ 50) do
    if tries > 0 and :sys.get_state(lv.pid).socket.assigns.cascade != nil do
      Process.sleep(10)
      settle(lv, tries - 1)
    else
      render(lv)
    end
  end

  defp title_of(page, admin), do: CMS.get_page!(page.id, actor: admin).title

  defp assigns(lv), do: :sys.get_state(lv.pid).socket.assigns

  setup do
    %{admin: authed_user(:admin)}
  end

  describe "Save with dirty cards" do
    test "saves each dirty child, then the parent, and says how many", ctx do
      field!(ctx.admin, "ric_ok")
      a = page!(ctx.admin)
      b = page!(ctx.admin)
      post = post_with!(ctx.admin, "ric_ok", [a, b])
      lv = open_editor(build_conn(), ctx.admin, post)

      open_card(lv, "ric_ok", a)
      open_card(lv, "ric_ok", b)
      edit(lv, "ric_ok", a, %{"title" => "A cascaded"})
      edit(lv, "ric_ok", b, %{"title" => "B cascaded"})

      html = save_parent(lv, "Host cascaded")

      assert title_of(a, ctx.admin) == "A cascaded"
      assert title_of(b, ctx.admin) == "B cascaded"
      assert CMS.get_post!(post.id, actor: ctx.admin).title == "Host cascaded"
      assert html =~ "Also saved 2 related records."
      assert assigns(lv).inline_dirty == %{}
      assert assigns(lv).cascade == nil
    end

    test "stops at the first failure: the parent and later cards are not saved", ctx do
      field!(ctx.admin, "ric_stop")
      a = page!(ctx.admin)
      b = page!(ctx.admin, %{title: "Bad before"})
      c = page!(ctx.admin)
      post = post_with!(ctx.admin, "ric_stop", [a, b, c])
      lv = open_editor(build_conn(), ctx.admin, post)

      for page <- [a, b, c], do: open_card(lv, "ric_stop", page)
      edit(lv, "ric_stop", a, %{"title" => "A saved"})
      edit(lv, "ric_stop", b, %{"title" => ""})
      edit(lv, "ric_stop", c, %{"title" => "C never"})

      html = save_parent(lv, "Host never")

      assert title_of(a, ctx.admin) == "A saved"
      assert title_of(b, ctx.admin) == "Bad before"
      assert title_of(c, ctx.admin) =~ "Child"
      assert CMS.get_post!(post.id, actor: ctx.admin).title == "Host"
      assert html =~ "Saved 1 related record, but couldn&#39;t save"
      assert html =~ "this record was not saved"
      assert html =~ "Give it a title."

      # The cards left dirty stay dirty; nothing was written for the parent.
      assert assigns(lv).inline_dirty == %{
               "ric_stop" => {"reference-picker-ric_stop", [b.id, c.id]}
             }

      assert assigns(lv).cascade == nil
    end

    test "after the failure is fixed, a second Save runs only the still-dirty cards", ctx do
      field!(ctx.admin, "ric_again")
      a = page!(ctx.admin)
      b = page!(ctx.admin)
      post = post_with!(ctx.admin, "ric_again", [a, b])
      lv = open_editor(build_conn(), ctx.admin, post)

      open_card(lv, "ric_again", a)
      open_card(lv, "ric_again", b)
      edit(lv, "ric_again", a, %{"title" => "A once"})
      edit(lv, "ric_again", b, %{"title" => ""})
      save_parent(lv, "Host twice")
      assert CMS.get_post!(post.id, actor: ctx.admin).title == "Host"

      edit(lv, "ric_again", b, %{"title" => "B fixed"})
      html = save_parent(lv, "Host twice")

      assert CMS.get_post!(post.id, actor: ctx.admin).title == "Host twice"
      assert title_of(b, ctx.admin) == "B fixed"
      assert html =~ "Also saved 1 related record."
    end

    test "a child changed by someone else stops the Save", ctx do
      field!(ctx.admin, "ric_stale")
      a = page!(ctx.admin)
      post = post_with!(ctx.admin, "ric_stale", [a])
      lv = open_editor(build_conn(), ctx.admin, post)

      open_card(lv, "ric_stale", a)
      edit(lv, "ric_stale", a, %{"title" => "Mine"})

      CMS.update_page!(CMS.get_page!(a.id, actor: ctx.admin), %{title: "Theirs"},
        actor: ctx.admin
      )

      html = save_parent(lv, "Host stale")

      assert title_of(a, ctx.admin) == "Theirs"
      assert CMS.get_post!(post.id, actor: ctx.admin).title == "Host"
      assert html =~ "Changed by someone else"
    end

    test "a published child's edit goes to its working copy, the live title stays", ctx do
      field!(ctx.admin, "ric_pub")
      a = page!(ctx.admin) |> then(&CMS.publish_page!(&1, %{}, actor: ctx.admin))
      post = post_with!(ctx.admin, "ric_pub", [a])
      lv = open_editor(build_conn(), ctx.admin, post)

      open_card(lv, "ric_pub", a)
      edit(lv, "ric_pub", a, %{"title" => "Next title"})
      save_parent(lv, "Host pub")

      row = CMS.get_page!(a.id, actor: ctx.admin)
      assert row.title == a.title
      assert row.working_title == "Next title"
      assert CMS.get_post!(post.id, actor: ctx.admin).title == "Host pub"
    end

    test "a parent conflict after the children committed keeps them Saved", ctx do
      field!(ctx.admin, "ric_conf")
      a = page!(ctx.admin)
      post = post_with!(ctx.admin, "ric_conf", [a])
      lv = open_editor(build_conn(), ctx.admin, post)

      open_card(lv, "ric_conf", a)
      edit(lv, "ric_conf", a, %{"title" => "Kept"})

      CMS.update_post!(CMS.get_post!(post.id, actor: ctx.admin), %{title: "Theirs"},
        actor: ctx.admin
      )

      html = save_parent(lv, "Mine")

      assert title_of(a, ctx.admin) == "Kept"
      assert CMS.get_post!(post.id, actor: ctx.admin).title == "Theirs"
      assert assigns(lv).conflict
      assert html =~ "Changed by someone else" or assigns(lv).conflict
      assert assigns(lv).inline_dirty == %{}
      assert has_element?(lv, "#cf-ref-ric_conf-#{a.id}-inline-toggle[aria-expanded=true]")
    end

    test "no dirty card: Save is what it was, with no related-record note", ctx do
      field!(ctx.admin, "ric_none")
      a = page!(ctx.admin)
      post = post_with!(ctx.admin, "ric_none", [a])
      lv = open_editor(build_conn(), ctx.admin, post)

      open_card(lv, "ric_none", a)
      html = save_parent(lv, "Host plain")

      assert CMS.get_post!(post.id, actor: ctx.admin).title == "Host plain"
      assert html =~ "Saved."
      refute html =~ "related record"
    end

    test "a card that never answers gives up instead of freezing Save", ctx do
      field!(ctx.admin, "ric_dead")
      a = page!(ctx.admin)
      post = post_with!(ctx.admin, "ric_dead", [a])
      lv = open_editor(build_conn(), ctx.admin, post)

      open_card(lv, "ric_dead", a)
      edit(lv, "ric_dead", a, %{"title" => "Typed"})

      # A cascade that is already running ignores a second Save.
      ref = make_ref()

      :sys.replace_state(lv.pid, fn state ->
        put_in(state.socket.assigns.cascade, %{
          ref: ref,
          queue: [],
          then: {:workflow, "none"},
          saved: 0,
          step: 1
        })
      end)

      render_submit(form(lv, "#post-editor", form: %{title: "Ignored"}))
      assert CMS.get_post!(post.id, actor: ctx.admin).title == "Host"

      send(lv.pid, {:cascade_timeout, ref, 1})
      assert render(lv) =~ "Couldn&#39;t save a related record"
      assert assigns(lv).cascade == nil
    end
  end

  describe "a workflow transition settles the cards first" do
    test "publishing saves the dirty card first", ctx do
      field!(ctx.admin, "ric_wf")
      a = page!(ctx.admin)
      post = post_with!(ctx.admin, "ric_wf", [a])
      lv = open_editor(build_conn(), ctx.admin, post)

      open_card(lv, "ric_wf", a)
      edit(lv, "ric_wf", a, %{"title" => "Before review"})

      lv
      |> element(~s(button[phx-click="workflow"][phx-value-action="publish"]))
      |> render_click()

      settle(lv)

      assert title_of(a, ctx.admin) == "Before review"
      assert CMS.get_post!(post.id, actor: ctx.admin).state == :published
      assert assigns(lv).inline_dirty == %{}
    end

    test "a failing card stops the transition", ctx do
      field!(ctx.admin, "ric_wfx")
      a = page!(ctx.admin)
      post = post_with!(ctx.admin, "ric_wfx", [a])
      lv = open_editor(build_conn(), ctx.admin, post)

      open_card(lv, "ric_wfx", a)
      edit(lv, "ric_wfx", a, %{"title" => ""})

      lv
      |> element(~s(button[phx-click="workflow"][phx-value-action="publish"]))
      |> render_click()

      settle(lv)

      assert CMS.get_post!(post.id, actor: ctx.admin).state == :draft
    end
  end
end

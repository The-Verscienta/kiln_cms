defmodule KilnCMSWeb.ReferenceInlineSaveTest do
  @moduledoc """
  The editing record card (#2283, PR 2a): a card's *Save* writes the child on
  its own with its own action, and nothing else moves. Draft and published
  children, a stale child, errors on the right card, grants, conditions, and
  every authorization-matrix row that applies to a save.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role, attrs \\ %{}) do
    email = "ref-sav-#{System.unique_integer([:positive])}@example.com"

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

  defp chip(lv, field, page),
    do: lv |> element("#cf-ref-#{field}-#{page.id}-inline-chip") |> render()

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

  describe "saving a draft child" do
    test "writes the child with :update, cuts a version, refreshes the struct", ctx do
      field!(ctx.admin, "ris_a")
      page = page!(ctx.admin)
      post = post_with!(ctx.admin, "ris_a", [page])
      host_versions = length(CMS.list_post_versions!(actor: ctx.admin))
      lv = open_editor(build_conn(), ctx.admin, post)
      open_card(lv, "ris_a", page)

      html =
        edit(lv, "ris_a", page, %{
          "title" => "Renamed",
          "custom_fields" => %{"ris_kicker" => "new k"}
        })

      assert html =~ "Unsaved changes"

      html = save(lv, "ris_a", page)
      assert html =~ "Saved"
      refute html =~ "Unsaved changes"

      saved = CMS.get_page!(page.id, actor: ctx.admin)
      assert saved.title == "Renamed"
      assert saved.custom_fields["ris_kicker"] == "new k"
      assert saved.state == :draft

      # The parent is untouched: no version of the host, its field is intact.
      assert length(CMS.list_post_versions!(actor: ctx.admin)) == host_versions

      # A second save works against the refreshed struct (no stale lock).
      edit(lv, "ris_a", page, %{"title" => "Renamed again"})
      save(lv, "ris_a", page)
      assert CMS.get_page!(page.id, actor: ctx.admin).title == "Renamed again"
      assert chip(lv, "ris_a", page) =~ "Saved"
    end

    test "only the changed keys are sent: a media value the card never shows survives", ctx do
      field!(ctx.admin, "ris_keep")
      page = page!(ctx.admin)
      post = post_with!(ctx.admin, "ris_keep", [page])
      lv = open_editor(build_conn(), ctx.admin, post)
      open_card(lv, "ris_keep", page)
      edit(lv, "ris_keep", page, %{"title" => "Only title"})
      save(lv, "ris_keep", page)

      saved = CMS.get_page!(page.id, actor: ctx.admin)
      assert saved.title == "Only title"
      assert saved.custom_fields["ris_kicker"] == "k"
    end

    test "a hand-posted key outside the card's editable set is ignored", ctx do
      field!(ctx.admin, "ris_forged")
      page = page!(ctx.admin)
      post = post_with!(ctx.admin, "ris_forged", [page])
      lv = open_editor(build_conn(), ctx.admin, post)
      open_card(lv, "ris_forged", page)

      edit(lv, "ris_forged", page, %{
        "title" => "T2",
        "custom_fields" => %{"ris_media" => "bogus", "ris_undefined" => "x", "ris_kicker" => "ok"},
        "slug" => "hacked",
        "state" => "published"
      })

      save(lv, "ris_forged", page)
      saved = CMS.get_page!(page.id, actor: ctx.admin)
      assert saved.title == "T2"
      assert saved.custom_fields["ris_kicker"] == "ok"
      refute Map.has_key?(saved.custom_fields, "ris_undefined")
      refute saved.custom_fields["ris_media"] == "bogus"
      assert saved.slug != "hacked"
      assert saved.state == :draft
    end

    test "a blank title stays on the card and writes nothing", ctx do
      field!(ctx.admin, "ris_blank")
      page = page!(ctx.admin)
      post = post_with!(ctx.admin, "ris_blank", [page])
      lv = open_editor(build_conn(), ctx.admin, post)
      open_card(lv, "ris_blank", page)
      edit(lv, "ris_blank", page, %{"title" => "  "})
      html = save(lv, "ris_blank", page)

      assert html =~ "Give it a title."
      assert html =~ "1 problem on this record"
      assert CMS.get_page!(page.id, actor: ctx.admin).title == page.title
    end
  end

  describe "saving a published child" do
    test "goes to the working copy only; the live row does not move", ctx do
      field!(ctx.admin, "ris_pub")
      page = page!(ctx.admin) |> then(&CMS.publish_page!(&1, %{}, actor: ctx.admin))
      post = post_with!(ctx.admin, "ris_pub", [page])
      lv = open_editor(build_conn(), ctx.admin, post)
      open_card(lv, "ris_pub", page)

      edit(lv, "ris_pub", page, %{
        "title" => "Held rename",
        "custom_fields" => %{"ris_kicker" => "held k"}
      })

      html = save(lv, "ris_pub", page)
      assert html =~ "Saved to the working copy"

      row = CMS.get_page!(page.id, actor: ctx.admin)
      assert row.title == page.title
      assert row.working_title == "Held rename"
      assert row.custom_fields["ris_kicker"] == "k"
      assert row.state == :published

      # The card now shows the working copy, and saves again without a stale lock.
      edit(lv, "ris_pub", page, %{"title" => "Held rename 2"})
      save(lv, "ris_pub", page)
      assert CMS.get_page!(page.id, actor: ctx.admin).working_title == "Held rename 2"
    end

    test "a blank title never reaches the working copy", ctx do
      field!(ctx.admin, "ris_pubblank")
      page = page!(ctx.admin) |> then(&CMS.publish_page!(&1, %{}, actor: ctx.admin))
      post = post_with!(ctx.admin, "ris_pubblank", [page])
      lv = open_editor(build_conn(), ctx.admin, post)
      open_card(lv, "ris_pubblank", page)
      edit(lv, "ris_pubblank", page, %{"title" => ""})
      html = save(lv, "ris_pubblank", page)

      assert html =~ "Give it a title."
      assert CMS.get_page!(page.id, actor: ctx.admin).working_title == nil
    end
  end

  describe "a child that changed under the card" do
    test "another editor's save is refused as stale and nothing is overwritten", ctx do
      field!(ctx.admin, "ris_stale")
      page = page!(ctx.admin)
      post = post_with!(ctx.admin, "ris_stale", [page])
      lv = open_editor(build_conn(), ctx.admin, post)
      open_card(lv, "ris_stale", page)
      edit(lv, "ris_stale", page, %{"title" => "Mine"})

      CMS.update_page!(CMS.get_page!(page.id, actor: ctx.admin), %{title: "Theirs"},
        actor: ctx.admin
      )

      html = save(lv, "ris_stale", page)
      assert html =~ "Someone changed this record since you opened it"
      assert html =~ "Reload this record"
      assert CMS.get_page!(page.id, actor: ctx.admin).title == "Theirs"

      # Reload discards the card's draft and shows the current record.
      html =
        lv
        |> element("#cf-ref-ris_stale-#{page.id}-inline-card [data-inline-reload]")
        |> render_click()

      assert html =~ "Theirs"
      refute html =~ "Someone changed this record"
    end

    test "a draft published meanwhile is refused; the live row is untouched", ctx do
      field!(ctx.admin, "ris_pubmeanwhile")
      page = page!(ctx.admin)
      post = post_with!(ctx.admin, "ris_pubmeanwhile", [page])
      lv = open_editor(build_conn(), ctx.admin, post)
      open_card(lv, "ris_pubmeanwhile", page)
      edit(lv, "ris_pubmeanwhile", page, %{"title" => "Mine"})

      published =
        CMS.publish_page!(CMS.get_page!(page.id, actor: ctx.admin), %{}, actor: ctx.admin)

      html = save(lv, "ris_pubmeanwhile", page)

      assert html =~ "Someone changed this record"
      row = CMS.get_page!(page.id, actor: ctx.admin)
      assert row.state == :published
      assert row.title == published.title
    end

    test "a child trashed after the card opened is refused on save", ctx do
      field!(ctx.admin, "ris_trashed")
      page = page!(ctx.admin)
      post = post_with!(ctx.admin, "ris_trashed", [page])
      lv = open_editor(build_conn(), ctx.admin, post)
      open_card(lv, "ris_trashed", page)
      edit(lv, "ris_trashed", page, %{"title" => "Mine"})

      CMS.destroy_page!(CMS.get_page!(page.id, actor: ctx.admin), actor: ctx.admin)
      html = save(lv, "ris_trashed", page)

      assert html =~ "can no longer be opened here"
    end
  end

  describe "errors and failures stay on one card" do
    test "a validation error lands on its own card; the other card still saves", ctx do
      field!(ctx.admin, "ris_two")
      a = page!(ctx.admin)
      b = page!(ctx.admin)
      post = post_with!(ctx.admin, "ris_two", [a, b])
      lv = open_editor(build_conn(), ctx.admin, post)
      open_card(lv, "ris_two", a)
      open_card(lv, "ris_two", b)

      edit(lv, "ris_two", a, %{"custom_fields" => %{"ris_stars" => "not a number"}})
      edit(lv, "ris_two", b, %{"title" => "B renamed"})

      html = save(lv, "ris_two", a)
      assert lv |> element("#cf-ref-ris_two-#{a.id}-inline-card") |> render() =~ "problem"
      refute lv |> element("#cf-ref-ris_two-#{b.id}-inline-card") |> render() =~ "problem"
      assert html =~ "Error"

      save(lv, "ris_two", b)
      assert CMS.get_page!(b.id, actor: ctx.admin).title == "B renamed"
      assert CMS.get_page!(a.id, actor: ctx.admin).custom_fields["ris_stars"] in [nil, ""]
    end

    test "a unique field's error shows on the card", ctx do
      page_field!(ctx.admin, "ris_sku", :string, %{validation: %{"unique" => true}})
      field!(ctx.admin, "ris_uniq")
      one = page!(ctx.admin, %{custom_fields: %{"ris_sku" => "A-1"}})
      two = page!(ctx.admin, %{custom_fields: %{"ris_sku" => "B-2"}})
      post = post_with!(ctx.admin, "ris_uniq", [two])
      lv = open_editor(build_conn(), ctx.admin, post)
      open_card(lv, "ris_uniq", two)
      edit(lv, "ris_uniq", two, %{"custom_fields" => %{"ris_sku" => "A-1"}})
      html = save(lv, "ris_uniq", two)

      assert html =~ "ris_sku"
      assert CMS.get_page!(two.id, actor: ctx.admin).custom_fields["ris_sku"] == "B-2"
      assert CMS.get_page!(one.id, actor: ctx.admin).custom_fields["ris_sku"] == "A-1"
    end
  end

  describe "authorization" do
    test "a title the editor's grant withholds is read-only and a posted title is ignored", ctx do
      field!(ctx.admin, "ris_grant")
      page = page!(ctx.admin)
      post = post_with!(ctx.admin, "ris_grant", [page])
      editor = authed_user(:editor, %{field_grants: %{"page" => ["custom_fields.ris_kicker"]}})
      lv = open_editor(build_conn(), editor, post)
      open_card(lv, "ris_grant", page)

      html = render(lv)
      refute html =~ ~s(name="_kiln_inline[ris_grant][#{page.id}][title]")
      assert html =~ ~s(name="_kiln_inline[ris_grant][#{page.id}][custom_fields][ris_kicker]")
      # A field outside the grant is shown, not editable.
      refute html =~ ~s(name="_kiln_inline[ris_grant][#{page.id}][custom_fields][ris_stars]")

      edit(lv, "ris_grant", page, %{
        "title" => "Hacked",
        "custom_fields" => %{"ris_kicker" => "granted", "ris_stars" => "9"}
      })

      save(lv, "ris_grant", page)
      saved = CMS.get_page!(page.id, actor: ctx.admin)
      assert saved.title == page.title
      assert saved.custom_fields["ris_kicker"] == "granted"
      refute saved.custom_fields["ris_stars"] == 9
    end

    test "the parent record never gets a card on its own field", ctx do
      CMS.create_field_definition!(
        %{
          content_type: :post,
          name: "ris_self",
          label: "Self",
          field_type: :reference,
          target_type: "post",
          multiple: true,
          edit_inline: true
        },
        actor: ctx.admin
      )

      post = CMS.create_post!(%{title: "Me", slug: "ris-#{uniq()}"}, actor: ctx.admin)

      post =
        CMS.update_post!(
          post,
          %{custom_fields: %{"ris_self" => [%{"id" => post.id, "type" => "post"}]}},
          actor: ctx.admin
        )

      lv = open_editor(build_conn(), ctx.admin, post)
      assert has_element?(lv, "#cf-ref-ris_self-#{post.id}")
      refute has_element?(lv, "#cf-ref-ris_self-#{post.id}-inline-toggle")
    end

    test "a card for a parent field the actor cannot write still saves under the child's policy",
         ctx do
      field!(ctx.admin, "ris_locked")
      page = page!(ctx.admin)
      post = post_with!(ctx.admin, "ris_locked", [page])
      editor = authed_user(:editor, %{field_grants: %{"post" => ["title"]}})
      lv = open_editor(build_conn(), editor, post)

      # Parent field is read-only for this editor; the page is writable for them.
      assert has_element?(lv, "#cf-ref-ris_locked-#{page.id}-inline-toggle")
      open_card(lv, "ris_locked", page)
      edit(lv, "ris_locked", page, %{"title" => "By a granted editor"})
      save(lv, "ris_locked", page)

      assert CMS.get_page!(page.id, actor: ctx.admin).title == "By a granted editor"
    end

    test "a read-only editor has no card and a forged toggle does nothing", ctx do
      field!(ctx.admin, "ris_viewer")
      page = page!(ctx.admin)
      post = post_with!(ctx.admin, "ris_viewer", [page])
      editor = authed_user(:editor, %{editable_types: ["post"]})
      lv = open_editor(build_conn(), editor, post)

      refute has_element?(lv, "#cf-ref-ris_viewer-#{page.id}-inline-toggle")

      lv
      |> element("#custom-field-ris_viewer")
      |> render_hook("inline_toggle", %{"id" => page.id})

      refute render(lv) =~ "data-inline-card"
    end
  end

  describe "conditions on the child form" do
    test "a field shows and hides as the card's values change", ctx do
      page_field!(ctx.admin, "ris_flag", :boolean)

      page_field!(ctx.admin, "ris_why", :string, %{
        visible_when: %{"field" => "ris_flag", "op" => "eq", "value" => true}
      })

      field!(ctx.admin, "ris_cond")
      page = page!(ctx.admin)
      post = post_with!(ctx.admin, "ris_cond", [page])
      lv = open_editor(build_conn(), ctx.admin, post)
      html = open_card(lv, "ris_cond", page)

      refute html =~ ~s([ris_why])

      html = edit(lv, "ris_cond", page, %{"custom_fields" => %{"ris_flag" => "true"}})
      assert html =~ ~s([custom_fields][ris_why])

      html = edit(lv, "ris_cond", page, %{"custom_fields" => %{"ris_flag" => "false"}})
      refute html =~ ~s([custom_fields][ris_why])
    end
  end

  test "a card edit does not touch the parent form's save state", ctx do
    field!(ctx.admin, "ris_parent")
    page = page!(ctx.admin)
    post = post_with!(ctx.admin, "ris_parent", [page])
    lv = open_editor(build_conn(), ctx.admin, post)

    before =
      render(lv)
      |> Floki.parse_document!()
      |> Floki.attribute("form[phx-change=validate]", "data-dirty")

    open_card(lv, "ris_parent", page)
    edit(lv, "ris_parent", page, %{"title" => "Typed"})

    after_edit =
      render(lv)
      |> Floki.parse_document!()
      |> Floki.attribute("form[phx-change=validate]", "data-dirty")

    # The guard lights (the card has unsaved edits), but the parent's own
    # save state does not move: no autosave, no "unsaved" chip on the parent.
    assert before == ["false"]
    assert after_edit == ["true"]
    assert %{save_state: :saved} = :sys.get_state(lv.pid).socket.assigns
    assert CMS.get_post!(post.id, actor: ctx.admin).title == post.title
  end

  test "the card's inputs are stripped from the parent's params" do
    params = %{"title" => "T", "custom_fields" => %{}, "_kiln_inline" => %{"f" => %{"k" => %{}}}}

    refute Map.has_key?(
             KilnCMSWeb.ContentEditor.ReferenceValues.normalize(params, []),
             "_kiln_inline"
           )

    refute Map.has_key?(
             KilnCMSWeb.ContentEditor.ReferenceValues.normalize(
               Map.delete(params, "custom_fields"),
               []
             ),
             "_kiln_inline"
           )
  end

  test "closing a card with unsaved edits is refused until it is saved or discarded", ctx do
    field!(ctx.admin, "ris_close")
    page = page!(ctx.admin)
    post = post_with!(ctx.admin, "ris_close", [page])
    lv = open_editor(build_conn(), ctx.admin, post)
    open_card(lv, "ris_close", page)
    edit(lv, "ris_close", page, %{"title" => "Draft text"})

    html = open_card(lv, "ris_close", page)
    assert html =~ "data-inline-card"
    assert html =~ "Save or discard the changes to this record before closing it."

    lv
    |> element("#cf-ref-ris_close-#{page.id}-inline-card [data-inline-discard]")
    |> render_click()

    refute open_card(lv, "ris_close", page) =~ "data-inline-card"
  end

  test "a card refused after unsaved edits can still be closed", ctx do
    field!(ctx.admin, "ris_stuck")
    page = page!(ctx.admin)
    post = post_with!(ctx.admin, "ris_stuck", [page])
    lv = open_editor(build_conn(), ctx.admin, post)
    open_card(lv, "ris_stuck", page)
    edit(lv, "ris_stuck", page, %{"title" => "Typed"})

    CMS.destroy_page!(CMS.get_page!(page.id, actor: ctx.admin), actor: ctx.admin)
    assert save(lv, "ris_stuck", page) =~ "can no longer be opened here"

    refute open_card(lv, "ris_stuck", page) =~ "can no longer be opened here"
  end
end

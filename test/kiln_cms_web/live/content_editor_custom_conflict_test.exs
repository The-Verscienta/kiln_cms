defmodule KilnCMSWeb.ContentEditorCustomConflictTest do
  @moduledoc """
  The publish-conflict panel's "Custom fields" row (#2294). The conflict stays
  one whole-map row (`WorkingCopy.fingerprint/3` hashes the map); beneath it
  the panel lists each custom field that differs between the live value and
  the draft's, with the field's label and the value on each side.
  """
  use KilnCMSWeb.ConnCase, async: false

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.WorkingCopy

  @password "password123456"

  defp authed_user(role) do
    email = "cf-conflict-#{System.unique_integer([:positive])}@example.com"

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

  defp reload(page), do: CMS.get_page!(page.id, authorize?: false, tenant: page.org_id)

  defp open(conn, user, page),
    do: conn |> log_in(user) |> live(~p"/editor/content/page/#{page.id}")

  defp save_custom(lv, fields) do
    lv
    |> form("#page-editor")
    |> render_submit(%{"form" => %{"custom_fields" => fields}})
  end

  setup do
    admin = authed_user(:admin)

    for attrs <- [
          %{name: "tier", label: "Membership tier", field_type: :string},
          %{name: "motto", label: "House motto", field_type: :string},
          %{name: "secret", label: "Secret note", field_type: :string, private: true}
        ] do
      CMS.create_field_definition!(Map.merge(%{content_type: :page}, attrs), actor: admin)
    end

    page =
      CMS.create_page!(
        %{
          title: "Live title",
          slug: "cf-conflict-#{System.unique_integer([:positive])}",
          custom_fields: %{"tier" => "gold", "motto" => "old", "secret" => "s0"}
        },
        actor: admin
      )

    page = CMS.publish_page!(page, %{}, actor: admin)
    KilnCMS.DataCase.drain_oban()
    %{admin: admin, page: reload(page)}
  end

  describe "draft against live" do
    test "a live edit to a different key lists each differing key, both sides", ctx do
      %{conn: conn, admin: admin, page: page} = ctx
      {:ok, lv, _html} = open(conn, admin, page)

      # The draft changes the tier; the live row's motto and private note move
      # after (an API PATCH). The whole map conflicts; the detail names keys.
      save_custom(lv, %{"tier" => "silver", "motto" => "old", "secret" => "s0"})

      CMS.update_page!(
        reload(page),
        %{custom_fields: %{"tier" => "gold", "motto" => "new", "secret" => "s1"}},
        actor: admin
      )

      {:ok, lv, _html} = open(conn, admin, page)
      lv |> element("#publish-changes") |> render_click()

      assert has_element?(lv, "#publish-conflict-custom_fields", "Custom fields")
      detail = "#publish-conflict-custom_fields-detail"

      # tier: live gold, draft silver
      assert has_element?(lv, ~s(#{detail} [data-custom-field="tier"]), "Membership tier")
      assert has_element?(lv, ~s(#{detail} [data-custom-field="tier"] del), "gold")
      assert has_element?(lv, ~s(#{detail} [data-custom-field="tier"] ins), "silver")

      # motto: live new, draft old
      assert has_element?(lv, ~s(#{detail} [data-custom-field="motto"]), "House motto")
      assert has_element?(lv, ~s(#{detail} [data-custom-field="motto"] del), "new")
      assert has_element?(lv, ~s(#{detail} [data-custom-field="motto"] ins), "old")

      # An editor sees a private key's values: the panel is not a delivery
      # read, so nothing is masked (a masked side would read as a false diff).
      assert has_element?(lv, ~s(#{detail} [data-custom-field="secret"] del), "s1")
      assert has_element?(lv, ~s(#{detail} [data-custom-field="secret"] ins), "s0")

      # Resolution is unchanged: still one whole-map choice.
      assert has_element?(lv, ~s(#publish-conflict-custom_fields button[phx-value-choice="mine"]))
      assert has_element?(lv, "#publish-conflicts-confirm[disabled]")
    end

    test "only the keys that differ are listed; equal keys are not", ctx do
      %{conn: conn, admin: admin, page: page} = ctx
      {:ok, lv, _html} = open(conn, admin, page)
      save_custom(lv, %{"tier" => "silver", "motto" => "old", "secret" => "s0"})

      CMS.update_page!(
        reload(page),
        %{custom_fields: %{"tier" => "gold", "motto" => "new", "secret" => "s0"}},
        actor: admin
      )

      {:ok, lv, _html} = open(conn, admin, page)
      lv |> element("#publish-changes") |> render_click()

      assert has_element?(
               lv,
               ~s(#publish-conflict-custom_fields-detail [data-custom-field="tier"])
             )

      assert has_element?(
               lv,
               ~s(#publish-conflict-custom_fields-detail [data-custom-field="motto"])
             )

      refute has_element?(
               lv,
               ~s(#publish-conflict-custom_fields-detail [data-custom-field="secret"])
             )
    end

    test "a conflict with no per-key difference renders no empty detail", ctx do
      %{conn: conn, admin: admin, page: page} = ctx
      {:ok, lv, _html} = open(conn, admin, page)
      save_custom(lv, %{"tier" => "silver", "motto" => "old", "secret" => "s0"})

      # The live row lands on exactly the draft's map: both moved off the
      # base, so it is still a conflict, but there is nothing to list.
      CMS.update_page!(
        reload(page),
        %{custom_fields: %{"tier" => "silver", "motto" => "old", "secret" => "s0"}},
        actor: admin
      )

      assert WorkingCopy.custom_field_changes(reload(page)) == []

      {:ok, lv, _html} = open(conn, admin, page)
      lv |> element("#publish-changes") |> render_click()

      assert has_element?(lv, "#publish-conflict-custom_fields")
      refute has_element?(lv, "#publish-conflict-custom_fields-detail")
    end

    test "a copy with no recorded base promotes without a panel, as before", ctx do
      %{conn: conn, admin: admin, page: page} = ctx
      {:ok, lv, _html} = open(conn, admin, page)
      save_custom(lv, %{"tier" => "silver", "motto" => "old", "secret" => "s0"})

      Ash.Seed.update!(reload(page), %{working_base: %{}})

      {:ok, lv, _html} = open(conn, admin, page)
      html = lv |> element("#publish-changes") |> render_click()

      refute has_element?(lv, "#publish-conflicts")
      assert html =~ "Published your changes."

      assert CMS.get_published_page_by_slug!(page.slug, page.locale).custom_fields["tier"] ==
               "silver"
    end
  end

  test "the pure helper diffs the held map against the live column", %{page: page, admin: admin} do
    assert WorkingCopy.custom_field_changes(page) == []

    {:ok, lv, _html} = open(build_conn(), admin, page)
    save_custom(lv, %{"tier" => "silver", "motto" => "old", "secret" => "s0"})

    assert [%{key: "tier", status: :changed, old: "gold", new: "silver"}] =
             WorkingCopy.custom_field_changes(reload(page))
  end

  test "a viewer cannot open the editor, so never reaches the panel", %{conn: conn, page: page} do
    viewer = authed_user(:viewer)
    assert {:error, {_kind, _}} = open(conn, viewer, page)
  end

  test "an anonymous visitor cannot open the editor", %{conn: conn, page: page} do
    assert {:error, {_kind, _}} = live(conn, ~p"/editor/content/page/#{page.id}")
  end
end

defmodule KilnCMSWeb.FlexibleFieldEditorTest do
  @moduledoc """
  A `:flexible` custom field in the content editor (#2282): the stored items
  are shown as cards (PR 2 replaced PR 1's read-only count and note;
  `FlexibleEditorTest` covers editing them), and a save that touches nothing
  else posts them back unchanged, ids included.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_admin do
    email = "ffe-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :admin
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

  setup %{conn: conn} do
    admin = authed_admin()

    flexible =
      CMS.create_field_definition!(
        %{content_type: :page, name: "ffe_sections", label: "Sections", field_type: :flexible},
        actor: admin
      )

    quote_type =
      CMS.create_field_definition!(
        %{name: "quote", label: "Quote", field_type: :group, flex_of_id: flexible.id},
        actor: admin
      )

    CMS.create_field_definition!(
      %{name: "text", label: "Text", field_type: :string, group_of_id: quote_type.id},
      actor: admin
    )

    page =
      CMS.create_page!(
        %{
          title: "Flexible",
          slug: "ffe-#{System.unique_integer([:positive])}",
          custom_fields: %{
            "ffe_sections" => [
              %{"_type" => "quote", "text" => "one"},
              %{"_type" => "quote", "text" => "two"}
            ]
          }
        },
        actor: admin
      )

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(admin)

    {:ok, lv, _html} = live(conn, ~p"/editor/content/page/#{page.id}")
    %{admin: admin, page: page, lv: lv}
  end

  test "shows a count and a card per item, with no read-only note", %{lv: lv} do
    assert has_element?(lv, "#custom-field-ffe_sections", "Sections")
    assert has_element?(lv, "#custom-field-ffe_sections", "2 items")
    refute has_element?(lv, "#custom-field-ffe_sections", "Edited through the API")
    assert has_element?(lv, "#custom-field-ffe_sections-items > li", "one")

    assert has_element?(
             lv,
             ~s(input[name="form[custom_fields][ffe_sections][1][text]"][value=two])
           )
  end

  test "saving something else keeps the stored items, ids and all", %{
    lv: lv,
    admin: admin,
    page: page
  } do
    before = CMS.get_page!(page.id, actor: admin).custom_fields["ffe_sections"]
    assert length(before) == 2

    lv |> form("#page-editor", %{"form" => %{"title" => "Renamed"}}) |> render_submit()

    saved = CMS.get_page!(page.id, actor: admin)
    assert saved.title == "Renamed"
    assert saved.custom_fields["ffe_sections"] == before
  end
end

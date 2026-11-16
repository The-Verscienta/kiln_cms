defmodule KilnCMSWeb.ColorPaletteEditorTest do
  @moduledoc """
  A `:color` field restricted to a palette (#2434) in the content editor: the
  palette shows as swatches, a pick saves, and a `:json` field's schema error
  is shown beside the field.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  setup %{conn: conn} do
    seeded =
      Ash.Seed.seed!(User, %{
        email: "cpe-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, admin} =
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{"email" => seeded.email, "password" => "password123456"},
        []
      )

    CMS.create_field_definition!(
      %{
        content_type: :page,
        name: "accent",
        label: "Accent",
        field_type: :color,
        validation: %{"palette" => ["#2563eb", "#F59E0B"]}
      },
      actor: admin
    )

    CMS.create_field_definition!(
      %{
        content_type: :page,
        name: "spec",
        label: "Spec",
        field_type: :json,
        validation: %{
          "json_schema" => %{"type" => "object", "required" => ["id"]}
        }
      },
      actor: admin
    )

    page =
      CMS.create_page!(
        %{
          title: "Brand",
          slug: "cpe-#{System.unique_integer([:positive])}",
          custom_fields: %{"accent" => "#2563eb", "spec" => %{"id" => 1}}
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

  test "the palette renders as swatches, the stored one checked, and a pick saves", ctx do
    assert has_element?(
             ctx.lv,
             ~s|fieldset#custom-field-accent input[type=radio][value="#2563eb"][checked]|
           )

    assert has_element?(
             ctx.lv,
             ~s|fieldset#custom-field-accent input[type=radio][value="#f59e0b"]|
           )

    # Optional, so it can be cleared.
    assert has_element?(ctx.lv, ~s|fieldset#custom-field-accent input[type=radio][value=""]|)
    refute has_element?(ctx.lv, "input[type=text]#custom-field-accent")

    ctx.lv
    |> form("#page-editor", %{"form" => %{"custom_fields" => %{"accent" => "#f59e0b"}}})
    |> render_change()

    ctx.lv |> form("#page-editor") |> render_submit()
    assert CMS.get_page!(ctx.page.id, actor: ctx.admin).custom_fields["accent"] == "#f59e0b"
  end

  test "a JSON value that breaks the schema is refused with the reason", ctx do
    ctx.lv
    |> form("#page-editor", %{"form" => %{"custom_fields" => %{"spec" => ~s({"other": 1})}}})
    |> render_change()

    html = ctx.lv |> form("#page-editor") |> render_submit()
    assert html =~ "JSON Schema"
    assert html =~ "required"
    assert CMS.get_page!(ctx.page.id, actor: ctx.admin).custom_fields["spec"] == %{"id" => 1}
  end
end

defmodule KilnCMSWeb.UserFieldEditorTest do
  @moduledoc """
  A `:user` custom field in the content editor (#2044): a picker of the
  site's people, marked private, saved as the chosen person's id.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp seed(role, attrs \\ %{}) do
    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: "ufe-#{role}-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt(@password),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )
  end

  defp sign_in(user) do
    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, signed_in} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => user.email,
        "password" => @password
      })

    signed_in
  end

  setup %{conn: conn} do
    admin = sign_in(seed(:admin, %{name: "Admin Person"}))
    writer = seed(:editor, %{name: "Staff Writer"})

    CMS.create_field_definition!(
      %{content_type: :page, name: "account", label: "Account", field_type: :user},
      actor: admin
    )

    page =
      CMS.create_page!(
        %{
          title: "Profile",
          slug: "ufe-#{System.unique_integer([:positive])}",
          custom_fields: %{"account" => admin.id}
        },
        actor: admin
      )

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(admin)

    {:ok, lv, _html} = live(conn, ~p"/editor/content/page/#{page.id}")
    %{admin: admin, writer: writer, page: page, lv: lv}
  end

  test "picks one of the site's people, says it is private, and saves the id", ctx do
    assert has_element?(ctx.lv, "label[for=custom-field-account]", "private")

    assert has_element?(
             ctx.lv,
             ~s(select#custom-field-account option[value="#{ctx.admin.id}"][selected]),
             "Admin Person"
           )

    assert has_element?(
             ctx.lv,
             ~s(select#custom-field-account option[value="#{ctx.writer.id}"]),
             "Staff Writer"
           )

    ctx.lv
    |> form("#page-editor", %{"form" => %{"custom_fields" => %{"account" => ctx.writer.id}}})
    |> render_change()

    ctx.lv |> form("#page-editor") |> render_submit()

    assert CMS.get_page!(ctx.page.id, actor: ctx.admin).custom_fields["account"] == ctx.writer.id
  end
end

defmodule KilnCMSWeb.FieldEditInlineAdminTest do
  @moduledoc """
  The fields admin's checkbox for `edit_inline` (#2283): a top-level reference
  offers "Let editors edit the related record here", ticking it stores the
  flag, unticking stores nil, and a field that is not a reference has no box.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role) do
    email = "ei-admin-#{System.unique_integer([:positive])}@example.com"

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

  defp uniq, do: System.unique_integer([:positive])

  defp reference!(admin, attrs \\ %{}) do
    CMS.create_field_definition!(
      Map.merge(
        %{
          content_type: :post,
          name: "rel_#{uniq()}",
          label: "Related",
          field_type: :reference,
          target_type: "page"
        },
        attrs
      ),
      actor: admin
    )
  end

  defp open_edit(conn, admin, field) do
    {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")
    lv |> element("#field-#{field.id} button[phx-click=edit]") |> render_click()
    lv
  end

  defp stored(field), do: CMS.get_field_definition!(field.id, authorize?: false).edit_inline

  setup do
    %{admin: authed_user(:admin)}
  end

  test "ticking the box stores the flag and unticking clears it", ctx do
    field = reference!(ctx.admin)
    lv = open_edit(build_conn(), ctx.admin, field)
    box = "#edit-field-rules-#{field.id}-edit-inline"

    assert has_element?(lv, box)
    assert has_element?(lv, "#{box}-hint", "saved on its own")
    refute lv |> element(box) |> render() =~ "checked"

    lv
    |> form("#edit-field-#{field.id}", field_definition: %{edit_inline: "true"})
    |> render_submit()

    assert stored(field) == true

    lv = open_edit(build_conn(), ctx.admin, field)
    assert lv |> element(box) |> render() =~ "checked"

    lv
    |> form("#edit-field-#{field.id}", field_definition: %{edit_inline: "false"})
    |> render_submit()

    assert stored(field) == nil
  end

  test "a field that is not a reference has no box", ctx do
    field =
      CMS.create_field_definition!(
        %{content_type: :post, name: "ei_plain_#{uniq()}", label: "Plain", field_type: :string},
        actor: ctx.admin
      )

    lv = open_edit(build_conn(), ctx.admin, field)
    refute has_element?(lv, "[id$=-edit-inline]")
  end
end

defmodule KilnCMSWeb.FieldSyncControllerTest do
  @moduledoc "The field-definitions download (#2288) is admin only and is the import's document."
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role) do
    email = "fsc-#{System.unique_integer([:positive])}@example.com"

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

  test "an admin downloads the document", %{conn: conn} do
    admin = authed_user(:admin)

    CMS.create_field_definition!(
      %{content_type: :post, name: "rating", label: "Rating", field_type: :integer},
      actor: admin
    )

    conn = conn |> log_in(admin) |> get("/editor/fields/export.json")

    assert response(conn, 200)
    assert get_resp_header(conn, "content-disposition") != []
    doc = Jason.decode!(conn.resp_body)
    assert doc["format"] == "kiln-field-definitions"

    assert Enum.any?(doc["owners"], fn o ->
             Enum.any?(o["fields"], &(&1["name"] == "rating"))
           end)
  end

  test "an editor is refused", %{conn: conn} do
    conn = conn |> log_in(authed_user(:editor)) |> get("/editor/fields/export.json")
    assert json_response(conn, 403)["error"] == "admin_required"
  end
end

defmodule KilnCMS.CMS.WebhookEndpointTest do
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "wh-val-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  test "rejects private webhook URLs on create" do
    admin = admin()

    assert {:error, %Ash.Error.Invalid{}} =
             CMS.create_webhook_endpoint(%{url: "http://127.0.0.1/hook"}, actor: admin)
  end

  test "rejects private webhook URLs on update" do
    admin = admin()

    endpoint =
      CMS.create_webhook_endpoint!(%{url: "https://example.test/hook"}, actor: admin)

    assert {:error, %Ash.Error.Invalid{}} =
             CMS.update_webhook_endpoint(endpoint, %{url: "http://192.168.0.1/hook"},
               actor: admin
             )
  end
end

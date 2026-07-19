defmodule KilnCMS.Accounts.SsoTest do
  @moduledoc """
  OIDC SSO (#331): the `:sso` strategy and its `register_with_sso` upsert —
  verified-email-only linking, viewer-by-default provisioning, invite-only
  respect. No live IdP: the register action is driven directly with the
  user-info shape the strategy hands it.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Accounts.User

  defp register(info) do
    # The strategy requires a stable subject claim; default one per call.
    info = Map.put_new(info, "sub", "sub-#{System.unique_integer([:positive])}")

    User
    |> Ash.Changeset.for_create(
      :register_with_sso,
      %{user_info: info, oauth_tokens: %{"access_token" => "tok"}},
      context: %{private: %{ash_authentication?: true}}
    )
    |> Ash.create()
  end

  defp email, do: "sso-#{System.unique_integer([:positive])}@example.com"

  test "the :sso strategy is compiled in (test env enables the gate)" do
    assert AshAuthentication.Info.strategy!(User, :sso)
  end

  test "a verified identity provisions a confirmed :viewer" do
    address = email()

    assert {:ok, user} =
             register(%{"email" => address, "email_verified" => true, "name" => "Priya IdP"})

    assert to_string(user.email) == address
    assert user.role == :viewer
    assert user.name == "Priya IdP"
    # The IdP verified the email — no second confirmation loop.
    reloaded = Ash.get!(User, user.id, authorize?: false)
    refute is_nil(reloaded.confirmed_at)
  end

  test "an unverified identity email is rejected" do
    assert {:error, error} = register(%{"email" => email(), "email_verified" => false})
    assert Exception.message(error) =~ "not verified"

    assert {:error, _} = register(%{"email_verified" => true})
  end

  test "an existing account links as-is — role and name untouched" do
    address = email()

    existing =
      Ash.Seed.seed!(User, %{
        email: address,
        name: "Chosen Name",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    assert {:ok, linked} =
             register(%{"email" => address, "email_verified" => true, "name" => "IdP Name"})

    assert linked.id == existing.id

    reloaded = Ash.get!(User, existing.id, authorize?: false)
    assert reloaded.role == :admin
    assert reloaded.name == "Chosen Name"
  end

  test "invite-only mode refuses unknown emails but signs in existing ones" do
    Application.put_env(:kiln_cms, :registration_enabled, false)
    on_exit(fn -> Application.delete_env(:kiln_cms, :registration_enabled) end)

    assert {:error, error} = register(%{"email" => email(), "email_verified" => true})
    assert Exception.message(error) =~ "self-registration is disabled"

    address = email()

    Ash.Seed.seed!(User, %{
      email: address,
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :editor
    })

    assert {:ok, _} = register(%{"email" => address, "email_verified" => true})
  end
end

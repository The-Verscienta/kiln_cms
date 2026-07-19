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
    reloaded = KilnCMS.Accounts.get_user!(user.id, authorize?: false)
    refute is_nil(reloaded.confirmed_at)
  end

  test "an unverified identity email is rejected" do
    assert {:error, error} = register(%{"email" => email(), "email_verified" => false})
    assert Exception.message(error) =~ "not verified"

    assert {:error, _} = register(%{"email_verified" => true})
  end

  test "a string \"true\" claim is accepted; an ABSENT claim is rejected by default" do
    assert {:ok, _} = register(%{"email" => email(), "email_verified" => "true"})

    assert {:error, error} = register(%{"email" => email()})
    assert Exception.message(error) =~ "not verified"
  end

  test "assume_email_verified lets claim-omitting IdPs (e.g. Entra) through" do
    prev = Application.get_env(:kiln_cms, :sso_oidc, [])
    Application.put_env(:kiln_cms, :sso_oidc, Keyword.put(prev, :assume_email_verified, true))
    on_exit(fn -> Application.put_env(:kiln_cms, :sso_oidc, prev) end)

    assert {:ok, _} = register(%{"email" => email()})
  end

  test "invite-only still admits an identity-linked user whose IdP email changed" do
    Application.put_env(:kiln_cms, :registration_enabled, false)
    on_exit(fn -> Application.delete_env(:kiln_cms, :registration_enabled) end)

    # First link happens while the account exists under the old email.
    address = email()

    Ash.Seed.seed!(User, %{
      email: address,
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :editor
    })

    sub = "stable-sub-#{System.unique_integer([:positive])}"
    assert {:ok, user} = register(%{"email" => address, "email_verified" => true, "sub" => sub})

    # The IdP now asserts a brand-new email for the SAME subject: no email
    # match, but the stored identity makes the account known — not a
    # "registration" to refuse.
    assert {:ok, linked} =
             register(%{"email" => email(), "email_verified" => true, "sub" => sub})

    assert linked.id == user.id
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

    reloaded = KilnCMS.Accounts.get_user!(existing.id, authorize?: false)
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

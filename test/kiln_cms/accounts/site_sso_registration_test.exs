defmodule KilnCMS.Accounts.SiteSsoRegistrationTest do
  @moduledoc """
  Site SSO admission under invite-only mode (#1561): no new accounts, known
  ones still sign in.

  Split out of `KilnCMS.Accounts.SiteSsoTest` and `async: false` because it
  turns `:registration_enabled` off, which is VM-global and read by every
  registration path (password sign-up, SSO, the registration LiveView): while
  it ran async, any concurrent test that registers an account could be refused
  (#2380).
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.SiteSso.Admission
  alias KilnCMS.Accounts.User
  alias KilnCMS.SiteSsoFixtures, as: F

  setup do
    org = KilnCMS.OrgFixtures.org("sso")
    domain = F.unique_domain()
    F.provider!(org)
    F.domain!(org, domain, verified: true)
    %{org: org, domain: domain}
  end

  defp user!(email) do
    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt("password1234!"),
      confirmed_at: DateTime.utc_now(),
      role: :viewer
    })
  end

  defp member!(user, org, role) do
    Ash.Seed.seed!(Accounts.OrgMembership, %{
      user_id: user.id,
      organization_id: org.id,
      role: role
    })
  end

  defp claims(email),
    do: %{"email" => email, "email_verified" => true, "sub" => "s-1"}

  test "invite-only: no new accounts, known ones still sign in", %{org: org, domain: domain} do
    previous = Application.fetch_env(:kiln_cms, :registration_enabled)
    Application.put_env(:kiln_cms, :registration_enabled, false)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:kiln_cms, :registration_enabled, value)
        :error -> Application.delete_env(:kiln_cms, :registration_enabled)
      end
    end)

    assert {:error, :registration_disabled} = Admission.admit(org.id, claims("new@#{domain}"))

    known = user!("known@#{domain}")
    member!(known, org, :viewer)
    assert {:ok, _user} = Admission.admit(org.id, claims("known@#{domain}"))
  end
end

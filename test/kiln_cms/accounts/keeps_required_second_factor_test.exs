defmodule KilnCMS.Accounts.KeepsRequiredSecondFactorTest do
  @moduledoc """
  An account can't remove its last second factor while a site it uses requires
  one (#2247, `KilnCMS.Accounts.Validations.KeepsRequiredSecondFactor`): not
  the authenticator app with no passkey left, not the only passkey with no
  app. The refusal spends none of the second-factor budget. Removing one of
  two factors, replacing the app, removing after the requirement is turned
  off, and a platform admin removing someone else's passkey all still work.

  That a refusal spends none of the second-factor budget is in
  `KilnCMSWeb.SecondFactorGuardBudgetTest`, which puts the real budget back.
  Each test uses a site of its own: the policy is cached per site on the
  whole node.
  """
  use KilnCMS.DataCase, async: true

  import KilnCMS.OrgFixtures, only: [org: 1]
  import KilnCMS.SecondFactorFixtures, only: [policy_row!: 3, change_policy!: 2, member!: 3]

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Errors.LastSecondFactorRequired
  alias KilnCMS.Accounts.Totp
  alias KilnCMS.TwoFactorFixtures

  # A site that requires editors (and admins), with a long grace: required,
  # not yet enforced. The guard is about "required", not "held".
  defp requiring_site(slug) do
    site = org(slug)
    row = policy_row!(site, :editors, grace_days: 30, since: DateTime.utc_now())
    {site, row}
  end

  defp app_editor(site) do
    {user, secret} = TwoFactorFixtures.enabled_user(role: :viewer)
    {member!(user, site, :editor), secret}
  end

  defp passkey!(user) do
    Ash.Seed.seed!(Accounts.Passkey, %{
      user_id: user.id,
      name: "Key",
      credential_id: "cred-#{System.unique_integer([:positive])}",
      public_key: <<1, 2, 3>>,
      sign_count: 0
    })
  end

  defp passkey_editor(site) do
    user =
      Ash.Seed.seed!(Accounts.User, %{
        email: "krsf-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :viewer
      })

    member!(user, site, :editor)
  end

  defp reload(user), do: Accounts.get_user!(user.id, authorize?: false)

  defp disable(user, secret),
    do: Accounts.disable_totp(user, %{code: Totp.code_at(secret, now())}, actor: user)

  defp remove(passkey, actor), do: Accounts.remove_passkey(passkey, actor: actor)

  defp now, do: System.system_time(:second)

  defp last_factor_refusal?({:error, %{errors: errors}}),
    do: Enum.any?(errors, &match?(%LastSecondFactorRequired{}, &1))

  defp last_factor_refusal?(_other), do: false

  describe "the authenticator app" do
    test "is not turned off while it is the last factor" do
      {site, _row} = requiring_site("krsf-app")
      {user, secret} = app_editor(site)

      assert last_factor_refusal?(disable(user, secret))
      assert Accounts.totp_enabled?(reload(user))
    end

    test "is not turned off in the grace period either" do
      {site, _row} = requiring_site("krsf-app-grace")
      {user, secret} = app_editor(site)

      assert {:grace, _deadline} =
               KilnCMS.Accounts.TwoFactorRequirement.status(
                 %{user | totp_confirmed_at: nil},
                 site.id
               )

      assert last_factor_refusal?(disable(user, secret))
    end

    test "is turned off once the site no longer requires it" do
      {site, row} = requiring_site("krsf-app-off")
      {user, secret} = app_editor(site)

      change_policy!(row, %{required_for: :off})

      assert {:ok, user} = disable(user, secret)
      refute Accounts.totp_enabled?(user)
    end

    test "is turned off while a passkey remains" do
      {site, _row} = requiring_site("krsf-app-pk")
      {user, secret} = app_editor(site)
      passkey!(user)

      assert {:ok, user} = disable(user, secret)
      refute Accounts.totp_enabled?(user)
    end

    test "can still be replaced, after a recovery-code sign-in included" do
      {site, _row} = requiring_site("krsf-app-replace")
      {user, _secret} = app_editor(site)
      old_secret = user.totp_secret

      {:ok, staged} = Accounts.setup_totp(user, actor: user)
      code = Totp.code_at(staged.totp_pending_secret, now())

      assert {:ok, replaced} =
               Accounts.confirm_totp(staged, %{code: code, recovery_login?: true}, actor: staged)

      assert replaced.totp_secret != old_secret
      assert Accounts.totp_enabled?(replaced)
    end

    test "an account no site requires it of turns it off as before" do
      site = org("krsf-app-none")
      {user, secret} = app_editor(site)

      assert {:ok, _user} = disable(user, secret)
    end
  end

  describe "passkeys" do
    test "the last one can't be removed while required" do
      {site, _row} = requiring_site("krsf-pk-last")
      user = passkey_editor(site)
      passkey = passkey!(user)

      assert last_factor_refusal?(remove(passkey, user))
      assert Accounts.second_factors(user).passkeys == 1
    end

    test "one of two can be removed, but not then the other" do
      {site, _row} = requiring_site("krsf-pk-two")
      user = passkey_editor(site)
      first = passkey!(user)
      second = passkey!(user)

      assert :ok = remove(first, user)
      assert last_factor_refusal?(remove(second, user))
    end

    test "the last one can be removed while the authenticator app remains" do
      {site, _row} = requiring_site("krsf-pk-app")
      {user, _secret} = app_editor(site)
      passkey = passkey!(user)

      assert :ok = remove(passkey, user)
    end

    test "a platform admin can remove someone's last one" do
      {site, _row} = requiring_site("krsf-pk-admin")
      user = passkey_editor(site)
      passkey = passkey!(user)
      {admin, _secret} = TwoFactorFixtures.enabled_user(role: :admin)

      assert :ok = remove(passkey, admin)
      assert Accounts.second_factors(user).passkeys == 0
    end
  end
end

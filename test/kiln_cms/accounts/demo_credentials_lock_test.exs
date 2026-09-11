defmodule KilnCMS.Accounts.DemoCredentialsLockTest do
  @moduledoc """
  Demo mode fixes the shared account's credentials (`docs/demo-mode.md`,
  "The shared account's credentials"): every visitor to a demo signs in as the
  same account, so a password or second factor one of them set would lock out
  the rest until the next reset. A non-admin is refused every change to how an
  account signs in; admins still manage accounts.

  Each refusal is asserted as the whole error list — exactly one
  `DemoAccountLocked` — so a refusal that also carried a wrong-code or
  wrong-password complaint, or arrived as a bare policy `Forbidden`, fails
  rather than matching loosely.

  `async: false`: `Application.put_env` is a process-wide write.
  """
  use KilnCMS.DataCase, async: false
  @moduletag :capture_log

  import KilnCMS.PasskeyFixtures, only: [enroll: 2]

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.ApiKey
  alias KilnCMS.Accounts.Errors.DemoAccountLocked
  alias KilnCMS.Accounts.Passkey
  alias KilnCMS.Accounts.User
  alias KilnCMS.Demo
  alias KilnCMS.TwoFactorFixtures

  @password TwoFactorFixtures.password()
  @new_password "a-new-password-9876"
  @refused "this is a shared demo account — its password and sign-in methods can't be changed"

  setup do
    saved = Application.get_env(:kiln_cms, KilnCMS.Demo)

    on_exit(fn ->
      if saved,
        do: Application.put_env(:kiln_cms, KilnCMS.Demo, saved),
        else: Application.delete_env(:kiln_cms, KilnCMS.Demo)
    end)

    demo(true)
    :ok
  end

  defp demo(enabled?), do: Application.put_env(:kiln_cms, KilnCMS.Demo, enabled: enabled?)

  defp user(role) do
    Ash.Seed.seed!(User, %{
      email: "demo-lock-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp reload(user), do: Ash.get!(User, user.id, authorize?: false)

  # The message of the one error a refused call returned, or the whole result
  # when it was anything else — so `==` against `@refused` shows what came back.
  # Bread crumbs ("Error returned from: …") depend on the call path, not the
  # refusal, so they are dropped before comparing.
  defp refusal({:error, %Ash.Error.Forbidden{errors: [%DemoAccountLocked{} = error]}}),
    do: Exception.message(%{error | bread_crumbs: []})

  defp refusal(other), do: other

  defp change_password(user, actor) do
    user
    |> Ash.Changeset.for_update(
      :change_password,
      %{
        current_password: @password,
        password: @new_password,
        password_confirmation: @new_password
      },
      actor: actor
    )
    |> Ash.update()
  end

  defp passkey_attrs(user) do
    %{
      user_id: user.id,
      name: "Laptop",
      credential_id: "demo-lock-#{System.unique_integer([:positive])}",
      public_key: :erlang.term_to_binary(%{stub: :cose_key}),
      sign_count: 0
    }
  end

  defp seed_passkey(user), do: Ash.Seed.seed!(Passkey, passkey_attrs(user))

  describe "KilnCMS.Demo.locks_credentials?/1" do
    test "refuses every non-admin actor while demo mode is on" do
      assert Demo.locks_credentials?(%User{role: :editor}) == true
      assert Demo.locks_credentials?(%User{role: :viewer}) == true
      assert Demo.locks_credentials?(%User{role: :admin}) == false
      assert Demo.locks_credentials?(nil) == false
    end

    test "refuses nobody while demo mode is off" do
      demo(false)

      assert Demo.locks_credentials?(%User{role: :editor}) == false
      assert Demo.locks_credentials?(%User{role: :viewer}) == false
      assert Demo.locks_credentials?(%User{role: :admin}) == false
    end
  end

  describe "a non-admin, in demo mode" do
    test "can't change their password" do
      editor = user(:editor)

      assert refusal(change_password(editor, editor)) == @refused
      assert reload(editor).hashed_password == editor.hashed_password
    end

    test "can't start two-factor enrolment" do
      editor = user(:editor)

      assert refusal(Accounts.setup_totp(editor, %{}, actor: editor)) == @refused
      assert reload(editor).totp_pending_secret == nil
    end

    test "can't confirm a staged enrolment, even with the right code" do
      pending = :crypto.strong_rand_bytes(20)
      editor = :editor |> user() |> Ash.Seed.update!(%{totp_pending_secret: pending})
      code = TwoFactorFixtures.current_code(pending)

      assert refusal(Accounts.confirm_totp(editor, %{code: code}, actor: editor)) == @refused

      stored = reload(editor)
      assert stored.totp_secret == nil
      assert stored.totp_confirmed_at == nil
      assert stored.totp_recovery_hashes == []
    end

    test "can't turn two-factor off, even with the right code" do
      {editor, secret} = TwoFactorFixtures.enabled_user(role: :editor)
      code = TwoFactorFixtures.current_code(secret)

      assert refusal(Accounts.disable_totp(editor, %{code: code}, actor: editor)) == @refused

      stored = reload(editor)
      assert stored.totp_secret == editor.totp_secret
      assert stored.totp_confirmed_at == editor.totp_confirmed_at
    end

    test "can't mint new recovery codes, even with the right code" do
      {editor, secret} = TwoFactorFixtures.enabled_user(role: :editor)
      editor = TwoFactorFixtures.with_recovery_codes(editor) |> elem(0)
      code = TwoFactorFixtures.current_code(secret)

      assert refusal(
               Accounts.regenerate_totp_recovery_codes(editor, %{code: code}, actor: editor)
             ) ==
               @refused

      assert reload(editor).totp_recovery_hashes == editor.totp_recovery_hashes
    end

    test "can't add a passkey through the WebAuthn ceremony" do
      editor = user(:editor)

      assert refusal(enroll(editor, "demo-lock-ceremony")) == @refused
      assert Accounts.list_passkeys!(editor.id, authorize?: false) == []
    end

    test "can't register a passkey on the action directly, even as a system call" do
      editor = user(:editor)

      assert refusal(
               Accounts.register_passkey_credential(passkey_attrs(editor),
                 actor: editor,
                 authorize?: false
               )
             ) == @refused
    end

    test "can't remove a passkey" do
      editor = user(:editor)
      passkey = seed_passkey(editor)

      assert refusal(Accounts.remove_passkey(passkey, actor: editor)) == @refused

      assert Enum.map(Accounts.list_passkeys!(editor.id, authorize?: false), & &1.id) == [
               passkey.id
             ]
    end

    test "still can't mint an API key (admin-only, demo or not)" do
      editor = user(:editor)

      assert {:error, %Ash.Error.Forbidden{}} =
               ApiKey
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   user_id: editor.id,
                   name: "visitor key",
                   expires_at: DateTime.add(DateTime.utc_now(), 3600)
                 },
                 actor: editor
               )
               |> Ash.create()
    end

    test "can still edit their display name" do
      editor = user(:editor)

      assert {:ok, updated} =
               editor
               |> Ash.Changeset.for_update(:update_profile, %{name: "Visitor"}, actor: editor)
               |> Ash.update()

      assert updated.name == "Visitor"
    end
  end

  describe "an admin, in demo mode" do
    test "changes their own password" do
      admin = user(:admin)

      assert {:ok, _} = change_password(admin, admin)
      assert Bcrypt.verify_pass(@new_password, reload(admin).hashed_password) == true
    end

    test "changes the shared account's password" do
      admin = user(:admin)
      editor = user(:editor)

      assert {:ok, _} = change_password(editor, admin)
      assert Bcrypt.verify_pass(@new_password, reload(editor).hashed_password) == true
    end

    test "starts two-factor enrolment on their own account" do
      admin = user(:admin)

      assert {:ok, staged} = Accounts.setup_totp(admin, %{}, actor: admin)
      assert byte_size(staged.totp_pending_secret) == 20
    end

    test "turns off the shared account's two-factor" do
      {editor, secret} = TwoFactorFixtures.enabled_user(role: :editor)
      admin = user(:admin)
      code = TwoFactorFixtures.current_code(secret)

      assert {:ok, disabled} = Accounts.disable_totp(editor, %{code: code}, actor: admin)
      assert disabled.totp_confirmed_at == nil
    end

    test "adds and removes passkeys" do
      admin = user(:admin)
      editor = user(:editor)

      assert {:ok, own} = enroll(admin, "demo-lock-admin")
      assert Accounts.remove_passkey(own, actor: admin) == :ok

      shared = seed_passkey(editor)
      assert Accounts.remove_passkey(shared, actor: admin) == :ok
    end
  end

  describe "outside demo mode" do
    setup do
      demo(false)
      :ok
    end

    test "an editor changes their own password" do
      editor = user(:editor)

      assert {:ok, _} = change_password(editor, editor)
      assert Bcrypt.verify_pass(@new_password, reload(editor).hashed_password) == true
    end

    test "an editor adds and removes their own passkey" do
      editor = user(:editor)

      assert {:ok, passkey} = enroll(editor, "demo-lock-off")
      assert Accounts.remove_passkey(passkey, actor: editor) == :ok
    end
  end
end

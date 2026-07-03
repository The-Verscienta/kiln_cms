defmodule KilnCMS.MailSettingsTest do
  @moduledoc """
  Coverage for DKIM key management on the mail-settings singleton: the
  generate/rotate lifecycle (database provider), pointing the key at
  operator-managed sources (env/file), admin-only policies, and
  `KilnCMS.Mail.dkim_config/0` feeding real signatures into direct delivery.
  """
  use KilnCMS.DataCase, async: true

  import ExUnit.CaptureLog

  alias KilnCMS.Accounts.User
  alias KilnCMS.Keys
  alias KilnCMS.Mail

  defp user(role) do
    Ash.Seed.seed!(User, %{
      email: "mail-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp admin, do: user(:admin)

  test "ensure_settings! creates the singleton once, with database provider default" do
    first = Mail.ensure_settings!()
    second = Mail.ensure_settings!()

    assert first.id == second.id
    assert first.dkim_key_provider == :database
    assert is_nil(first.dkim_selector)
  end

  describe "generate/rotate (database provider)" do
    test "generate_dkim stores encrypted key, matching public key, and a selector" do
      settings = Mail.generate_dkim!(Mail.ensure_settings!(), actor: admin())

      assert settings.dkim_key_provider == :database
      assert settings.dkim_selector =~ ~r/^kiln/
      assert is_binary(settings.dkim_private_key_encrypted)
      assert {:ok, _der} = Base.decode64(settings.dkim_public_key)

      # The stored public key is derived from the resolvable private key.
      assert {:ok, pem} = Keys.fetch(:dkim)
      assert Keys.rsa_public_key_b64(pem) == {:ok, settings.dkim_public_key}
    end

    test "second generate refuses; rotate replaces both key and selector" do
      admin = admin()
      settings = Mail.generate_dkim!(Mail.ensure_settings!(), actor: admin)

      assert {:error, %Ash.Error.Invalid{}} = Mail.generate_dkim(settings, actor: admin)

      rotated = Mail.rotate_dkim!(settings, actor: admin)
      refute rotated.dkim_selector == settings.dkim_selector
      refute rotated.dkim_public_key == settings.dkim_public_key
    end

    test "rotate without an existing database key refuses" do
      assert {:error, %Ash.Error.Invalid{}} =
               Mail.rotate_dkim(Mail.ensure_settings!(), actor: admin())
    end
  end

  describe "configure_key_source (env/file providers)" do
    @tag :tmp_dir
    test "file source is checked, public key derived, database material cleared", %{
      tmp_dir: tmp_dir
    } do
      admin = admin()
      path = Path.join(tmp_dir, "dkim.pem")
      pem = Keys.generate_rsa_pem()
      File.write!(path, pem)

      # Start from a database key to prove the switch clears it.
      settings = Mail.generate_dkim!(Mail.ensure_settings!(), actor: admin)

      settings =
        Mail.configure_dkim_key_source!(settings, :file, %{"path" => path}, actor: admin)

      assert settings.dkim_key_provider == :file
      assert settings.dkim_key_provider_config == %{"path" => path}
      assert is_nil(settings.dkim_private_key_encrypted)
      assert Keys.rsa_public_key_b64(pem) == {:ok, settings.dkim_public_key}
      assert {:ok, ^pem} = Keys.fetch(:dkim)
    end

    @tag :tmp_dir
    test "re-saving the same source keeps the selector; new key material rotates it", %{
      tmp_dir: tmp_dir
    } do
      admin = admin()
      path = Path.join(tmp_dir, "dkim.pem")
      File.write!(path, Keys.generate_rsa_pem())

      settings =
        Mail.configure_dkim_key_source!(Mail.ensure_settings!(), :file, %{"path" => path},
          actor: admin
        )

      unchanged =
        Mail.configure_dkim_key_source!(settings, :file, %{"path" => path}, actor: admin)

      assert unchanged.dkim_selector == settings.dkim_selector

      File.write!(path, Keys.generate_rsa_pem())
      changed = Mail.configure_dkim_key_source!(unchanged, :file, %{"path" => path}, actor: admin)

      refute changed.dkim_selector == settings.dkim_selector
      refute changed.dkim_public_key == settings.dkim_public_key
    end

    test "env source works; an unusable source is rejected with a readable error" do
      admin = admin()
      var = "KILN_TEST_DKIM_#{System.unique_integer([:positive])}"
      pem = Keys.generate_rsa_pem()
      System.put_env(var, pem)
      on_exit(fn -> System.delete_env(var) end)

      settings =
        Mail.configure_dkim_key_source!(Mail.ensure_settings!(), :env, %{"var" => var},
          actor: admin
        )

      assert settings.dkim_key_provider == :env
      assert {:ok, ^pem} = Keys.fetch(:dkim)

      assert {:error, %Ash.Error.Invalid{} = error} =
               Mail.configure_dkim_key_source(settings, :env, %{"var" => "#{var}_MISSING"},
                 actor: admin
               )

      assert Exception.message(error) =~ "is not set"
    end
  end

  describe "server IP and verification bookkeeping" do
    test "set_server_ip validates addresses" do
      admin = admin()
      settings = Mail.ensure_settings!()

      updated = Mail.set_mail_server_ip!(settings, %{server_ip: "203.0.113.9"}, actor: admin)
      assert updated.server_ip == "203.0.113.9"

      assert {:error, %Ash.Error.Invalid{}} =
               Mail.set_mail_server_ip(settings, %{server_ip: "not-an-ip"}, actor: admin)
    end

    test "record_verification stamps last_verified_at" do
      settings = Mail.ensure_settings!()
      assert is_nil(settings.last_verified_at)

      updated =
        Mail.record_mail_verification!(
          settings,
          %{verification_results: %{"spf" => "ok"}},
          actor: admin()
        )

      assert updated.verification_results == %{"spf" => "ok"}
      assert %DateTime{} = updated.last_verified_at
    end
  end

  test "every mutating action is admin-only" do
    settings = Mail.ensure_settings!()
    editor = user(:editor)

    assert {:error, %Ash.Error.Forbidden{}} = Mail.generate_dkim(settings, actor: editor)
    assert {:error, %Ash.Error.Forbidden{}} = Mail.rotate_dkim(settings, actor: editor)

    assert {:error, %Ash.Error.Forbidden{}} =
             Mail.configure_dkim_key_source(settings, :env, %{}, actor: editor)

    assert {:error, %Ash.Error.Forbidden{}} =
             Mail.set_mail_server_ip(settings, %{server_ip: "203.0.113.9"}, actor: editor)

    assert {:error, %Ash.Error.Forbidden{}} =
             Mail.record_mail_verification(settings, %{verification_results: %{}}, actor: editor)
  end

  describe "dkim_config/0" do
    test "nil before any key is configured" do
      assert is_nil(Mail.dkim_config())
      Mail.ensure_settings!()
      assert is_nil(Mail.dkim_config())
    end

    test "returns gen_smtp signing options once a key exists" do
      settings = Mail.generate_dkim!(Mail.ensure_settings!(), actor: admin())

      config = Mail.dkim_config()
      assert config[:s] == settings.dkim_selector
      # :email_from test default is noreply@kilncms.dev (config/config.exs).
      assert config[:d] == "kilncms.dev"
      assert {:pem_plain, pem} = config[:private_key]
      assert Keys.rsa_public_key_b64(pem) == {:ok, settings.dkim_public_key}
    end

    test "an unresolvable configured key logs and sends unsigned (nil)" do
      admin = admin()
      var = "KILN_TEST_DKIM_#{System.unique_integer([:positive])}"
      System.put_env(var, Keys.generate_rsa_pem())

      Mail.configure_dkim_key_source!(Mail.ensure_settings!(), :env, %{"var" => var},
        actor: admin
      )

      System.delete_env(var)

      log =
        capture_log(fn ->
          assert is_nil(Mail.dkim_config())
        end)

      assert log =~ "sending unsigned"
      assert log =~ var
    end
  end

  test "direct delivery DKIM-signs with the configured key" do
    settings = Mail.generate_dkim!(Mail.ensure_settings!(), actor: admin())

    {sink_name, port} = KilnCMS.SMTPSink.start(self())
    on_exit(fn -> :gen_smtp_server.stop(sink_name) end)

    email =
      Swoosh.Email.new()
      |> Swoosh.Email.from({"KilnCMS", "noreply@kilncms.dev"})
      |> Swoosh.Email.to("user@example.com")
      |> Swoosh.Email.subject("Signed")
      |> Swoosh.Email.html_body("<p>Hi</p>")

    assert {:ok, _receipts} =
             KilnCMS.Mailer.DirectMX.deliver(email,
               relay_override: "127.0.0.1",
               port: port,
               no_mx_lookups: true,
               tls: :never,
               hostname: "kiln.test"
             )

    assert_receive {:smtp_sink, _from, _to, data}, 2_000
    assert data =~ "DKIM-Signature:"
    assert data =~ "s=#{settings.dkim_selector}"
    assert data =~ "d=kilncms.dev"
    assert data =~ "b="
  end
end

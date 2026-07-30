defmodule KilnCMS.Billing.SettingsTest do
  @moduledoc """
  The instance-wide billing credentials singleton: lazy creation, secret storage
  through `KilnCMS.Keys`, and the platform-admin policy.

  The policy assertions matter more than they look: this row holds a payment
  provider's account-wide API key, and because it is *tenant-less* an `OrgAdmin`
  check would resolve every actor against the default org — the hazard documented
  on `KilnCMS.Mail.Settings` and `KilnCMS.CMS.SiteBranding`. The
  default-org-admin case below is that hazard as an executable assertion.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Accounts.User
  alias KilnCMS.Billing

  setup do
    # `Application.put_env` for the provider double, so not async.
    on_exit(fn -> Application.delete_env(:kiln_cms, KilnCMS.Billing) end)
    :ok
  end

  defp user(role) do
    Ash.Seed.seed!(User, %{
      email: "#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  describe "ensure_settings!/0" do
    test "creates the row lazily and is idempotent" do
      first = Billing.ensure_settings!()
      second = Billing.ensure_settings!()

      assert first.id == second.id
      assert first.provider == :stripe
      assert first.secret_key_provider == :database
      assert first.webhook_secret_provider == :database
    end

    test "get_settings/0 is nil before first use" do
      refute Billing.get_settings()
    end
  end

  describe "store_secret" do
    test "round-trips a secret through the Keys registry" do
      settings = Billing.ensure_settings!()

      {:ok, _updated} =
        Billing.store_billing_secret(settings, :secret_key, "sk_test_abc123", authorize?: false)

      assert {:ok, "sk_test_abc123"} = KilnCMS.Keys.fetch(:billing_secret_key)
    end

    test "keeps the two secrets independent" do
      settings = Billing.ensure_settings!()

      {:ok, settings} =
        Billing.store_billing_secret(settings, :secret_key, "sk_test_abc", authorize?: false)

      {:ok, _settings} =
        Billing.store_billing_secret(settings, :webhook_secret, "whsec_xyz", authorize?: false)

      assert {:ok, "sk_test_abc"} = KilnCMS.Keys.fetch(:billing_secret_key)
      assert {:ok, "whsec_xyz"} = KilnCMS.Keys.fetch(:billing_webhook_secret)
    end

    test "never persists the plaintext in the provider-config column" do
      settings = Billing.ensure_settings!()

      {:ok, updated} =
        Billing.store_billing_secret(settings, :secret_key, "sk_test_abc123", authorize?: false)

      refute updated.secret_key_provider_config["encrypted"]
      assert updated.secret_key_provider_config == %{}
      refute inspect(updated.secret_key_provider_config) =~ "sk_test_abc123"
      # Stored ciphertext must not contain the plaintext.
      refute updated.secret_key_encrypted =~ "sk_test_abc123"
    end

    test "trims surrounding whitespace" do
      # A key pasted from a dashboard or read from a mounted file routinely
      # carries a trailing newline, which would otherwise land in an
      # `Authorization` header.
      settings = Billing.ensure_settings!()

      {:ok, _updated} =
        Billing.store_billing_secret(settings, :secret_key, "  sk_test_abc\n", authorize?: false)

      assert {:ok, "sk_test_abc"} = KilnCMS.Keys.fetch(:billing_secret_key)
    end

    test "rejects a blank secret" do
      settings = Billing.ensure_settings!()

      # Ash's string cast trims and nils a whitespace-only value, so the
      # `allow_nil? false` argument rejects it before the change even runs. Either
      # way it cannot be stored — which is the property under test.
      assert {:error, error} =
               Billing.store_billing_secret(settings, :secret_key, "   ", authorize?: false)

      assert Exception.message(error) =~ "required"
      refute Billing.configured?()
    end

    test "switches the provider back to :database from :env" do
      System.put_env("KILN_TEST_BILLING_KEY", "sk_from_env")
      on_exit(fn -> System.delete_env("KILN_TEST_BILLING_KEY") end)

      settings = Billing.ensure_settings!()

      {:ok, settings} =
        Billing.configure_billing_key_source(
          settings,
          :secret_key,
          :env,
          %{"var" => "KILN_TEST_BILLING_KEY"},
          authorize?: false
        )

      assert settings.secret_key_provider == :env

      {:ok, settings} =
        Billing.store_billing_secret(settings, :secret_key, "sk_pasted", authorize?: false)

      assert settings.secret_key_provider == :database
      # The stale env pointer must not linger, or the console misreports the source.
      assert settings.secret_key_provider_config == %{}
      assert {:ok, "sk_pasted"} = KilnCMS.Keys.fetch(:billing_secret_key)
    end
  end

  describe "configure_key_source" do
    test "resolves from an env var" do
      System.put_env("KILN_TEST_BILLING_KEY", "sk_from_env")
      on_exit(fn -> System.delete_env("KILN_TEST_BILLING_KEY") end)

      settings = Billing.ensure_settings!()

      {:ok, updated} =
        Billing.configure_billing_key_source(
          settings,
          :secret_key,
          :env,
          %{"var" => "KILN_TEST_BILLING_KEY"},
          authorize?: false
        )

      assert updated.secret_key_provider == :env
      assert updated.secret_key_provider_config == %{"var" => "KILN_TEST_BILLING_KEY"}
      assert {:ok, "sk_from_env"} = KilnCMS.Keys.fetch(:billing_secret_key)
    end

    test "clears any previously stored ciphertext when switching away from :database" do
      System.put_env("KILN_TEST_BILLING_KEY", "sk_from_env")
      on_exit(fn -> System.delete_env("KILN_TEST_BILLING_KEY") end)

      settings = Billing.ensure_settings!()

      {:ok, settings} =
        Billing.store_billing_secret(settings, :secret_key, "sk_pasted", authorize?: false)

      assert settings.secret_key_encrypted

      {:ok, settings} =
        Billing.configure_billing_key_source(
          settings,
          :secret_key,
          :env,
          %{"var" => "KILN_TEST_BILLING_KEY"},
          authorize?: false
        )

      # Leaving the ciphertext behind would resurrect the old secret if the
      # provider were ever switched back to :database.
      refute settings.secret_key_encrypted
    end

    test "reports an unset env var" do
      settings = Billing.ensure_settings!()

      assert {:error, error} =
               Billing.configure_billing_key_source(
                 settings,
                 :secret_key,
                 :env,
                 %{"var" => "KILN_DEFINITELY_UNSET"},
                 authorize?: false
               )

      assert Exception.message(error) =~ "KILN_DEFINITELY_UNSET"
    end

    test "refuses a blank pointer instead of falling back to the DKIM default var" do
      # `KilnCMS.Keys.Providers.Env` defaults to "DKIM_PRIVATE_KEY" when its
      # config carries no "var", so accepting a blank pointer here would resolve
      # a billing secret to the DKIM SIGNING KEY and send it to the payment
      # provider as a bearer token.
      System.put_env("DKIM_PRIVATE_KEY", "-----BEGIN RSA PRIVATE KEY-----")
      on_exit(fn -> System.delete_env("DKIM_PRIVATE_KEY") end)

      settings = Billing.ensure_settings!()

      assert {:error, error} =
               Billing.configure_billing_key_source(
                 settings,
                 :secret_key,
                 :env,
                 %{"var" => ""},
                 authorize?: false
               )

      assert Exception.message(error) =~ "environment variable"

      refute match?(
               {:ok, "-----BEGIN RSA PRIVATE KEY-----"},
               KilnCMS.Keys.fetch(:billing_secret_key)
             )
    end

    test "refuses a missing file path" do
      settings = Billing.ensure_settings!()

      assert {:error, error} =
               Billing.configure_billing_key_source(
                 settings,
                 :secret_key,
                 :file,
                 %{"path" => "/nonexistent/kiln-billing-key"},
                 authorize?: false
               )

      assert Exception.message(error) =~ "cannot read"
    end
  end

  describe "configured?/0" do
    test "false with no settings row" do
      refute Billing.configured?()
    end

    test "false with only one secret stored" do
      settings = Billing.ensure_settings!()

      {:ok, _settings} =
        Billing.store_billing_secret(settings, :secret_key, "sk_test_abc", authorize?: false)

      refute Billing.configured?()
    end

    test "true once both secrets resolve" do
      settings = Billing.ensure_settings!()

      {:ok, settings} =
        Billing.store_billing_secret(settings, :secret_key, "sk_test_abc", authorize?: false)

      {:ok, _settings} =
        Billing.store_billing_secret(settings, :webhook_secret, "whsec_xyz", authorize?: false)

      assert Billing.configured?()
    end

    test "false again after clear_credentials" do
      settings = Billing.ensure_settings!()

      {:ok, settings} =
        Billing.store_billing_secret(settings, :secret_key, "sk_test_abc", authorize?: false)

      {:ok, settings} =
        Billing.store_billing_secret(settings, :webhook_secret, "whsec_xyz", authorize?: false)

      assert Billing.configured?()

      {:ok, cleared} = Billing.clear_billing_credentials(settings, authorize?: false)

      refute cleared.secret_key_encrypted
      refute cleared.webhook_secret_encrypted
      refute Billing.configured?()
    end
  end

  describe "policies" do
    test "a platform admin may read and write" do
      admin = user(:admin)
      settings = Billing.ensure_settings!()

      assert {:ok, _updated} =
               Billing.store_billing_secret(settings, :secret_key, "sk_test_abc", actor: admin)

      assert {:ok, [_settings]} = Billing.list_settings(actor: admin)
    end

    test "an editor may not read or write" do
      editor = user(:editor)
      settings = Billing.ensure_settings!()

      assert {:error, %Ash.Error.Forbidden{}} =
               Billing.store_billing_secret(settings, :secret_key, "sk_test_abc", actor: editor)

      assert {:ok, []} = Billing.list_settings(actor: editor)
    end

    test "a viewer may not write" do
      viewer = user(:viewer)
      settings = Billing.ensure_settings!()

      assert {:error, %Ash.Error.Forbidden{}} =
               Billing.store_billing_secret(settings, :secret_key, "sk_test_abc", actor: viewer)
    end

    test "a DEFAULT-ORG admin membership does not grant access" do
      # The `Mail.Settings` hazard as an executable assertion: this resource is
      # tenant-less, so if its policy used `Checks.OrgAdmin` the check would
      # resolve this actor against the default org and let them rewrite payment
      # credentials for every site on the instance.
      # The default org already exists (seeded by the #336 backfill migration),
      # so use it rather than creating a second row on the same slug.
      viewer = user(:viewer)

      Ash.Seed.seed!(KilnCMS.Accounts.OrgMembership, %{
        organization_id: KilnCMS.Accounts.default_org_id(),
        user_id: viewer.id,
        role: :admin
      })

      settings = Billing.ensure_settings!()

      assert {:error, %Ash.Error.Forbidden{}} =
               Billing.store_billing_secret(settings, :secret_key, "sk_test_abc", actor: viewer)
    end

    test "an anonymous caller may not read" do
      Billing.ensure_settings!()

      assert {:ok, []} = Billing.list_settings(actor: nil)
    end
  end
end

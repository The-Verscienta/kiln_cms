defmodule KilnCMS.Keys.VaultRotationTest do
  @moduledoc """
  The vault across a `SECRET_KEY_BASE` rotation (#1487): the read-only
  dual-key window, the explicit-secret primitives the re-encryption walk is
  built on, and the guard that keeps every vault column discoverable.

  `async: false` because the rotation is simulated by swapping the endpoint's
  `secret_key_base` in application env, which every test in the VM reads.
  """
  use ExUnit.Case, async: false

  alias KilnCMS.Keys.Vault
  alias KilnCMS.Keys.Vault.Ciphertext

  @old "old-secret-key-base-" <> String.duplicate("o", 64)
  @new "new-secret-key-base-" <> String.duplicate("n", 64)

  setup do
    endpoint = Application.get_env(:kiln_cms, KilnCMSWeb.Endpoint)
    vault = Application.get_env(:kiln_cms, Vault)

    on_exit(fn ->
      Application.put_env(:kiln_cms, KilnCMSWeb.Endpoint, endpoint)

      if vault,
        do: Application.put_env(:kiln_cms, Vault, vault),
        else: Application.delete_env(:kiln_cms, Vault)
    end)

    :ok
  end

  defp rotate_to(current, previous) do
    endpoint = Application.get_env(:kiln_cms, KilnCMSWeb.Endpoint)

    Application.put_env(
      :kiln_cms,
      KilnCMSWeb.Endpoint,
      Keyword.put(endpoint, :secret_key_base, current)
    )

    Application.put_env(:kiln_cms, Vault, previous_secret_key_bases: previous)
  end

  describe "the dual-key window" do
    test "ciphertext from before the rotation opens while the old secret is previous" do
      stored = Vault.encrypt("dkim private key", @old)

      rotate_to(@new, [@old])
      assert {:ok, "dkim private key"} = Vault.decrypt(stored)
    end

    test "and not once the old secret is retired" do
      stored = Vault.encrypt("dkim private key", @old)

      rotate_to(@new, [])
      assert {:error, :decrypt_failed} = Vault.decrypt(stored)
    end

    # The window is read-only. If writes went to the old key too, retiring it
    # would orphan everything written during the window.
    test "writes during the window use only the current secret" do
      rotate_to(@new, [@old])
      written = Vault.encrypt("billing secret")

      assert {:ok, "billing secret"} = Vault.decrypt(written, @new)
      assert {:error, :decrypt_failed} = Vault.decrypt(written, @old)
    end

    test "a blank or duplicate previous secret is the same as none" do
      rotate_to(@new, ["", "   ", @new, @old, @old])
      assert Vault.previous_secret_key_bases() == [@old]

      rotate_to(@new, [""])
      assert Vault.previous_secret_key_bases() == []
    end
  end

  describe "explicit-secret primitives" do
    test "decrypt/2 tries exactly the secret it is given" do
      stored = Vault.encrypt("actor key", @old)

      assert {:ok, "actor key"} = Vault.decrypt(stored, @old)
      assert {:error, :decrypt_failed} = Vault.decrypt(stored, @new)
      assert {:error, :decrypt_failed} = Vault.decrypt("too short", @old)
    end
  end

  describe "which columns hold vault ciphertext" do
    # The five columns #1487 named. Pinned here so a column quietly dropping
    # out of discovery (a type reverted to `:binary`) fails loudly, alongside
    # the guard below.
    @known [
      {KilnCMS.Billing.Settings, :secret_key_encrypted},
      {KilnCMS.Billing.Settings, :webhook_secret_encrypted},
      {KilnCMS.CMS.SiteAiProvider, :api_key_encrypted},
      {KilnCMS.CMS.SiteMailRelay, :password_encrypted},
      {KilnCMS.CMS.SiteSsoProvider, :client_secret_encrypted},
      {KilnCMS.CMS.SiteMeilisearch, :api_key_encrypted},
      {KilnCMS.CMS.SiteVapidKey, :private_key_encrypted},
      {KilnCMS.CMS.StorageProfile, :secret_access_key_encrypted},
      {KilnCMS.CMS.WebhookEndpoint, :secret_encrypted},
      {KilnCMS.Federation.SiteFederation, :private_key_encrypted},
      {KilnCMS.Mail.Settings, :dkim_private_key_encrypted},
      {KilnCMS.Social.Account, :credential_encrypted}
    ]

    test "discovery finds every column the vault writes" do
      assert Enum.sort(@known) -- Vault.encrypted_attributes() == []
    end

    # Every other `:binary`-stored attribute in the app, and why it is not
    # vault ciphertext. A new vault column declared as plain `:binary` lands
    # here as a failure instead of being orphaned by the next rotation.
    @not_vault %{
      {KilnCMS.Accounts.ApiKey, :api_key_hash} => "a SHA-256 hash, not ciphertext",
      {KilnCMS.Accounts.Passkey, :public_key} => "a public COSE key",
      {KilnCMS.Accounts.User, :totp_secret} => "stored raw, not through the vault",
      {KilnCMS.Accounts.User, :totp_pending_secret} => "stored raw, not through the vault"
    }

    test "every binary attribute is vault ciphertext or accounted for" do
      binary_attributes =
        for domain <- Application.fetch_env!(:kiln_cms, :ash_domains),
            resource <- Ash.Domain.Info.resources(domain),
            attribute <- Ash.Resource.Info.attributes(resource),
            Ash.Type.storage_type(attribute.type, attribute.constraints) == :binary,
            uniq: true,
            do: {resource, attribute.name, attribute.type}

      unaccounted =
        for {resource, name, type} <- binary_attributes,
            type != Ciphertext,
            not Map.has_key?(@not_vault, {resource, name}),
            do: {resource, name}

      assert unaccounted == [], """
      These attributes store binary data but are neither
      `KilnCMS.Keys.Vault.Ciphertext` nor listed in @not_vault:

        #{inspect(unaccounted)}

      If one holds `Vault.encrypt/1` output, declare it as
      `KilnCMS.Keys.Vault.Ciphertext` so `mix kiln.vault.reencrypt` walks it —
      otherwise rotating SECRET_KEY_BASE orphans it. If not, add it to
      @not_vault with the reason.
      """

      # And the allowlist cannot rot: every entry still names a real binary
      # attribute that is not ciphertext.
      present = MapSet.new(binary_attributes, fn {r, n, _type} -> {r, n} end)
      assert Enum.reject(Map.keys(@not_vault), &MapSet.member?(present, &1)) == []
    end
  end
end

defmodule KilnCMS.KeysTest do
  @moduledoc """
  Coverage for the key-provider subsystem: vault encryption at rest, the
  env/file/database providers, and the RSA/PEM helpers behind DKIM key
  management.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Keys
  alias KilnCMS.Keys.Providers
  alias KilnCMS.Keys.Vault

  describe "Vault" do
    test "encrypt/decrypt round-trips and never stores plaintext" do
      secret = "-----BEGIN RSA PRIVATE KEY-----\nsecret material\n"
      encrypted = Vault.encrypt(secret)

      refute encrypted =~ "secret material"
      assert {:ok, ^secret} = Vault.decrypt(encrypted)
    end

    test "tampered or malformed ciphertext fails closed" do
      encrypted = Vault.encrypt("secret")
      <<head::binary-size(30), byte, rest::binary>> = encrypted
      tampered = <<head::binary, Bitwise.bxor(byte, 1), rest::binary>>

      assert {:error, :decrypt_failed} = Vault.decrypt(tampered)
      assert {:error, :decrypt_failed} = Vault.decrypt("too short")
    end
  end

  describe "RSA/PEM helpers" do
    test "generated keys are PKCS#1 PEM that validate and yield a public key" do
      pem = Keys.generate_rsa_pem()

      assert pem =~ "BEGIN RSA PRIVATE KEY"
      assert :ok = Keys.validate_private_key_pem(pem)
      assert {:ok, public_b64} = Keys.rsa_public_key_b64(pem)
      # The p= value must be valid base64 DER (SubjectPublicKeyInfo).
      assert {:ok, _der} = Base.decode64(public_b64)
    end

    test "the derived public key is stable per key and distinct across keys" do
      pem = Keys.generate_rsa_pem()

      assert Keys.rsa_public_key_b64(pem) == Keys.rsa_public_key_b64(pem)
      refute Keys.rsa_public_key_b64(pem) == Keys.rsa_public_key_b64(Keys.generate_rsa_pem())
    end

    test "rejects garbage and flags PKCS#8 distinctly" do
      assert {:error, :invalid_pem} = Keys.validate_private_key_pem("not a key")

      pkcs8 =
        "-----BEGIN PRIVATE KEY-----\nMIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQ==\n-----END PRIVATE KEY-----\n"

      assert {:error, :pkcs8_unsupported} = Keys.validate_private_key_pem(pkcs8)
      assert Keys.describe_error(:pkcs8_unsupported) =~ "openssl rsa"
    end

    test "selectors are DNS-label-safe and unique" do
      selectors = for _i <- 1..20, do: Keys.new_selector()

      assert Enum.all?(selectors, &(&1 =~ ~r/^kiln\d{6}[0-9a-f]{8}$/))
      assert selectors == Enum.uniq(selectors)
    end
  end

  describe "providers" do
    test "env provider reads its variable and reports unset ones" do
      var = "KILN_TEST_DKIM_#{System.unique_integer([:positive])}"
      pem = Keys.generate_rsa_pem()

      assert {:error, {:env_var_unset, ^var}} = Providers.Env.fetch(%{"var" => var})

      System.put_env(var, pem)
      on_exit(fn -> System.delete_env(var) end)

      assert {:ok, ^pem} = Providers.Env.fetch(%{"var" => var})
      refute Providers.Env.writable?()
    end

    @tag :tmp_dir
    test "file provider reads its path and reports unreadable ones", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "dkim.pem")
      pem = Keys.generate_rsa_pem()

      assert {:error, {:unreadable, ^path, :enoent}} = Providers.File.fetch(%{"path" => path})
      assert {:error, :no_path_configured} = Providers.File.fetch(%{})

      File.write!(path, pem)
      assert {:ok, ^pem} = Providers.File.fetch(%{"path" => path})
      refute Providers.File.writable?()
    end

    test "database provider decrypts vault material" do
      pem = Keys.generate_rsa_pem()
      encrypted = Vault.encrypt(pem)

      assert {:ok, ^pem} = Providers.Database.fetch(%{"encrypted" => encrypted})
      assert {:error, :no_key_generated} = Providers.Database.fetch(%{"encrypted" => nil})
      assert Providers.Database.writable?()
    end

    test "writable?/1 distinguishes generate-here (database) from point-at-source providers" do
      assert Keys.writable?(:database)
      refute Keys.writable?(:env)
      refute Keys.writable?(:file)
    end
  end
end

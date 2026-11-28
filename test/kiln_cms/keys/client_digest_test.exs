defmodule KilnCMS.Keys.ClientDigestTest do
  @moduledoc """
  The digest stored client keys go under (#3501): an HMAC keyed from
  `secret_key_base`, so a row in a dump names nobody without the secret.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Keys.ClientDigest
  alias KilnCMS.Keys.Vault

  @key "inet:203.0.113.5"

  test "is not a plain SHA-256 of the key" do
    for key <- [@key, "203.0.113.5", "org|198.51.100.7/32", "ada@example.com"] do
      refute ClientDigest.digest(key) == :crypto.hash(:sha256, key)
    end
  end

  test "is 32 bytes, and stable for one key under one secret" do
    assert <<_::binary-size(32)>> = ClientDigest.digest(@key)
    assert ClientDigest.digest(@key) == ClientDigest.digest(@key)
    assert ClientDigest.digest(@key, "s") == ClientDigest.digest(@key, "s")
  end

  test "different keys differ" do
    refute ClientDigest.digest(@key) == ClientDigest.digest("inet:203.0.113.6")
  end

  test "the configured digest is the one under the endpoint's secret_key_base" do
    assert ClientDigest.digest(@key) == ClientDigest.digest(@key, Vault.secret_key_base())
  end

  test "a different secret gives a different digest" do
    secret = Vault.secret_key_base()
    refute ClientDigest.digest(@key, secret) == ClientDigest.digest(@key, secret <> "x")
  end

  # Pins the derivation: Plug.Crypto.KeyGenerator's defaults (PBKDF2-HMAC-SHA256,
  # 1000 iterations, 32 bytes) under this label. A change to any of them moves
  # every stored key, which is a rotation and has to be one on purpose.
  test "matches the known derivation" do
    secret = Vault.secret_key_base()
    key = :crypto.pbkdf2_hmac(:sha256, secret, "kiln client key digest v1", 1000, 32)

    assert ClientDigest.digest(@key) == :crypto.mac(:hmac, :sha256, key, @key)

    assert ClientDigest.digest(@key, "fixed") ==
             :crypto.mac(
               :hmac,
               :sha256,
               :crypto.pbkdf2_hmac(:sha256, "fixed", "kiln client key digest v1", 1000, 32),
               @key
             )
  end
end

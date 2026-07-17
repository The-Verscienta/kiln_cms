defmodule KilnCMS.Accounts.TotpTest do
  @moduledoc "TOTP correctness, pinned to the RFC 6238 published test vectors."
  use ExUnit.Case, async: true

  alias KilnCMS.Accounts.Totp

  # RFC 6238 Appendix B: the SHA-1 seed is the ASCII "12345678901234567890".
  @seed "12345678901234567890"

  # Appendix B publishes 8-digit codes; a 6-digit TOTP is the low 6 digits.
  @vectors [
    {59, "287082"},
    {1_111_111_109, "081804"},
    {1_111_111_111, "050471"},
    {1_234_567_890, "005924"},
    {2_000_000_000, "279037"}
  ]

  test "matches the RFC 6238 test vectors" do
    for {time, code} <- @vectors do
      assert Totp.code_at(@seed, time) == code, "wrong code at t=#{time}"
    end
  end

  test "valid?/3 accepts the current step and rejects a wrong code" do
    secret = Totp.generate_secret()
    now = System.system_time(:second)

    assert Totp.valid?(secret, Totp.code_at(secret, now), time: now)
    refute Totp.valid?(secret, "000000", time: now) or Totp.code_at(secret, now) == "000000"
  end

  test "valid?/3 tolerates ±1 step of drift but not ±2" do
    secret = Totp.generate_secret()
    now = 1_600_000_000

    assert Totp.valid?(secret, Totp.code_at(secret, now - 30), time: now)
    assert Totp.valid?(secret, Totp.code_at(secret, now + 30), time: now)
    refute Totp.valid?(secret, Totp.code_at(secret, now - 90), time: now)
  end

  test "base32_encode/1 is unpadded uppercase RFC 4648" do
    # RFC 4648 test vector: "foobar" → "MZXW6YTBOI".
    assert Totp.base32_encode("foobar") == "MZXW6YTBOI"
  end

  test "otpauth_uri/3 is a scannable provisioning URI" do
    uri = Totp.otpauth_uri(Totp.generate_secret(), "user@example.com", issuer: "KilnCMS")
    assert uri =~ ~r{^otpauth://totp/KilnCMS:user@example.com\?}
    assert uri =~ ~r/secret=[A-Z2-7]+/
    assert uri =~ "issuer=KilnCMS"
  end
end

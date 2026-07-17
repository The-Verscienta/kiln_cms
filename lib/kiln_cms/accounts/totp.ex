defmodule KilnCMS.Accounts.Totp do
  @moduledoc """
  RFC 6238 Time-based One-Time Passwords (TOTP) for two-factor authentication —
  built on Erlang's `:crypto` (HMAC-SHA1) with **no external dependency**.

  Compatible with standard authenticator apps (Google Authenticator, 1Password,
  Authy, …): `otpauth_uri/3` produces the `otpauth://totp/...` string they scan
  (or the `base32_encode/1` secret can be typed in), and `valid?/3` checks a
  6-digit code against the current 30-second step, allowing ±1 step of clock
  drift.

  Correctness is pinned by the published RFC 6238 test vectors (see
  `KilnCMS.Accounts.TotpTest`).
  """

  # RFC 4226/6238 defaults.
  @digits 6
  @period 30
  # Steps of clock skew tolerated on either side (±30s).
  @drift 1
  @base32_alphabet ~c"ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

  @doc "A fresh 20-byte (160-bit) secret — the SHA-1 key size RFC 4226 recommends."
  @spec generate_secret() :: binary()
  def generate_secret, do: :crypto.strong_rand_bytes(20)

  @doc """
  Whether `code` is a valid TOTP for `secret` right now (or at `:time`, a Unix
  timestamp in seconds — used by tests). Accepts a code from the current step or
  either adjacent step, and compares in constant time.
  """
  @spec valid?(binary(), String.t(), keyword()) :: boolean()
  def valid?(secret, code, opts \\ []) when is_binary(secret) and is_binary(code) do
    time = Keyword.get(opts, :time, System.system_time(:second))
    candidate = String.trim(code)
    step = div(time, @period)

    Enum.any?(-@drift..@drift, fn offset ->
      Plug.Crypto.secure_compare(candidate, code_for_step(secret, step + offset))
    end)
  end

  @doc "The TOTP code for `secret` at Unix time `unix_time` (tests / enrolment display)."
  @spec code_at(binary(), integer()) :: String.t()
  def code_at(secret, unix_time), do: code_for_step(secret, div(unix_time, @period))

  # HOTP(secret, step): HMAC-SHA1 → dynamic truncation → `@digits`-digit code.
  defp code_for_step(secret, step) do
    hmac = :crypto.mac(:hmac, :sha, secret, <<step::unsigned-big-integer-size(64)>>)
    # Offset = low nibble of the last byte; read the 4 bytes there, clear the MSB.
    <<_::binary-size(19), last::unsigned-integer-size(8)>> = hmac
    offset = rem(last, 16)
    <<_::binary-size(^offset), truncated::unsigned-big-integer-size(32), _::binary>> = hmac

    truncated
    |> rem(0x80000000)
    |> rem(10 ** @digits)
    |> Integer.to_string()
    |> String.pad_leading(@digits, "0")
  end

  @doc """
  The `otpauth://totp/...` provisioning URI an authenticator app scans.
  `account` labels the entry (typically the user's email); `:issuer` names the
  service (default `"KilnCMS"`).
  """
  @spec otpauth_uri(binary(), String.t(), keyword()) :: String.t()
  def otpauth_uri(secret, account, opts \\ []) do
    issuer = Keyword.get(opts, :issuer, "KilnCMS")
    label = URI.encode("#{issuer}:#{account}")

    query =
      URI.encode_query(%{
        "secret" => base32_encode(secret),
        "issuer" => issuer,
        "algorithm" => "SHA1",
        "digits" => @digits,
        "period" => @period
      })

    "otpauth://totp/#{label}?#{query}"
  end

  @doc """
  RFC 4648 base32 (unpadded, uppercase) — the secret encoding authenticator apps
  expect. Only encoding is needed: the raw secret is stored, never re-parsed.
  """
  @spec base32_encode(binary()) :: String.t()
  def base32_encode(binary) when is_binary(binary) do
    pad_bits = rem(5 - rem(bit_size(binary), 5), 5)
    padded = <<binary::bitstring, 0::size(pad_bits)>>

    for <<group::size(5) <- padded>>, into: "" do
      <<Enum.at(@base32_alphabet, group)>>
    end
  end
end

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

  ## Whitespace is stripped, not trimmed

  Authenticator apps display the code as `123 456`, and Safari's
  `autocomplete="one-time-code"` fill and a plain paste both carry that inner
  space through. Normalizing *here* rather than at each call site is what makes
  the three surfaces that check a code — the browser prompt, the headless
  exchange, and the enrolment/disable forms in `/editor/settings` — agree: they
  used not to, and a paste that signed you in was rejected when you tried to
  turn 2FA off (#726).

  It is not cosmetic either. Attempts are budgeted per account
  (`KilnCMS.Accounts.AccountThrottle.consume_second_factor/1`), so a space costs
  one of five rather than one free retry — three pastes and one genuine
  clock-skew miss would lock a user out for fifteen minutes without their ever
  having entered a wrong code.
  """
  @spec valid?(binary(), String.t(), keyword()) :: boolean()
  def valid?(secret, code, opts \\ []) when is_binary(secret) and is_binary(code) do
    time = Keyword.get(opts, :time, System.system_time(:second))
    candidate = normalize(code)
    step = div(time, @period)

    Enum.any?(-@drift..@drift, fn offset ->
      Plug.Crypto.secure_compare(candidate, code_for_step(secret, step + offset))
    end)
  end

  @doc """
  A submitted code with all whitespace removed — see `valid?/3` on why inner
  whitespace and not just the ends.

  A code that is not valid UTF-8 is returned unchanged rather than normalized.
  `~r/\\s/u` raises `ArgumentError` on such a subject, and this now runs on an
  unauthenticated request body: `Plug.Parsers` accepts
  `application/x-www-form-urlencoded` regardless of the `:accepts` list, so
  `code=%FF%FE` reaches here. Unchanged is the right answer anyway — a code is
  six digits, so a non-UTF-8 one cannot match, and a 500 here would burn one of
  the account's five attempts per malformed request.
  """
  @spec normalize(String.t()) :: String.t()
  def normalize(code) when is_binary(code) do
    if String.valid?(code), do: String.replace(code, ~r/\s/u, ""), else: code
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

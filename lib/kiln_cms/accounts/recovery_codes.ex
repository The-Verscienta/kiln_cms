defmodule KilnCMS.Accounts.RecoveryCodes do
  @moduledoc """
  One-time 2FA recovery codes (issue #331, phase 2).

  A set of high-entropy backup codes minted when TOTP enrolment is confirmed
  (or on demand via regeneration). Each code signs the user in **once** when
  their authenticator is unavailable; using or regenerating invalidates it.

  Only SHA-256 hashes are stored (`totp_recovery_hashes` on the user) — the
  plaintext is shown exactly once at generation. Unlike passwords, the codes
  are uniformly random (40 bits), so a fast hash is appropriate; matching
  compares in constant time per candidate.
  """

  alias KilnCMS.Accounts.Totp

  @count 10
  # 5 random bytes → 8 base32 chars → shown as XXXX-XXXX.
  @bytes 5

  @doc "How many codes a set contains."
  @spec count() :: pos_integer()
  def count, do: @count

  @doc "A fresh plaintext code set (`XXXX-XXXX`, base32 alphabet)."
  @spec generate() :: [String.t()]
  def generate do
    Enum.map(1..@count, fn _ ->
      <<a::binary-size(4), b::binary-size(4)>> =
        Totp.base32_encode(:crypto.strong_rand_bytes(@bytes))

      "#{a}-#{b}"
    end)
  end

  @doc "The stored form of a code: SHA-256 of its normalized plaintext."
  @spec hash(String.t()) :: String.t()
  def hash(code) do
    :sha256 |> :crypto.hash(normalize(code)) |> Base.encode16(case: :lower)
  end

  @doc """
  Consume `code` from a stored hash set: `{:ok, remaining_hashes}` with the
  matched hash removed, or `:error` when nothing matches. Comparison is
  constant-time per candidate hash.
  """
  @spec consume([String.t()], String.t()) :: {:ok, [String.t()]} | :error
  def consume(hashes, code) when is_list(hashes) and is_binary(code) do
    candidate = hash(code)

    case Enum.find(hashes, &Plug.Crypto.secure_compare(&1, candidate)) do
      nil -> :error
      matched -> {:ok, List.delete(hashes, matched)}
    end
  end

  def consume(_hashes, _code), do: :error

  # Case/format-insensitive: `abcd-efgh`, `ABCD EFGH`, and `ABCDEFGH` all match.
  defp normalize(code) do
    code |> String.upcase() |> String.replace(~r/[\s-]/, "")
  end
end

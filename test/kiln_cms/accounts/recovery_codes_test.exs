defmodule KilnCMS.Accounts.RecoveryCodesTest do
  @moduledoc "One-time 2FA recovery codes (#331 phase 2) — generate/hash/consume."
  use ExUnit.Case, async: true

  alias KilnCMS.Accounts.RecoveryCodes

  test "generates the advertised number of XXXX-XXXX codes" do
    codes = RecoveryCodes.generate()

    assert length(codes) == RecoveryCodes.count()
    assert Enum.all?(codes, &Regex.match?(~r/^[A-Z2-7]{4}-[A-Z2-7]{4}$/, &1))
    # High-entropy: no duplicates in a set.
    assert length(Enum.uniq(codes)) == length(codes)
  end

  test "consume burns exactly the matched code" do
    [code | _] = codes = RecoveryCodes.generate()
    hashes = Enum.map(codes, &RecoveryCodes.hash/1)

    assert {:ok, remaining} = RecoveryCodes.consume(hashes, code)
    assert length(remaining) == length(hashes) - 1
    refute RecoveryCodes.hash(code) in remaining

    # The same code doesn't match twice.
    assert :error = RecoveryCodes.consume(remaining, code)
  end

  test "matching is case- and separator-insensitive" do
    [code | _] = codes = RecoveryCodes.generate()
    hashes = Enum.map(codes, &RecoveryCodes.hash/1)

    assert {:ok, _} = RecoveryCodes.consume(hashes, String.downcase(code))
    assert {:ok, _} = RecoveryCodes.consume(hashes, String.replace(code, "-", " "))
    assert {:ok, _} = RecoveryCodes.consume(hashes, String.replace(code, "-", ""))
  end

  test "an unknown code and junk input are rejected" do
    hashes = Enum.map(RecoveryCodes.generate(), &RecoveryCodes.hash/1)

    assert :error = RecoveryCodes.consume(hashes, "AAAA-AAAA")
    assert :error = RecoveryCodes.consume(hashes, "")
    assert :error = RecoveryCodes.consume([], "AAAA-AAAA")
  end
end

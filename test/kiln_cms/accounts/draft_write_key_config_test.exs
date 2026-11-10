defmodule KilnCMS.Accounts.DraftWriteKeyConfigTest do
  @moduledoc """
  The configurable lifetime cap on `:draft_write` keys (#2273).

  Split out of `KilnCMS.Accounts.DraftWriteKeyTest` and `async: false` because
  it rewrites `:draft_write_key_max_ttl_days`, which is VM-global: while it ran
  async, every concurrent test minting a 7-day draft-write key was refused
  (#2380).
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Accounts

  @key :draft_write_key_max_ttl_days

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "dw-cfg-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp mint(owner, days) do
    Accounts.mint_api_key(
      owner.id,
      "svc",
      DateTime.add(DateTime.utc_now(), days, :day),
      %{access: :draft_write},
      actor: user(:admin)
    )
  end

  test "the cap is configurable" do
    previous = Application.fetch_env(:kiln_cms, @key)
    Application.put_env(:kiln_cms, @key, 3)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:kiln_cms, @key, value)
        :error -> Application.delete_env(:kiln_cms, @key)
      end
    end)

    owner = user(:viewer)
    assert {:error, %Ash.Error.Invalid{}} = mint(owner, 7)
    assert {:ok, _} = mint(owner, 3)
  end
end

defmodule KilnCMS.Accounts.PasswordNoticeTest do
  @moduledoc """
  The one-shot "breached password" note (#2240): keyed by user id, a boolean,
  taken at most once, gone after its TTL.

  `async: false`: the TTL is application env, and the store is node-wide.
  """
  use ExUnit.Case, async: false

  alias KilnCMS.Accounts.PasswordNotice

  # The store is node-wide and other suites park notes they never take.
  setup do
    Cachex.clear(PasswordNotice.cache())
    :ok
  end

  defp id, do: Ecto.UUID.generate()

  test "a note is taken exactly once" do
    user_id = id()
    PasswordNotice.put(user_id)

    assert PasswordNotice.take(user_id)
    refute PasswordNotice.take(user_id)
  end

  test "a note is for its own user only" do
    mine = id()
    PasswordNotice.put(mine)

    refute PasswordNotice.take(id())
    assert PasswordNotice.take(mine)
  end

  test "nothing to take is false, and a non-id is false" do
    refute PasswordNotice.take(id())
    refute PasswordNotice.take(nil)
  end

  test "the note expires after its TTL" do
    original = Application.get_env(:kiln_cms, PasswordNotice)
    Application.put_env(:kiln_cms, PasswordNotice, ttl: 30)

    on_exit(fn ->
      if original,
        do: Application.put_env(:kiln_cms, PasswordNotice, original),
        else: Application.delete_env(:kiln_cms, PasswordNotice)
    end)

    user_id = id()
    PasswordNotice.put(user_id)
    Process.sleep(80)

    refute PasswordNotice.take(user_id)
  end

  test "the default TTL is short" do
    assert PasswordNotice.ttl() <= :timer.minutes(15)
  end

  test "what is stored is a boolean under the user id, with a TTL, and nothing else" do
    user_id = id()
    PasswordNotice.put(user_id)

    assert {:ok, [^user_id]} = Cachex.keys(PasswordNotice.cache())
    assert {:ok, true} = Cachex.get(PasswordNotice.cache(), user_id)
    assert {:ok, ttl} = Cachex.ttl(PasswordNotice.cache(), user_id)
    assert is_integer(ttl) and ttl > 0

    PasswordNotice.take(user_id)
  end
end

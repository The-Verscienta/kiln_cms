defmodule KilnCMS.Accounts.PasswordNoticeTest do
  @moduledoc """
  The one-shot "breached password" note (#2240): keyed by user id, its kind
  (`:set`, or `:sign_in` for an administrator's sign-in, #2407), taken at
  most once, gone after its TTL.

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

  test "what is stored is the kind under the user id, with a TTL, and nothing else" do
    user_id = id()
    PasswordNotice.put(user_id)

    assert {:ok, [^user_id]} = Cachex.keys(PasswordNotice.cache())
    assert {:ok, :set} = Cachex.get(PasswordNotice.cache(), user_id)
    assert {:ok, ttl} = Cachex.ttl(PasswordNotice.cache(), user_id)
    assert is_integer(ttl) and ttl > 0

    PasswordNotice.take(user_id)
  end

  describe "kinds (#2407)" do
    test "put/1 is a :set note; put/2 keeps its kind" do
      set = id()
      sign_in = id()
      PasswordNotice.put(set)
      PasswordNotice.put(sign_in, :sign_in)

      assert PasswordNotice.take(set) == :set
      assert PasswordNotice.take(sign_in) == :sign_in
      refute PasswordNotice.take(sign_in)
    end

    test "a bare true from before the kinds reads as :set" do
      user_id = id()
      Cachex.put(PasswordNotice.cache(), user_id, true)

      assert PasswordNotice.take(user_id) == :set
    end

    test "each kind has its own message, and message/0 is the :set one" do
      assert PasswordNotice.message() == PasswordNotice.message(:set)
      refute PasswordNotice.message(:sign_in) == PasswordNotice.message(:set)
      assert PasswordNotice.message(:sign_in) =~ "account page"
    end
  end
end

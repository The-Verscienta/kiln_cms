defmodule KilnCMS.RateLimitHelpersTest do
  @moduledoc """
  Pins the restore contract behind #1614: a test that changes the RateLimit
  env gets `config/test.exs`'s value back — not a delete, and not whatever the
  previous test left — and a leak fails the next case setup by name.
  """
  # async: false — every test here writes the global RateLimit env.
  use ExUnit.Case, async: false

  alias KilnCMS.RateLimitHelpers
  alias KilnCMSWeb.RateLimit

  test "test_config/0 is the raised config/test.exs limits, not the shipped ones" do
    limits = Keyword.fetch!(RateLimitHelpers.test_config(), :limits)

    assert {1_000_000, _} = limits.gql
    refute limits.gql == Map.fetch!(RateLimit.default_limits(), :gql)
  end

  test "assert_test_limits!/0 passes on the test config and names a leak" do
    assert :ok = RateLimitHelpers.assert_test_limits!()

    try do
      Application.delete_env(:kiln_cms, RateLimit)

      assert_raise ExUnit.AssertionError, ~r/#1614/, &RateLimitHelpers.assert_test_limits!/0
    after
      RateLimitHelpers.restore_limits()
    end
  end

  test "restore_limits/0 puts config/test.exs's value back, whatever the env holds" do
    # The #1614 shape: a previous test left the env deleted, so a restore that
    # captured the current value would faithfully put `nil` back.
    Application.delete_env(:kiln_cms, RateLimit)
    RateLimitHelpers.put_limit(:gql, 2)

    RateLimitHelpers.restore_limits()

    assert Application.get_env(:kiln_cms, RateLimit) == RateLimitHelpers.test_config()
  end
end

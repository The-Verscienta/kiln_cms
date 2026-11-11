defmodule KilnCMS.Security.Posture.Checks.ApiKeysTest do
  @moduledoc """
  `core.api_keys` (#2252) against real keys: a narrow, short-lived key passes,
  and each change below turns it. The age rule is exercised by moving the
  report's `now`, not the key's timestamps.
  """
  use KilnCMS.DataCase, async: true

  import KilnCMS.OrgFixtures, only: [org: 1]
  import KilnCMS.PostureFixtures

  alias KilnCMS.Accounts
  alias KilnCMS.Security.Posture.Checks.ApiKeys

  setup do
    %{operator: user(:admin)}
  end

  defp mint!(owner, operator, attrs \\ %{}) do
    expires = Map.get(attrs, :expires_at, DateTime.add(DateTime.utc_now(), 30, :day))

    {:ok, key} =
      Accounts.mint_api_key(
        owner.id,
        Map.get(attrs, :name, "key-#{System.unique_integer([:positive])}"),
        expires,
        Map.take(attrs, [:access]),
        actor: operator
      )

    key
  end

  defp run(opts \\ []), do: ApiKeys.run(context(nil, opts))

  test "no valid key is not applicable" do
    assert %{status: :n_a, facts: %{valid_keys: 0}} = run()
  end

  test "an editor's read key passes", %{operator: operator} do
    mint!(user(:editor), operator)
    assert %{status: :pass, facts: %{valid_keys: 1}} = run()
  end

  test "an editor's read-write key passes: it writes only as an editor", %{operator: operator} do
    mint!(user(:editor), operator, %{access: :read_write})
    assert %{status: :pass} = run()
  end

  test "a platform admin's read-write key fails, named with its owner", %{operator: operator} do
    mint!(user(:editor), operator)
    mint!(operator, operator, %{access: :read_write, name: "robot"})

    result = run()
    assert result.status == :fail
    assert result.details == ["robot (#{operator.email})"]
    assert result.facts.admin_read_write == 1
  end

  test "a site admin's read-write key fails: an admin tier anywhere counts", %{operator: operator} do
    owner = user(:viewer) |> member!(org("pfkeys"), :admin)
    mint!(owner, operator, %{access: :read_write})

    assert %{status: :fail} = run()
  end

  test "a pending admin membership does not make the owner an admin", %{operator: operator} do
    owner = user(:viewer) |> member!(org("pfkeys"), :admin, status: :pending)
    mint!(owner, operator, %{access: :read_write})

    assert %{status: :pass} = run()
  end

  test "a revoked key is not counted", %{operator: operator} do
    key = mint!(operator, operator, %{access: :read_write})
    {:ok, _} = Accounts.revoke_api_key(key, actor: operator)

    assert %{status: :n_a} = run()
  end

  test "a key over 180 days old warns", %{operator: operator} do
    mint!(user(:editor), operator, %{expires_at: DateTime.add(DateTime.utc_now(), 300, :day)})

    assert %{status: :pass} = run()

    later = DateTime.add(DateTime.utc_now(), 200, :day)
    result = run(now: later)
    assert result.status == :warn
    assert result.facts.older_than_180_days == 1
    assert result.summary =~ "last use"
  end

  test "a key expiring more than a year out warns", %{operator: operator} do
    mint!(user(:editor), operator, %{expires_at: DateTime.add(DateTime.utc_now(), 400, :day)})

    assert %{status: :warn, facts: %{expiring_after_365_days: 1}} = run()
  end

  test "a key past its expiry at the report's now is not counted", %{operator: operator} do
    mint!(operator, operator, %{access: :read_write})
    assert %{status: :n_a} = run(now: DateTime.add(DateTime.utc_now(), 31, :day))
  end
end

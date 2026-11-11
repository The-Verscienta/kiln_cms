defmodule KilnCMS.Accounts.TierSourceMemoTest do
  @moduledoc """
  The console resolves a displayed tier from the membership it just read
  (`Scoping.tier_source_for_membership/3`), not the policy checks' per-process
  memo, so a page re-read after a write shows the tier the write left (#2142).
  """
  # async: false — turns the Scoping memo on with `Application.put_env`, which
  # is VM-global (config/test.exs sets it to 0 for every other test).
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.{OrgMembership, Scoping, User}

  setup do
    previous = Application.get_env(:kiln_cms, Scoping)
    Application.put_env(:kiln_cms, Scoping, memo_ttl_ms: 60_000)
    on_exit(fn -> Application.put_env(:kiln_cms, Scoping, previous) end)
  end

  test "a re-read membership wins over the memoized one" do
    user =
      Ash.Seed.seed!(User, %{
        email: "tier-memo-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :viewer
      })

    org_id = Accounts.default_org_id()

    membership =
      Ash.Seed.seed!(OrgMembership, %{
        user_id: user.id,
        organization_id: org_id,
        role: :viewer,
        granted_role: :editor,
        granted_role_expires_at: DateTime.add(DateTime.utc_now(), 5, :hour)
      })

    # Primes the memo with the live grant.
    assert {:editor, :member, _} = Scoping.tier_source(user, org_id)

    revoked = Ash.Seed.update!(membership, %{granted_role: nil, granted_role_expires_at: nil})

    # The memo still answers with the row as it was...
    assert {:editor, :member, _} = Scoping.tier_source(user, org_id)
    # ...the page's own read does not.
    assert {:viewer, :member, _} = Scoping.tier_source_for_membership(user, org_id, revoked)
    assert Scoping.tier_changes_for_membership(user, org_id, revoked) == []
  end
end

defmodule KilnCMS.Accounts.ErasureRaceTest do
  @moduledoc """
  Erasing an account (`KilnCMS.Accounts.Changes.AnonymizeUser`) against a
  write on the same person committed by another transaction at the same
  moment: a newsletter tier sync (#3006), a billing webhook's state change,
  and a site admin's membership edit (#2774).

  Run **outside** the sandbox (`Ecto.Adapters.SQL.Sandbox.unboxed_run/2`), on
  real connections whose writes commit, for the reason
  `KilnCMS.Accounts.RegistrationErasureRaceTest` gives: inside the sandbox a
  row lock never makes anything wait. Each interleaving is pinned with
  `KilnCMS.Test.Latch`: the first transaction holds after it has its locks,
  the second is shown to be waiting, then the first is released. Everything
  committed is deleted again on exit. No platform admin is committed: the
  erasure runs `authorize?: false`, as the staging scrub does, and the
  membership edit is a site admin's.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.OrgMembership
  alias KilnCMS.Accounts.User
  alias KilnCMS.Billing
  alias KilnCMS.CMS.Audiences
  alias KilnCMS.Repo
  alias KilnCMS.Test.Latch

  @moduletag :capture_log

  @gated hd(Audiences.gated())

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp uniq, do: System.unique_integer([:positive])

  defp seed_user(attrs \\ %{}) do
    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: "erasure-race-#{uniq()}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("erasure-race-123"),
          confirmed_at: DateTime.utc_now(),
          role: :viewer
        },
        attrs
      )
    )
  end

  defp seed_org(slug),
    do:
      Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
        name: "race #{slug}",
        slug: "#{slug}-#{uniq()}",
        status: :active
      })

  setup do
    start_supervised!({Latch, name: :erasure_race, listener: self()})

    {site, other, person} =
      unboxed(fn ->
        site = seed_org("erasure-race")
        other = seed_org("erasure-race-other")
        person = seed_user()

        for org <- [site, other] do
          Ash.Seed.seed!(OrgMembership, %{
            user_id: person.id,
            organization_id: org.id,
            role: :viewer
          })
        end

        {site, other, person}
      end)

    # Every account a test seeds is added here, so the cleanup finds it.
    {:ok, tracked} = Agent.start(fn -> [person.id] end)

    on_exit(fn ->
      ids = Agent.get(tracked, & &1)
      Agent.stop(tracked)
      unboxed(fn -> cleanup([site.id, other.id], ids) end)
    end)

    %{site: site, other: other, person: person, tracked: tracked}
  end

  # The erasure, run as the staging scrub runs it (see the moduledoc).
  defp erase(user), do: Accounts.anonymize_user(user, authorize?: false)

  # The erasure, holding after its own write — the account's row is taken
  # `FOR UPDATE` by then, and none of the erasure's after-action steps has
  # run — until released. A hook added to the changeset before the action
  # runs before the action's own.
  defp held_erasure(user) do
    held =
      user
      |> Ash.Changeset.new()
      |> Ash.Changeset.after_action(fn _changeset, record ->
        Latch.enter(:erasure_race)
        {:ok, record}
      end)

    Task.async(fn -> unboxed(fn -> Accounts.anonymize_user(held, authorize?: false) end) end)
  end

  # `fun` in a transaction held open, after it ran, until released.
  defp held(fun), do: in_flight(fn -> Repo.transaction(fn -> hold(fun.()) end) end)

  defp hold(result) do
    Latch.enter(:erasure_race)
    result
  end

  defp in_flight(fun), do: Task.async(fn -> unboxed(fun) end)

  # Once the first transaction is holding its locks, start `second` and show
  # it waits on them; then let the first commit. Returns the second's task.
  defp race(second) do
    assert_receive {:latch_started, :erasure_race, 1}, 5_000
    task = in_flight(second)
    refute Task.yield(task, 300), "the second transaction did not wait for the first"
    assert [_] = Latch.release_all(:erasure_race)
    task
  end

  defp reload(user), do: unboxed(fn -> Accounts.get_user!(user.id, authorize?: false) end)

  defp erased?(user), do: match?(%{anonymized_at: %DateTime{}}, reload(user))

  # ── a newsletter tier sync (#3006) ─────────────────────────────────────

  describe "a newsletter tier sync" do
    # A paid tier on the site (with its managed segment) and the person's
    # membership on it, not yet entitling: activating it links a subscriber
    # row at the account's real address.
    setup %{site: site, person: person} do
      membership =
        unboxed(fn ->
          tier =
            Billing.create_tier!(
              %{
                name: "Race tier #{uniq()}",
                slug: "race-tier-#{uniq()}",
                audience: @gated,
                provider_price_id: "price_#{uniq()}"
              },
              authorize?: false,
              tenant: site.id
            )

          Ash.Seed.seed!(Billing.Membership, %{
            org_id: site.id,
            user_id: person.id,
            tier_id: tier.id,
            status: :incomplete
          })
        end)

      %{membership: membership}
    end

    defp activate(membership, site),
      do:
        Billing.apply_provider_state(membership, %{status: :active},
          authorize?: false,
          tenant: site.id
        )

    # Every subscriber row on the site that is linked to the account or carries
    # its real address.
    defp subscribers(person, site), do: unboxed(fn -> subscriber_rows(person, site) end)

    # On the calling connection, so a transaction sees its own writes.
    defp subscriber_rows(person, site) do
      %{rows: rows} =
        Repo.query!(
          "SELECT user_id IS NOT NULL FROM newsletter_subscribers " <>
            "WHERE org_id = $1 AND (user_id = $2 OR email = $3)",
          [Ecto.UUID.dump!(site.id), Ecto.UUID.dump!(person.id), to_string(person.email)]
        )

      rows
    end

    test "committed first: the erasure waits, then deletes the row it linked", ctx do
      sync =
        held(fn ->
          {activate(ctx.membership, ctx.site), subscriber_rows(ctx.person, ctx.site)}
        end)

      erasure = race(fn -> erase(ctx.person) end)

      # The sync linked a row at the real address before the erasure ran.
      assert {:ok, {{:ok, _active}, [[true]]}} = Task.await(sync, 10_000)
      assert {:ok, _erased} = Task.await(erasure, 10_000)

      assert erased?(ctx.person)
      assert subscribers(ctx.person, ctx.site) == []
      refute_received {:latch_timeout, _, _}
    end

    test "after the erasure committed its steps: the sync waits, then links nothing", ctx do
      erasure = held(fn -> erase(ctx.person) end)
      sync = race(fn -> activate(ctx.membership, ctx.site) end)

      assert {:ok, {:ok, _erased}} = Task.await(erasure, 10_000)
      assert {:ok, _settled} = Task.await(sync, 10_000)

      assert erased?(ctx.person)
      assert subscribers(ctx.person, ctx.site) == []
      refute_received {:latch_timeout, _, _}
    end
  end

  # ── a billing webhook's state change ──────────────────────────────────

  describe "a billing state change" do
    # A paid membership on each site, entitling: the erasure cancels both.
    setup %{site: site, other: other, person: person} do
      memberships =
        unboxed(fn ->
          for org <- [site, other] do
            tier =
              Ash.Seed.seed!(Billing.MembershipTier, %{
                org_id: org.id,
                name: "Tier #{uniq()}",
                slug: "race-tier-#{uniq()}",
                audience: @gated,
                provider_price_id: "price_#{uniq()}"
              })

            Ash.Seed.seed!(Billing.Membership, %{
              org_id: org.id,
              user_id: person.id,
              tier_id: tier.id,
              status: :active,
              provider_subscription_id: "sub_#{uniq()}"
            })
          end
        end)

      %{memberships: memberships}
    end

    defp past_due(membership),
      do:
        Billing.apply_provider_state(membership, %{status: :past_due},
          authorize?: false,
          tenant: membership.org_id
        )

    # The webhook takes the account's row before its membership's
    # (`LockAccount` on `:apply_provider_state`); the erasure takes the
    # account, then cancels every paid membership. Before the webhook locked
    # the account first, it held its membership and waited for the account
    # while the erasure held the account and waited for the membership.
    test "after the erasure locked the account: no deadlock, and the webhook settles", ctx do
      [_on_site, on_other] = ctx.memberships

      erasure = held_erasure(ctx.person)
      webhook = race(fn -> past_due(on_other) end)

      assert {:ok, _erased} = Task.await(erasure, 10_000)
      assert {:ok, _settled} = Task.await(webhook, 10_000)
      refute_received {:latch_timeout, _, _}

      # The recompute saw the tombstone under the lock and granted nothing.
      account = reload(ctx.person)
      assert %DateTime{} = account.anonymized_at
      assert account.audiences == []

      for org <- [ctx.site, ctx.other] do
        assert %{audiences: []} = membership(ctx.person, org)
      end

      # The webhook read its row before the erasure; it writes nothing back.
      assert paid_memberships(ctx.person) == [{:canceled, nil}, {:canceled, nil}]
    end

    test "committed first: the erasure waits, then cancels what it left", ctx do
      [_on_site, on_other] = ctx.memberships

      webhook = held(fn -> past_due(on_other) end)
      erasure = race(fn -> erase(ctx.person) end)

      assert {:ok, {:ok, _past_due}} = Task.await(webhook, 10_000)
      assert {:ok, _erased} = Task.await(erasure, 10_000)

      assert paid_memberships(ctx.person) == [{:canceled, nil}, {:canceled, nil}]
    end

    # Each paid membership's status and provider subscription id.
    defp paid_memberships(person) do
      unboxed(fn ->
        person.id
        |> Billing.memberships_for_export!(authorize?: false)
        |> Enum.map(&{&1.status, &1.provider_subscription_id})
      end)
    end
  end

  # ── a site admin's membership edit (#2774) ────────────────────────────

  describe "a membership edit" do
    # Run `authorize?: false`: only a platform admin may edit a membership,
    # and none is committed here (see the moduledoc). The lock is the
    # action's, whoever calls it.
    # The row is read before the race, as the Team page holds it.
    defp promote(person, org) do
      row = membership(person, org)
      fn -> Accounts.update_org_membership(row, %{role: :admin}, authorize?: false) end
    end

    defp grant(person, org) do
      row = membership(person, org)

      fn ->
        Accounts.grant_membership_temporary_role(
          row,
          %{
            granted_role: :admin,
            granted_role_expires_at: DateTime.add(DateTime.utc_now(), 3_600)
          },
          authorize?: false
        )
      end
    end

    test "after the erasure locked the account: it waits, then is refused", ctx do
      promoting = promote(ctx.person, ctx.site)
      erasure = held_erasure(ctx.person)
      edit = race(promoting)

      assert {:ok, _erased} = Task.await(erasure, 10_000)
      assert erased_error?(Task.await(edit, 10_000))
      assert %{role: :viewer, granted_role: nil} = membership(ctx.person, ctx.site)
      refute_received {:latch_timeout, _, _}
    end

    test "a temporary tier after the erasure locked the account: it waits, then is refused",
         ctx do
      granting = grant(ctx.person, ctx.site)
      erasure = held_erasure(ctx.person)
      edit = race(granting)

      assert {:ok, _erased} = Task.await(erasure, 10_000)
      assert erased_error?(Task.await(edit, 10_000))
      assert %{role: :viewer, granted_role: nil} = membership(ctx.person, ctx.site)
    end

    test "committed first: the erasure waits, then demotes the row it left", ctx do
      edit = held(promote(ctx.person, ctx.site))
      erasure = race(fn -> erase(ctx.person) end)

      assert {:ok, {:ok, %{role: :admin}}} = Task.await(edit, 10_000)
      assert {:ok, _erased} = Task.await(erasure, 10_000)
      assert %{role: :viewer, status: :active} = membership(ctx.person, ctx.site)
      refute_received {:latch_timeout, _, _}
    end
  end

  defp membership(person, org),
    do:
      unboxed(fn ->
        Accounts.get_org_membership!(person.id, org.id, authorize?: false)
      end)

  defp erased_error?({:error, error}),
    do: Enum.any?(error.errors, &match?(%KilnCMS.Accounts.Errors.AccountErased{}, &1))

  defp erased_error?(_result), do: false

  # Everything the tests committed: rows scoped to the two sites (a foreign
  # key between two scoped tables can refuse a delete until the other is
  # emptied, so loop until a pass makes no progress), the sites, then the
  # accounts with what hangs off them that is not site-scoped.
  defp cleanup(org_ids, user_ids) do
    orgs = Enum.map(org_ids, &Ecto.UUID.dump!/1)
    users = Enum.map(user_ids, &Ecto.UUID.dump!/1)

    %{rows: tables} =
      Repo.query!("""
      SELECT table_name FROM information_schema.columns
      WHERE column_name = 'org_id' AND table_schema = 'public'
      """)

    sweep(Enum.map(tables, &hd/1), orgs, 10)
    Repo.query!("DELETE FROM org_memberships WHERE organization_id = ANY($1)", [orgs])
    Repo.query!("DELETE FROM organizations WHERE id = ANY($1)", [orgs])

    ids = org_ids ++ user_ids
    Repo.query!("DELETE FROM oban_jobs WHERE args::text ~ ANY($1)", [ids])

    Repo.query!("DELETE FROM security_events WHERE actor_id = ANY($1) OR target_id = ANY($1)", [
      users
    ])

    Repo.query!("DELETE FROM api_keys WHERE user_id = ANY($1)", [users])
    Repo.query!("DELETE FROM tokens WHERE subject ~ ANY($1)", [user_ids])
    Repo.query!("DELETE FROM users WHERE id = ANY($1)", [users])
  end

  defp sweep([], _orgs, _passes), do: :ok
  defp sweep(_tables, _orgs, 0), do: :ok

  defp sweep(tables, orgs, passes) do
    left =
      Enum.reject(tables, fn table ->
        match?({:ok, _}, Repo.query(~s|DELETE FROM "#{table}" WHERE org_id = ANY($1)|, [orgs]))
      end)

    sweep(left, orgs, passes - 1)
  end
end

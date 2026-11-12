defmodule KilnCMS.Accounts.RegistrationErasureRaceTest do
  @moduledoc """
  Erasing an unconfirmed, rejected registration (#2514) against a write that
  makes the account more than that registration, committed by another
  transaction at the same moment: the account lock
  (`KilnCMS.Accounts.AccountLock`) decides which goes first, and the other
  sees what it committed.

  The sandbox runs every test on one connection inside one transaction, where
  a row lock never makes anything wait, so these run **outside** it
  (`Ecto.Adapters.SQL.Sandbox.unboxed_run/2`), on real connections whose
  writes commit, the way `KilnCMS.CMS.ReferenceCapRaceTest` does. Each
  interleaving is pinned with `KilnCMS.Test.Latch`: the first transaction
  holds after it has its locks, the second is shown to be waiting, then the
  first is released. Everything committed is deleted again on exit: the two
  sites (and every row scoped to them), the accounts, their tokens and API
  keys, and the Oban jobs that name them. No platform admin is committed: the
  deciding admin is an admin of the site.

  The domain rules themselves are `KilnCMS.Accounts.RegistrationErasureTest`.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Errors.AccountErased
  alias KilnCMS.Accounts.OrgMembership
  alias KilnCMS.Accounts.User
  alias KilnCMS.Billing
  alias KilnCMS.Billing.Entitlements
  alias KilnCMS.Repo
  alias KilnCMS.Test.Latch

  @moduletag :capture_log

  @password "registration-race-123"

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp uniq, do: System.unique_integer([:positive])

  defp seed_user(attrs) do
    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: "erase-race-#{uniq()}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt(@password),
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
    test_pid = self()
    start_supervised!({Latch, name: :erasure_race, listener: test_pid})

    {site, other, site_admin, users} =
      unboxed(fn ->
        site = seed_org("erase-race")
        other = seed_org("erase-race-other")
        site_admin = seed_user(%{})

        Ash.Seed.seed!(OrgMembership, %{
          user_id: site_admin.id,
          organization_id: site.id,
          role: :admin
        })

        Ash.Seed.seed!(KilnCMS.CMS.SiteRegistration, %{
          org_id: site.id,
          approval_required: true,
          rejected_accounts: :erase_unconfirmed
        })

        {site, other, site_admin, [site_admin.id]}
      end)

    # Every account a test seeds is added here, so the cleanup finds it.
    {:ok, tracked} = Agent.start(fn -> users end)

    on_exit(fn ->
      ids = Agent.get(tracked, & &1)
      Agent.stop(tracked)
      unboxed(fn -> cleanup([site.id, other.id], ids) end)
    end)

    %{site: site, other: other, site_admin: site_admin, tracked: tracked}
  end

  # An unconfirmed applicant whose registration created the account, waiting
  # on the site: erasable until something else attaches to it.
  defp applicant(%{site: site, tracked: tracked}) do
    unboxed(fn ->
      applicant = seed_user(%{confirmed_at: nil})
      Agent.update(tracked, &[applicant.id | &1])

      row =
        Ash.Seed.seed!(OrgMembership, %{
          user_id: applicant.id,
          organization_id: site.id,
          role: :viewer,
          status: :pending,
          created_account: true
        })

      {applicant, row}
    end)
  end

  defp reload_user(user),
    do: unboxed(fn -> Accounts.get_user!(user.id, authorize?: false) end)

  defp erased?(user), do: match?(%{anonymized_at: %DateTime{}}, reload_user(user))

  defp erased_error?({:error, error}), do: Enum.any?(error.errors, &match?(%AccountErased{}, &1))
  defp erased_error?(_result), do: false

  # The rejection, holding after its own write — with the account's row taken
  # `FOR UPDATE` by then and the erasure not yet run — until released.
  defp held_reject(row, admin) do
    held =
      row
      |> Ash.Changeset.new()
      |> Ash.Changeset.after_action(fn _changeset, record ->
        Latch.enter(:erasure_race)
        {:ok, record}
      end)

    Task.async(fn ->
      unboxed(fn -> Accounts.reject_registration(held, %{erase: true}, actor: admin) end)
    end)
  end

  defp reject_fun(row, admin),
    do: fn -> Accounts.reject_registration(row, %{erase: true}, actor: admin) end

  # `fun` in a transaction held open, after it ran, until released. Its
  # `after_transaction` hooks run inside it, which is the point of the test,
  # so the nested-hook warning they log is expected.
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

  defp create_membership_elsewhere(applicant, other) do
    Accounts.create_org_membership(
      %{organization_id: other.id, user_id: applicant.id, role: :viewer},
      authorize?: false
    )
  end

  describe "a membership created elsewhere" do
    test "after the erasure locked the account: it waits, then is refused", ctx do
      {applicant, row} = applicant(ctx)

      reject = held_reject(row, ctx.site_admin)
      create = race(fn -> create_membership_elsewhere(applicant, ctx.other) end)

      assert {:ok, %{__metadata__: %{registration_outcome: :erased}}} = Task.await(reject)
      assert erased_error?(Task.await(create))
      assert erased?(applicant)
      refute_received {:latch_timeout, _, _}
    end

    test "before the erasure: the erasure waits, sees it, and keeps the account", ctx do
      {applicant, row} = applicant(ctx)

      create = held(fn -> create_membership_elsewhere(applicant, ctx.other) end)
      reject = race(reject_fun(row, ctx.site_admin))

      assert {:ok, {:ok, _membership}} = Task.await(create)
      assert {:ok, %{status: :rejected} = rejected} = Task.await(reject)
      assert rejected.__metadata__[:registration_outcome] == :kept
      refute erased?(applicant)
      refute_received {:latch_timeout, _, _}
    end
  end

  describe "a paid membership started" do
    setup %{other: other} do
      tier =
        unboxed(fn ->
          Ash.Seed.seed!(Billing.MembershipTier, %{
            org_id: other.id,
            name: "Tier #{uniq()}",
            slug: "race-tier-#{uniq()}",
            audience: :member,
            provider_price_id: "price_#{uniq()}"
          })
        end)

      %{tier: tier}
    end

    defp start(applicant, tier, other),
      do:
        Billing.start_membership(%{user_id: applicant.id, tier_id: tier.id},
          authorize?: false,
          tenant: other.id
        )

    test "after the erasure locked the account: it waits, then is refused", ctx do
      {applicant, row} = applicant(ctx)

      reject = held_reject(row, ctx.site_admin)
      starting = race(fn -> start(applicant, ctx.tier, ctx.other) end)

      assert {:ok, %{__metadata__: %{registration_outcome: :erased}}} = Task.await(reject)
      assert erased_error?(Task.await(starting))
    end

    test "before the erasure: the account is kept", ctx do
      {applicant, row} = applicant(ctx)

      starting = held(fn -> start(applicant, ctx.tier, ctx.other) end)
      reject = race(reject_fun(row, ctx.site_admin))

      assert {:ok, {:ok, _membership}} = Task.await(starting)
      assert {:ok, %{__metadata__: %{registration_outcome: :kept}}} = Task.await(reject)
      refute erased?(applicant)
    end
  end

  describe "an API key minted" do
    defp mint(applicant),
      do:
        Accounts.mint_api_key(applicant.id, "ci", DateTime.add(DateTime.utc_now(), 86_400),
          authorize?: false
        )

    test "after the erasure locked the account: it waits, then is refused", ctx do
      {applicant, row} = applicant(ctx)

      reject = held_reject(row, ctx.site_admin)
      minting = race(fn -> mint(applicant) end)

      assert {:ok, %{__metadata__: %{registration_outcome: :erased}}} = Task.await(reject)
      assert erased_error?(Task.await(minting))
    end

    test "before the erasure: the account is kept", ctx do
      {applicant, row} = applicant(ctx)

      minting = held(fn -> mint(applicant) end)
      reject = race(reject_fun(row, ctx.site_admin))

      assert {:ok, {:ok, _key}} = Task.await(minting)
      assert {:ok, %{__metadata__: %{registration_outcome: :kept}}} = Task.await(reject)
      refute erased?(applicant)
    end
  end

  describe "a confirmation" do
    defp confirm(user) do
      strategy = AshAuthentication.Info.strategy!(User, :confirm_new_user)

      {:ok, token} =
        AshAuthentication.AddOn.Confirmation.confirmation_token(
          strategy,
          Ash.Changeset.new(user),
          user
        )

      fn ->
        AshAuthentication.Strategy.action(
          strategy,
          :confirm,
          %{"confirm" => token, "password" => @password},
          []
        )
      end
    end

    defp reset(user) do
      strategy = AshAuthentication.Info.strategy!(User, :password)
      {:ok, token} = AshAuthentication.Strategy.Password.reset_token_for(strategy, user)
      password = "a-brand-new-password-#{uniq()}"

      fn ->
        AshAuthentication.Strategy.action(
          strategy,
          :reset,
          %{"reset_token" => token, "password" => password, "password_confirmation" => password},
          []
        )
      end
    end

    test "committed while the erasure waited: the just-confirmed account is kept", ctx do
      {applicant, row} = applicant(ctx)
      confirming = unboxed(fn -> confirm(applicant) end)

      confirm = held(confirming)
      reject = race(reject_fun(row, ctx.site_admin))

      assert {:ok, {:ok, _confirmed}} = Task.await(confirm)
      assert {:ok, %{__metadata__: %{registration_outcome: :kept}}} = Task.await(reject)

      account = reload_user(applicant)
      assert %DateTime{} = account.confirmed_at
      assert account.anonymized_at == nil
    end

    test "after the erasure locked the account: it waits, then is refused", ctx do
      {applicant, row} = applicant(ctx)
      confirming = unboxed(fn -> confirm(applicant) end)

      reject = held_reject(row, ctx.site_admin)
      confirm = race(confirming)

      assert {:ok, %{__metadata__: %{registration_outcome: :erased}}} = Task.await(reject)

      # Refused: the erasure revoked every token the account held, the
      # confirmation token among them, and scrambled the password the
      # confirmation checked (#2594), so the account's row no longer holds the
      # password it was given (`GuardAccountTakeover`). Whichever check gets
      # there first refuses it. (The reset below gets as far as the lock, and
      # is refused there.)
      assert {:error, error} = Task.await(confirm)

      assert Enum.any?(
               error.errors,
               &(match?(%AshAuthentication.Errors.InvalidToken{type: :revocation}, &1) or
                   match?(%KilnCMS.Accounts.Errors.AccountTakenOver{}, &1))
             )

      account = reload_user(applicant)
      assert account.confirmed_at == nil
      assert %DateTime{} = account.anonymized_at
    end

    test "a password reset after the erasure locked the account sets no password on the tombstone",
         ctx do
      {applicant, row} = applicant(ctx)
      resetting = unboxed(fn -> reset(applicant) end)

      reject = held_reject(row, ctx.site_admin)
      reset = race(resetting)

      assert {:ok, %{__metadata__: %{registration_outcome: :erased}}} = Task.await(reject)
      assert erased_error?(Task.await(reset))

      account = reload_user(applicant)
      assert account.confirmed_at == nil
      refute Bcrypt.verify_pass(@password, account.hashed_password)
    end
  end

  describe "an entitlement recompute" do
    # The recompute writes the account, then the membership on the site; the
    # rejection locks the account, then the membership. Both orders finish.
    defp persist(applicant, site),
      do: Entitlements.persist(applicant, [], [:member], [:member], %{site.id => [:member]})

    test "holding the account and the membership first: the erasure waits and keeps", ctx do
      {applicant, row} = applicant(ctx)

      recompute = held(fn -> persist(applicant, ctx.site) end)
      reject = race(reject_fun(row, ctx.site_admin))

      assert {:ok, :ok} = Task.await(recompute, 10_000)
      assert {:ok, %{__metadata__: %{registration_outcome: :kept}}} = Task.await(reject, 10_000)
      refute erased?(applicant)
    end

    test "after the rejection locked the account and the membership: no deadlock", ctx do
      {applicant, row} = applicant(ctx)

      reject = held_reject(row, ctx.site_admin)
      recompute = race(fn -> persist(applicant, ctx.site) end)

      assert {:ok, %{__metadata__: %{registration_outcome: :erased}}} =
               Task.await(reject, 10_000)

      assert Task.await(recompute, 10_000) == :ok

      # The recompute saw the tombstone under the lock and wrote nothing.
      account = reload_user(applicant)
      assert %DateTime{} = account.anonymized_at
      assert account.audiences == []

      membership =
        unboxed(fn ->
          Accounts.get_org_membership!(applicant.id, ctx.site.id, authorize?: false)
        end)

      assert membership.status == :rejected
      assert membership.audiences == row.audiences
    end
  end

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

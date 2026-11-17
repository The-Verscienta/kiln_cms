defmodule KilnCMS.Accounts.ErasureBackfillTest do
  @moduledoc """
  `KilnCMS.Accounts.ErasureBackfill` gives an account erased by an earlier
  release the erasure steps added since: demoting its site memberships
  (#2774), which erasure used to leave granting a tier and audiences;
  deleting its linked newsletter subscriptions (#2991), which erasure used to
  leave mailing the real address; and #2514's steps, deleting its push
  subscriptions, private saved views and own notifications and clearing the
  audiences on its row; and revoking its API keys, which erasure used to
  leave live.
  """
  use KilnCMS.DataCase, async: true
  use Oban.Testing, repo: KilnCMS.Repo

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog
  import KilnCMS.OrgFixtures, only: [org: 1]

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.ErasureBackfill
  alias KilnCMS.Accounts.User
  alias KilnCMS.Newsletter

  # A run that changed nothing; each test merges in what it expects.
  @nothing %{
    memberships: 0,
    newsletter_accounts: 0,
    newsletter_subscribers: 0,
    audiences: 0,
    push_subscriptions: 0,
    saved_views: 0,
    notifications: 0,
    api_keys: 0,
    failed: 0
  }

  defp user(attrs \\ %{}) do
    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: "erasure-backfill-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: :viewer
        },
        attrs
      )
    )
  end

  # An account erased before #2991: tombstoned, its subscriber rows left in
  # place, still linked and confirmed at the address it was erased from.
  defp pre_fix_tombstone do
    user = user()
    rows = [link(user, Accounts.default_org_id()), link(user, org("erasure-backfill").id)]

    tombstone =
      Ash.Seed.update!(user, %{
        email: "anonymized-#{user.id}@deleted.invalid",
        name: nil,
        anonymized_at: DateTime.utc_now()
      })

    {tombstone, rows}
  end

  defp link(user, org_id) do
    opts = [authorize?: false, tenant: org_id]

    user.id
    |> Newsletter.link_member_subscriber!(%{email: to_string(user.email)}, opts)
    |> Newsletter.confirm_subscriber!(opts)
  end

  # Every backfill job row, whatever its state (`all_enqueued/1` lists only
  # the ones waiting to run).
  defp jobs do
    KilnCMS.Repo.all(from(j in Oban.Job, where: j.worker == "KilnCMS.Accounts.ErasureBackfill"))
  end

  defp count_subscriber_deletes(fun), do: count_deletes("newsletter_subscribers", fun)

  # How many DELETEs on `table` `fun` sends, in this process.
  defp count_deletes(table, fun) do
    pattern = ~r/^DELETE FROM "#{table}"/

    id = {__MODULE__, make_ref()}
    parent = self()

    :telemetry.attach(
      id,
      [:kiln_cms, :repo, :query],
      fn _event, _measurements, %{query: query}, _config ->
        if self() == parent and query =~ pattern,
          do: send(parent, {id, :delete})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(id)
    end

    Stream.repeatedly(fn ->
      receive do
        {^id, :delete} -> 1
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(& &1)
    |> length()
  end

  defp exists?(subscriber) do
    Newsletter.get_subscriber(subscriber.id,
      authorize?: false,
      tenant: subscriber.org_id,
      not_found_error?: false
    ) != {:ok, nil}
  end

  test "deletes an erased account's linked rows and leaves a live account's alone" do
    {_tombstone, rows} = pre_fix_tombstone()
    live = link(user(), Accounts.default_org_id())

    assert ErasureBackfill.run() == %{
             @nothing
             | newsletter_accounts: 1,
               newsletter_subscribers: 2
           }

    refute Enum.any?(rows, &exists?/1)
    assert exists?(live)
  end

  test "a second run finds nothing to do" do
    pre_fix_tombstone()

    assert %{newsletter_accounts: 1} = ErasureBackfill.run()

    assert ErasureBackfill.run() == @nothing
  end

  test "the job runs the pass" do
    {_tombstone, rows} = pre_fix_tombstone()

    assert :ok = perform_job(ErasureBackfill, %{})
    refute Enum.any?(rows, &exists?/1)
  end

  test "enqueue/0 queues one job however often a node boots" do
    assert :ok = ErasureBackfill.enqueue()
    assert :ok = ErasureBackfill.enqueue()

    assert [_one] = all_enqueued(worker: ErasureBackfill)
  end

  test "deletes only in the orgs where the account has rows" do
    {_tombstone, rows} = pre_fix_tombstone()
    # Sites where it has nothing must not each cost a DELETE.
    for n <- 1..3, do: org("erasure-backfill-empty-#{n}")

    deletes = count_subscriber_deletes(fn -> ErasureBackfill.run() end)

    assert deletes == length(rows)
  end

  test "a failed run fails the job, so Oban retries it, and the retry finishes the pass" do
    {_tombstone, rows} = pre_fix_tombstone()

    log =
      capture_log(fn ->
        Newsletter.with_actor(nil, fn ->
          assert {:error, message} = perform_job(ErasureBackfill, %{})
          assert message =~ "failed for 1 account"
        end)
      end)

    assert log =~ "erasure backfill could not forget newsletter rows"
    assert Enum.all?(rows, &exists?/1)

    assert :ok = perform_job(ErasureBackfill, %{})
    refute Enum.any?(rows, &exists?/1)
  end

  test "a job waiting to retry is not shadowed by uniqueness, nor duplicated by a boot" do
    {_tombstone, rows} = pre_fix_tombstone()
    assert :ok = ErasureBackfill.enqueue()

    capture_log(fn ->
      Newsletter.with_actor(nil, fn ->
        assert %{failure: 1} = Oban.drain_queue(queue: :default, with_scheduled: true)
      end)
    end)

    assert [%{state: "retryable", attempt: 1}] = jobs()

    # A node booting meanwhile queues nothing new: the retry is the job.
    assert :ok = ErasureBackfill.enqueue()
    assert [%{state: "retryable"}] = jobs()

    assert %{success: 1} = Oban.drain_queue(queue: :default, with_scheduled: true)
    assert [%{state: "completed"}] = jobs()
    refute Enum.any?(rows, &exists?/1)
  end

  describe "memberships (#2774)" do
    alias KilnCMS.Accounts.OrgMembership

    @gated hd(KilnCMS.CMS.Audiences.gated())

    defp membership(user, org_id, attrs) do
      Ash.Seed.seed!(
        OrgMembership,
        Map.merge(%{user_id: user.id, organization_id: org_id}, Map.new(attrs))
      )
    end

    defp reload(membership),
      do:
        Accounts.get_org_membership!(membership.user_id, membership.organization_id,
          authorize?: false
        )

    # An account erased before #2774: tombstoned, its memberships untouched.
    defp tombstone_with_memberships do
      user = user()
      site = org("erasure-backfill-members").id

      granting = [
        membership(user, Accounts.default_org_id(),
          role: :admin,
          audiences: [@gated],
          editable_types: ["post"]
        ),
        membership(user, site,
          role: :viewer,
          granted_role: :editor,
          granted_role_expires_at: DateTime.add(DateTime.utc_now(), 86_400)
        )
      ]

      bare = membership(user, org("erasure-backfill-bare").id, role: :viewer)

      Ash.Seed.update!(user, %{
        email: "anonymized-#{user.id}@deleted.invalid",
        anonymized_at: DateTime.utc_now()
      })

      {granting, bare}
    end

    test "demotes an erased account's memberships and leaves a live account's alone" do
      {[admin_row, granted_row], bare} = tombstone_with_memberships()
      live = membership(user(), Accounts.default_org_id(), role: :admin, audiences: [@gated])

      assert %{memberships: 2, failed: 0} = ErasureBackfill.run()

      assert %{role: :viewer, audiences: [], editable_types: ["post"]} = reload(admin_row)

      assert %{role: :viewer, granted_role: nil, granted_role_expires_at: nil} =
               reload(granted_row)

      # A bare viewer row grants nothing, so it is not counted or written.
      assert reload(bare).updated_at == bare.updated_at
      assert %{role: :admin, audiences: [@gated]} = reload(live)
    end

    test "a second run finds nothing to do" do
      tombstone_with_memberships()

      assert %{memberships: 2} = ErasureBackfill.run()
      assert %{memberships: 0, failed: 0} = ErasureBackfill.run()
    end

    test "the job runs the step" do
      {[admin_row, _granted_row], _bare} = tombstone_with_memberships()

      assert :ok = perform_job(ErasureBackfill, %{})
      assert %{role: :viewer} = reload(admin_row)
    end
  end

  describe "what erasure deletes since #2514" do
    alias KilnCMS.Accounts.PushSubscription
    alias KilnCMS.CMS
    alias KilnCMS.Notifications

    @gated hd(KilnCMS.CMS.Audiences.gated())

    defp push_subscription(user) do
      Ash.Seed.seed!(PushSubscription, %{
        user_id: user.id,
        org_id: Accounts.default_org_id(),
        endpoint: "https://push.example.com/x/#{System.unique_integer([:positive])}",
        p256dh: "key",
        auth: "auth",
        label: "iOS · Safari",
        vapid_public_key: "vapid"
      })
    end

    defp saved_view(user, org_id, shared?) do
      Ash.Seed.seed!(CMS.SavedView, %{
        owner_id: user.id,
        org_id: org_id,
        name: if(shared?, do: "Team", else: "Mine"),
        params: %{},
        shared: shared?
      })
    end

    defp notification(user, org_id) do
      Notifications.record_notification!(
        %{
          user_id: user.id,
          event: :comment_mention,
          content_type: "page",
          content_id: Ecto.UUID.generate(),
          title: "A draft"
        },
        tenant: org_id
      )
    end

    # One person's rows on two sites: a device, a private and a shared view
    # on each, a notification on each, and audiences on the account row.
    defp with_rows(user, sites) do
      %{
        push: push_subscription(user),
        private: Enum.map(sites, &saved_view(user, &1, false)),
        shared: Enum.map(sites, &saved_view(user, &1, true)),
        notifications: Enum.map(sites, &notification(user, &1))
      }
    end

    # An account erased before #2514: tombstoned, everything above left.
    defp pre_2514_tombstone(sites) do
      user = user(%{audiences: [@gated]})
      rows = with_rows(user, sites)

      tombstone =
        Ash.Seed.update!(user, %{
          email: "anonymized-#{user.id}@deleted.invalid",
          name: nil,
          anonymized_at: DateTime.utc_now()
        })

      {tombstone, rows}
    end

    defp sites, do: [Accounts.default_org_id(), org("erasure-backfill-2514").id]

    defp push_exists?(row),
      do:
        Accounts.get_push_subscription(row.id, authorize?: false, not_found_error?: false) !=
          {:ok, nil}

    defp view_exists?(row),
      do:
        CMS.get_saved_view(row.id,
          authorize?: false,
          tenant: row.org_id,
          not_found_error?: false
        ) != {:ok, nil}

    defp notification_exists?(row),
      do:
        Notifications.get_notification(row.id,
          authorize?: false,
          tenant: row.org_id,
          not_found_error?: false
        ) != {:ok, nil}

    defp audiences(user), do: Accounts.get_user!(user.id, authorize?: false).audiences

    test "deletes an erased account's rows, clears its audiences, and leaves a live account's alone" do
      sites = sites()
      {tombstone, rows} = pre_2514_tombstone(sites)
      live = user(%{audiences: [@gated]})
      live_rows = with_rows(live, sites)

      assert ErasureBackfill.run() == %{
               @nothing
               | audiences: 1,
                 push_subscriptions: 1,
                 saved_views: 2,
                 notifications: 2
             }

      assert audiences(tombstone) == []
      refute push_exists?(rows.push)
      refute Enum.any?(rows.private, &view_exists?/1)
      refute Enum.any?(rows.notifications, &notification_exists?/1)
      # A shared view is the team's, as erasure keeps it.
      assert Enum.all?(rows.shared, &view_exists?/1)

      assert audiences(live) == [@gated]
      assert push_exists?(live_rows.push)
      assert Enum.all?(live_rows.private ++ live_rows.shared, &view_exists?/1)
      assert Enum.all?(live_rows.notifications, &notification_exists?/1)
    end

    test "a second run finds nothing to do" do
      pre_2514_tombstone(sites())

      assert %{audiences: 1, push_subscriptions: 1} = ErasureBackfill.run()
      assert ErasureBackfill.run() == @nothing
    end

    test "deletes saved views and notifications only in the orgs where the account has rows" do
      {_tombstone, rows} = pre_2514_tombstone([Accounts.default_org_id()])
      for n <- 1..3, do: org("erasure-backfill-2514-empty-#{n}")

      deletes =
        count_deletes("saved_views", fn ->
          send(self(), {:notifications, count_deletes("notifications", &ErasureBackfill.run/0)})
        end)

      assert deletes == length(rows.private)
      assert_received {:notifications, notification_deletes}
      assert notification_deletes == length(rows.notifications)
    end

    test "a failed step fails the job, and the retry finishes it" do
      {_tombstone, rows} = pre_2514_tombstone(sites())

      log =
        capture_log(fn ->
          KilnCMS.Push.with_actor(nil, fn ->
            assert {:error, message} = perform_job(ErasureBackfill, %{})
            assert message =~ "failed for 1 account"
          end)
        end)

      assert log =~ "erasure backfill could not delete the push subscriptions"
      assert push_exists?(rows.push)
      # The other steps went on without it.
      refute Enum.any?(rows.private, &view_exists?/1)

      assert :ok = perform_job(ErasureBackfill, %{})
      refute push_exists?(rows.push)
    end
  end

  describe "API keys" do
    defp mint(owner) do
      admin = user(%{role: :admin})

      Accounts.mint_api_key!(owner.id, "reader", DateTime.add(DateTime.utc_now(), 30, :day),
        actor: admin
      )
    end

    # Erased with its keys left unrevoked, as erasure did before it revoked them.
    defp tombstone_with_keys(n) do
      owner = user()
      keys = for _ <- 1..n, do: mint(owner)

      Ash.Seed.update!(owner, %{
        email: "anonymized-#{owner.id}@deleted.invalid",
        name: nil,
        anonymized_at: DateTime.utc_now()
      })

      keys
    end

    defp revoked_at(key), do: Accounts.get_api_key!(key.id, authorize?: false).revoked_at

    test "revokes an erased account's live keys and leaves a live account's alone" do
      keys = tombstone_with_keys(2)
      live = mint(user())

      assert ErasureBackfill.run() == %{@nothing | api_keys: 2}

      assert Enum.all?(keys, &revoked_at/1)
      refute revoked_at(live)
    end

    test "leaves a key erasure already revoked as it was" do
      [key] = tombstone_with_keys(1)
      admin = user(%{role: :admin})
      revoked = Accounts.revoke_api_key!(key, actor: admin)

      assert ErasureBackfill.run() == @nothing
      assert revoked_at(key) == revoked.revoked_at
    end

    test "a second run finds nothing to do" do
      tombstone_with_keys(2)

      assert %{api_keys: 2} = ErasureBackfill.run()
      assert ErasureBackfill.run() == @nothing
    end

    test "the job runs the step" do
      keys = tombstone_with_keys(1)

      assert :ok = perform_job(ErasureBackfill, %{})
      assert Enum.all?(keys, &revoked_at/1)
    end
  end

  test "the test build does not enqueue it on boot" do
    # A boot-time enqueue commits outside every sandbox (see config/test.exs).
    assert Application.get_env(:kiln_cms, :erasure_backfill_on_boot) == false
  end
end

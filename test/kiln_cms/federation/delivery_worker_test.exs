defmodule KilnCMS.Federation.DeliveryWorkerTest do
  @moduledoc """
  The outbound half (#491): signing, the ledger's pending-vs-failed split, and
  what happens to a follower whose instance is gone.

  Dead instances are the normal case in the fediverse, so the failure paths
  here are the ordinary ones, not the edge cases.
  """
  use KilnCMS.DataCase, async: false
  use Oban.Testing, repo: KilnCMS.Repo

  alias KilnCMS.Federation
  alias KilnCMS.Federation.DeliveryWorker
  alias KilnCMS.Federation.Follower
  alias KilnCMS.FederationFixtures

  @remote "https://remote.example/users/alice"

  setup do
    FederationFixtures.enable_deployment!()
    org_id = KilnCMS.Accounts.default_org_id()
    FederationFixtures.enable_site!(org_id)

    {:ok, follower} =
      Federation.follow(@remote, @remote <> "/inbox", %{},
        authorize?: false,
        tenant: org_id
      )

    %{org_id: org_id, follower: follower}
  end

  defp queue_delivery(org_id, follower) do
    {:ok, delivery} =
      Federation.create_federation_delivery(
        %{
          follower_id: follower.id,
          inbox_uri: Follower.delivery_inbox(follower),
          activity_type: :create,
          activity: %{"type" => "Create", "id" => "https://kiln.example/ap/activity/create/1"}
        },
        authorize?: false,
        tenant: org_id
      )

    delivery
  end

  defp run(delivery, org_id, opts \\ []) do
    DeliveryWorker.perform(%Oban.Job{
      args: %{"org_id" => org_id, "delivery_id" => delivery.id},
      attempt: Keyword.get(opts, :attempt, 1),
      max_attempts: Keyword.get(opts, :max_attempts, 12)
    })
  end

  defp reload(delivery, org_id), do: Ash.reload!(delivery, authorize?: false, tenant: org_id)

  describe "a successful delivery" do
    test "is signed, settled, and resets the follower's failure count", ctx do
      test_pid = self()

      Req.Test.stub(KilnCMS.Federation, fn conn ->
        send(test_pid, {:delivered, conn.req_headers})
        Plug.Conn.send_resp(conn, 202, "")
      end)

      delivery = queue_delivery(ctx.org_id, ctx.follower)

      assert :ok = run(delivery, ctx.org_id)
      assert_received {:delivered, headers}

      names = headers |> Enum.map(&elem(&1, 0)) |> MapSet.new()
      assert "signature" in names
      assert "digest" in names
      assert "date" in names

      settled = reload(delivery, ctx.org_id)
      assert settled.state == :delivered
      assert settled.last_status == 202
    end
  end

  describe "a failing delivery" do
    setup do
      Req.Test.stub(KilnCMS.Federation, fn conn -> Plug.Conn.send_resp(conn, 500, "") end)
      :ok
    end

    # The ledger must not claim a verdict the job has not reached — a retry is
    # still pending, not failed.
    test "stays pending while attempts remain", ctx do
      delivery = queue_delivery(ctx.org_id, ctx.follower)

      assert {:error, _reason} = run(delivery, ctx.org_id, attempt: 1, max_attempts: 12)

      settled = reload(delivery, ctx.org_id)
      assert settled.state == :pending
      assert settled.last_status == 500

      # And the follower is untouched: one bad response is not a dead instance.
      assert Ash.reload!(ctx.follower, authorize?: false, tenant: ctx.org_id).consecutive_failures ==
               0
    end

    test "settles as failed on the last attempt and counts against the follower", ctx do
      delivery = queue_delivery(ctx.org_id, ctx.follower)

      # `:ok`, not an error: the attempt is exhausted and recorded, and
      # returning an error would only re-mark the job for the same fact.
      assert :ok = run(delivery, ctx.org_id, attempt: 12, max_attempts: 12)

      settled = reload(delivery, ctx.org_id)
      assert settled.state == :failed
      assert settled.attempts == 12

      assert Ash.reload!(ctx.follower, authorize?: false, tenant: ctx.org_id).consecutive_failures ==
               1
    end

    # A follower belongs to a stranger on another server; there is nobody here
    # to notice a disabled row, so it is deleted and that instance is free to
    # follow again.
    test "drops the follower once its instance has been dead long enough", ctx do
      Enum.each(1..(Federation.drop_follower_after() - 1), fn _ ->
        ctx.follower
        |> Ash.reload!(authorize?: false, tenant: ctx.org_id)
        |> Ash.update!(%{}, action: :record_failure, authorize?: false, tenant: ctx.org_id)
      end)

      delivery = queue_delivery(ctx.org_id, ctx.follower)
      assert :ok = run(delivery, ctx.org_id, attempt: 12, max_attempts: 12)

      assert [] = Ash.read!(Follower, authorize?: false, tenant: ctx.org_id)
      # The ledger row survives the follower it was addressed to.
      assert reload(delivery, ctx.org_id).state == :failed
    end
  end

  describe "when the site cannot sign" do
    test "the delivery settles rather than retrying forever", ctx do
      [settings] =
        Ash.read!(KilnCMS.Federation.SiteFederation, authorize?: false, tenant: ctx.org_id)

      Ash.update!(settings, %{}, action: :disable, authorize?: false, tenant: ctx.org_id)

      delivery = queue_delivery(ctx.org_id, ctx.follower)

      # Nothing about waiting makes an absent signing key appear.
      assert :ok = run(delivery, ctx.org_id)
      settled = reload(delivery, ctx.org_id)
      assert settled.state == :failed
      assert settled.last_error == "federation is not enabled for this site"
    end

    # #1487: a site that is ON but whose key the vault cannot open (a rotated
    # SECRET_KEY_BASE) used to be reported as "not enabled", which sent the
    # operator to the wrong switch.
    test "an unreadable key is named as the cause, not federation being off", ctx do
      [settings] =
        Ash.read!(KilnCMS.Federation.SiteFederation, authorize?: false, tenant: ctx.org_id)

      under_another_secret =
        KilnCMS.Keys.Vault.encrypt("pem", "some-other-secret-" <> String.duplicate("z", 64))

      KilnCMS.Repo.query!(
        "UPDATE site_federation SET private_key_encrypted = $1 WHERE id = $2",
        [under_another_secret, Ecto.UUID.dump!(settings.id)]
      )

      delivery = queue_delivery(ctx.org_id, ctx.follower)

      {result, log} =
        ExUnit.CaptureLog.with_log(fn -> run(delivery, ctx.org_id) end)

      assert result == :ok
      assert log =~ "signing key is unreadable"

      settled = reload(delivery, ctx.org_id)
      assert settled.state == :failed
      assert settled.last_error =~ "signing key is unreadable"
      assert settled.last_error =~ "SECRET_KEY_BASE"
    end
  end

  describe "backoff" do
    test "grows and is capped, and is always an integer Oban can use" do
      values = for attempt <- 1..20, do: DeliveryWorker.backoff(%Oban.Job{attempt: attempt})

      assert Enum.all?(values, &is_integer/1)
      assert Enum.all?(values, &(&1 > 0))
      # Monotonic up to the cap, then flat at six hours — a dead instance must
      # not hold a job for a week.
      assert values == Enum.sort(values)
      assert List.last(values) == 6 * 60 * 60
    end
  end

  test "a delivery row pruned out from under the job succeeds rather than crashing", ctx do
    delivery = queue_delivery(ctx.org_id, ctx.follower)
    Ash.destroy!(delivery, authorize?: false, tenant: ctx.org_id)

    assert :ok = run(delivery, ctx.org_id)
  end

  # #2753: one delivery stands for every follower at its inbox, so its outcome
  # is recorded against all of them — and nobody else.
  describe "a delivery to a shared inbox" do
    @shared "https://shared.example/inbox"

    setup ctx do
      followers =
        for name <- ~w(bob carol dave) do
          uri = "https://shared.example/users/#{name}"

          {:ok, follower} =
            Federation.follow(uri, uri <> "/inbox", %{shared_inbox_uri: @shared},
              authorize?: false,
              tenant: ctx.org_id
            )

          follower
        end

      # The same instance followed from ANOTHER site: the same inbox URI, and
      # none of this site's business. The test build's tenancy fails open, so
      # only this shows a lost `tenant:`.
      other = KilnCMS.OrgFixtures.org("fedshared")

      {:ok, theirs} =
        Federation.follow(
          "https://shared.example/users/zed",
          "https://shared.example/zed",
          %{shared_inbox_uri: @shared},
          authorize?: false,
          tenant: other.id
        )

      # Everyone starts with a failure on the books, so a reset shows.
      for follower <- [ctx.follower, theirs | followers] do
        fail!(follower, follower.org_id)
      end

      %{shared: followers, theirs: theirs}
    end

    defp fail!(follower, org_id) do
      Federation.record_follower_failure!(follower, authorize?: false, tenant: org_id)
    end

    defp shared_delivery(org_id, follower_id \\ nil) do
      {:ok, delivery} =
        Federation.create_federation_delivery(
          %{
            follower_id: follower_id,
            inbox_uri: @shared,
            activity_type: :create,
            activity: %{"type" => "Create", "id" => "https://kiln.example/ap/activity/create/2"}
          },
          authorize?: false,
          tenant: org_id
        )

      delivery
    end

    defp failures(follower) do
      case Federation.get_follower(follower.id, authorize?: false, tenant: follower.org_id) do
        {:ok, follower} -> follower.consecutive_failures
        {:error, _gone} -> :dropped
      end
    end

    defp delivered_at(follower) do
      Federation.get_follower!(follower.id, authorize?: false, tenant: follower.org_id).last_delivered_at
    end

    test "a success resets every follower at the inbox, and only them", ctx do
      Req.Test.stub(KilnCMS.Federation, fn conn -> Plug.Conn.send_resp(conn, 202, "") end)

      assert :ok = run(shared_delivery(ctx.org_id), ctx.org_id)

      for follower <- ctx.shared do
        assert failures(follower) == 0
        assert %DateTime{} = delivered_at(follower)
      end

      # A follower at a different inbox, and the other site's follower at this
      # one, are untouched.
      assert failures(ctx.follower) == 1
      assert failures(ctx.theirs) == 1
      assert delivered_at(ctx.theirs) == nil
    end

    test "an exhausted failure charges every follower at the inbox, and only them", ctx do
      Req.Test.stub(KilnCMS.Federation, fn conn -> Plug.Conn.send_resp(conn, 500, "") end)

      assert :ok = run(shared_delivery(ctx.org_id), ctx.org_id, attempt: 12, max_attempts: 12)

      for follower <- ctx.shared, do: assert(failures(follower) == 2)
      assert failures(ctx.follower) == 1
      assert failures(ctx.theirs) == 1
    end

    test "a retryable failure charges nobody", ctx do
      Req.Test.stub(KilnCMS.Federation, fn conn -> Plug.Conn.send_resp(conn, 500, "") end)

      assert {:error, _} = run(shared_delivery(ctx.org_id), ctx.org_id, attempt: 1)

      for follower <- ctx.shared, do: assert(failures(follower) == 1)
    end

    test "the failure that reaches the ceiling drops every follower at the inbox", ctx do
      Req.Test.stub(KilnCMS.Federation, fn conn -> Plug.Conn.send_resp(conn, 500, "") end)

      # One failure each from setup; take them to one short of the ceiling.
      for follower <- ctx.shared,
          _ <- 1..(Federation.drop_follower_after() - 2),
          do: fail!(follower, ctx.org_id)

      assert :ok = run(shared_delivery(ctx.org_id), ctx.org_id, attempt: 12, max_attempts: 12)

      for follower <- ctx.shared, do: assert(failures(follower) == :dropped)
      assert failures(ctx.follower) == 1
      assert failures(ctx.theirs) == 1
    end

    # `follower_id` set means exactly that follower, even at a shared inbox:
    # the row was written when the inbox had one follower, and someone who
    # followed through it since was not part of that delivery's bookkeeping.
    test "a named follower at a shared inbox is the only one recorded", ctx do
      [bob | others] = ctx.shared
      Req.Test.stub(KilnCMS.Federation, fn conn -> Plug.Conn.send_resp(conn, 500, "") end)

      assert :ok =
               run(shared_delivery(ctx.org_id, bob.id), ctx.org_id,
                 attempt: 12,
                 max_attempts: 12
               )

      assert failures(bob) == 2
      for follower <- others, do: assert(failures(follower) == 1)
    end

    test "a named follower since dropped records nothing, and the delivery still settles",
         ctx do
      [bob | others] = ctx.shared
      delivery = shared_delivery(ctx.org_id, bob.id)
      Federation.destroy_follower!(bob, authorize?: false, tenant: ctx.org_id)
      Req.Test.stub(KilnCMS.Federation, fn conn -> Plug.Conn.send_resp(conn, 202, "") end)

      assert :ok = run(delivery, ctx.org_id)

      assert reload(delivery, ctx.org_id).state == :delivered
      for follower <- others, do: assert(failures(follower) == 1)
    end
  end
end

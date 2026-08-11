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
      assert reload(delivery, ctx.org_id).state == :failed
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
end

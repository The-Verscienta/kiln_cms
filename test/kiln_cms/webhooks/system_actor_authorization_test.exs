defmodule KilnCMS.Webhooks.SystemActorAuthorizationTest do
  @moduledoc """
  #1659 batch 6: the webhook pipeline runs as `KilnCMS.Webhooks.system/0`
  rather than `authorize?: false`.

  Every grant is paired with a refusal, and each read that decides whether a
  webhook goes out is tested with the grant taken away
  (`Webhooks.with_actor(nil, ...)`). Under a filter policy a refused read
  answers "nothing": here that is "no endpoint subscribed" (nothing sent,
  nothing logged) or "ledger row gone" (the job succeeds, the webhook is never
  sent). Both must fail CLOSED instead: logged, and retried where there is a
  job to retry.
  """
  # async: false: Req.Test stubs are shared with the Oban job run inline.
  use KilnCMS.DataCase, async: false
  use Oban.Testing, repo: KilnCMS.Repo

  import ExUnit.CaptureLog

  alias KilnCMS.CMS
  alias KilnCMS.Webhooks
  alias KilnCMS.Webhooks.DeliveryWorker

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "sab6-wh-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp tenant, do: KilnCMS.Accounts.default_org_id()

  defp endpoint! do
    CMS.create_webhook_endpoint!(
      %{url: "https://example.test/hook", events: ["page.published"]},
      actor: admin(),
      tenant: tenant()
    )
  end

  defp stub_receiver do
    test = self()

    Req.Test.stub(KilnCMS.Webhooks, fn conn ->
      send(test, :posted)
      Plug.Conn.send_resp(conn, 200, "{}")
    end)
  end

  defp ledger, do: CMS.recent_webhook_deliveries!(actor: admin(), tenant: tenant())

  describe "CMS.WebhookEndpoint" do
    test "the system actor reads endpoints and keeps their health counters" do
      endpoint = endpoint!()
      system = Webhooks.system()

      read =
        CMS.list_webhook_endpoints!(actor: system, authorize_with: :error, tenant: tenant())

      assert endpoint.id in Enum.map(read, & &1.id)

      assert {:ok, failed} =
               CMS.record_webhook_failure(endpoint, %{}, actor: system, tenant: tenant())

      assert failed.consecutive_failures == 1

      assert {:ok, healed} =
               CMS.record_webhook_success(failed, %{}, actor: system, tenant: tenant())

      assert healed.consecutive_failures == 0
    end

    test "...and may not create, edit or delete one" do
      endpoint = endpoint!()
      system = Webhooks.system()

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.create_webhook_endpoint(%{url: "https://evil.test/hook"},
                 actor: system,
                 tenant: tenant()
               )

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.update_webhook_endpoint(endpoint, %{url: "https://evil.test/hook"},
                 actor: system,
                 tenant: tenant()
               )

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.destroy_webhook_endpoint(endpoint, actor: system, tenant: tenant())
    end

    test "an editor is refused the health counters" do
      endpoint = endpoint!()

      editor =
        Ash.Seed.seed!(KilnCMS.Accounts.User, %{
          email: "sab6-wh-ed-#{System.unique_integer([:positive])}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: :editor
        })

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.record_webhook_success(endpoint, %{}, actor: editor, tenant: tenant())
    end
  end

  describe "CMS.WebhookDelivery" do
    test "the system actor writes, re-reads and settles a ledger row" do
      endpoint = endpoint!()
      system = Webhooks.system()

      assert {:ok, delivery} =
               CMS.create_webhook_delivery(
                 %{endpoint_id: endpoint.id, event: "ping", payload: %{}},
                 actor: system,
                 tenant: tenant()
               )

      assert {:ok, read} =
               CMS.get_webhook_delivery(delivery.id,
                 actor: system,
                 authorize_with: :error,
                 tenant: tenant()
               )

      assert read.id == delivery.id

      assert {:ok, settled} =
               CMS.record_webhook_delivery_attempt(read, %{status: :succeeded, attempts: 1},
                 actor: system,
                 tenant: tenant()
               )

      assert settled.status == :succeeded
    end

    test "...and may not delete one" do
      endpoint = endpoint!()

      delivery =
        CMS.create_webhook_delivery!(
          %{endpoint_id: endpoint.id, event: "ping", payload: %{}},
          actor: Webhooks.system(),
          tenant: tenant()
        )

      refute Ash.can?({delivery, :destroy}, Webhooks.system(), tenant: tenant())
      assert Ash.can?({delivery, :destroy}, admin(), tenant: tenant())
    end
  end

  describe "fail closed" do
    test "a refused endpoint scan is logged, not read as \"nobody subscribed\"" do
      endpoint!()

      log =
        capture_log(fn ->
          assert :ok =
                   Webhooks.with_actor(nil, fn ->
                     Webhooks.dispatch("page.published", %{"title" => "Hi"}, tenant())
                   end)
        end)

      assert log =~ "Webhook dispatch of page.published"
      assert log =~ "refused by policy"
      refute_enqueued(worker: DeliveryWorker)
      assert ledger() == []
    end

    test "a refused ledger read retries the job instead of reading \"row pruned\"" do
      stub_receiver()
      endpoint!()
      Webhooks.dispatch("page.published", %{"title" => "Hi"}, tenant())
      [job] = all_enqueued(worker: DeliveryWorker)

      log =
        capture_log(fn ->
          assert {:error, %Ash.Error.Forbidden{}} =
                   Webhooks.with_actor(nil, fn -> perform_job(DeliveryWorker, job.args) end)
        end)

      assert log =~ "could not be read, retrying"
      refute_received :posted

      # Nothing was settled: the row is still pending, with no attempt on it,
      # so the retry delivers it rather than finding it closed.
      assert [%{status: :pending, attempts: 0}] = ledger()
    end

    test "with the grant in place the same job delivers and settles" do
      stub_receiver()
      endpoint!()
      Webhooks.dispatch("page.published", %{"title" => "Hi"}, tenant())
      [job] = all_enqueued(worker: DeliveryWorker)

      assert :ok = perform_job(DeliveryWorker, job.args)
      assert_received :posted
      assert [%{status: :succeeded, attempts: 1}] = ledger()
    end
  end
end
